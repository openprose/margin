"""A narrow, audited gateway between an agent and the Margin executable."""

from __future__ import annotations

import fcntl
import json
import os
import subprocess
import time
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

from .schema import Actor, CommandEvent, canonical_json, sha256_bytes


ALLOWED_COMMANDS = frozenset({
    "capabilities",
    "cat",
    "collaborators",
    "comment",
    "comments",
    "context",
    "handoff",
    "help",
    "inbox",
    "inspect",
    "man",
    "merge",
    "outline",
    "read",
    "reconcile",
    "review",
    "show",
    "slice",
    "stage",
    "suggest",
    "transact",
    "version",
    "workspace",
})
IDENTITY_FLAGS = frozenset({
    "--actor-id",
    "--actor-name",
    "--actor-type",
    "--creator-id",
    "--creator-name",
    "--creator-type",
})
VALUE_OPTIONS = frozenset({
    "-m", "--actor", "--actor-id", "--actor-name", "--actor-type", "--app",
    "--assignee", "--audience", "--body", "--change-set-file", "--comment",
    "--context", "--exclude", "--expect", "--finishing-cursor", "--for",
    "--format", "--from", "--heading", "--id", "--contribution-id", "--if-content-sha",
    "--if-revision", "--include", "--kind", "--limit", "--lines", "--max-bytes",
    "--max-contributions", "--max-depth", "--max-files", "--max-headings",
    "--max-preview-bytes", "--max-source-bytes", "--merged-body", "--message", "--message-file",
    "--next-actor", "--occurrence", "--operations-file", "--output", "--parent", "--path",
    "--policy", "--prefix", "--priority", "--quote", "--range", "--replacement",
    "--mutation-id", "--request-id", "--resolve", "--root", "--since-revision", "--stage-id",
    "--starting-cursor", "--status", "--suffix", "--thread", "--to", "--touched",
    "--unresolved",
})
BOOLEAN_OPTIONS = frozenset({
    "-h", "-v", "--apply", "--document", "--force", "--help", "--json",
    "--jsonl", "--list", "--pretty", "--reopen", "--stdin", "--subtree",
    "--version", "--wait", "--with-comments",
})
PATH_VALUE_OPTIONS = frozenset({
    "--app", "--change-set-file", "--exclude", "--include", "--merged-body",
    "--message-file", "--operations-file", "--output", "--path", "--root",
})


@dataclass(frozen=True)
class ToolPolicy:
    max_arguments: int = 64
    max_argument_bytes: int = 16 * 1024
    max_stdin_bytes: int = 1024 * 1024
    max_output_bytes: int = 1024 * 1024
    timeout_seconds: float = 30.0

    def __post_init__(self) -> None:
        values = (
            self.max_arguments,
            self.max_argument_bytes,
            self.max_stdin_bytes,
            self.max_output_bytes,
        )
        if any(value <= 0 for value in values) or not (0 < self.timeout_seconds <= 120):
            raise ValueError("Invalid gateway limits.")


@dataclass(frozen=True)
class GatewayResponse:
    exit_code: int
    stdout: str
    stderr: str
    duration_ms: float
    error_code: str | None
    blocked: bool = False

    @property
    def ok(self) -> bool:
        return self.exit_code == 0

    @property
    def json(self) -> dict[str, Any] | None:
        for value in (self.stdout, self.stderr):
            try:
                parsed = json.loads(value)
            except (json.JSONDecodeError, TypeError):
                continue
            if isinstance(parsed, dict):
                return parsed
        return None

    def tool_payload(self) -> dict[str, Any]:
        parsed_stdout: Any = self.stdout
        parsed_stderr: Any = self.stderr
        try:
            parsed_stdout = json.loads(self.stdout) if self.stdout else None
        except json.JSONDecodeError:
            pass
        try:
            parsed_stderr = json.loads(self.stderr) if self.stderr else None
        except json.JSONDecodeError:
            pass
        return {
            "ok": self.ok,
            "exitCode": self.exit_code,
            "errorCode": self.error_code,
            "stdout": parsed_stdout,
            "stderr": parsed_stderr,
        }


def _path_escapes_workspace(argument: str) -> bool:
    candidates = [argument]
    if argument.startswith("--") and "=" in argument:
        candidates.append(argument.split("=", 1)[1])
    for candidate in candidates:
        if not candidate or candidate == "-":
            continue
        normalized = candidate.replace("\\", "/")
        if "\x00" in candidate:
            return True
        if candidate.startswith(("/", "~")) or candidate.lower().startswith("file:"):
            return True
        if len(candidate) >= 3 and candidate[0].isalpha() and candidate[1] == ":" and candidate[2] in "/\\":
            return True
        if ".." in normalized.split("/"):
            return True
    return False


def _resolves_outside_workspace(argument: str, workspace: Path) -> bool:
    candidates = [argument]
    if argument.startswith("--") and "=" in argument:
        candidates.append(argument.split("=", 1)[1])
    for candidate in candidates:
        if (
            not candidate
            or candidate == "-"
            or candidate.startswith("-")
            or candidate.startswith(("urn:", "sha256:", "mcur1:"))
        ):
            continue
        try:
            resolved = (workspace / candidate).resolve(strict=False)
            resolved.relative_to(workspace)
        except ValueError:
            return True
        except OSError:
            # The CLI remains responsible for ordinary malformed or unavailable
            # paths; a resolution failure is not evidence of an escape.
            continue
    return False


def _path_arguments(arguments: list[str]) -> list[str]:
    """Extract only values the Margin grammar can interpret as filesystem paths.

    Comment bodies, quotes, headings, and identifiers are deliberately excluded:
    untrusted collaborative prose may contain absolute-looking text or `../`
    without gaining filesystem authority.
    """
    aliases = {"comment": "comments", "show": "read", "cat": "read"}
    command = aliases.get(arguments[0], arguments[0])
    positionals: list[str] = []
    path_values: list[str] = []
    index = 1
    while index < len(arguments):
        token = arguments[index]
        if token.startswith("--") and "=" in token:
            option, value = token.split("=", 1)
            if option in PATH_VALUE_OPTIONS or (option == "--from" and command == "reconcile"):
                path_values.append(value)
            index += 1
            continue
        if _is_boolean_option(token, arguments):
            index += 1
            continue
        if token.startswith("-"):
            takes_value = token in VALUE_OPTIONS or not _is_boolean_option(token, arguments)
            if takes_value and index + 1 < len(arguments):
                value = arguments[index + 1]
                if token in PATH_VALUE_OPTIONS or (token == "--from" and command == "reconcile"):
                    path_values.append(value)
                index += 2
            else:
                index += 1
            continue
        positionals.append(token)
        index += 1

    if command in {"inspect", "outline", "read", "slice", "review"}:
        path_values.extend(positionals[:1])
    elif command in {"context", "collaborators", "inbox"}:
        path_values.extend(positionals[:1])
    elif command in {"comments", "workspace", "stage", "suggest", "handoff"}:
        path_values.extend(positionals[1:2])
    elif command == "transact":
        path_values.extend(positionals[:2])
    elif command == "reconcile":
        path_values.extend(positionals[:1])
    elif command == "merge":
        path_values.extend(positionals[:3])
    return path_values


def _option_names(arguments: list[str]) -> set[str]:
    names: set[str] = set()
    index = 1
    while index < len(arguments):
        token = arguments[index]
        if not token.startswith("-"):
            index += 1
            continue
        option = token.split("=", 1)[0]
        names.add(option)
        if (
            "=" not in token
            and not _is_boolean_option(option, arguments)
            and index + 1 < len(arguments)
        ):
            index += 2
        else:
            index += 1
    return names


def _error_code(stdout: str, stderr: str) -> str | None:
    for value in (stderr, stdout):
        try:
            payload = json.loads(value)
        except (json.JSONDecodeError, TypeError):
            continue
        if not isinstance(payload, dict):
            continue
        error = payload.get("error")
        if isinstance(error, dict) and isinstance(error.get("code"), str):
            return error["code"]
        if isinstance(payload.get("errorCode"), str):
            return payload["errorCode"]
    return None


def command_path(arguments: list[str]) -> str:
    if not arguments:
        return ""
    first = arguments[0].lstrip("-")
    if len(arguments) > 1 and not arguments[1].startswith("-") and first in {
        "comments", "handoff", "stage", "suggest", "workspace", "reconcile", "merge"
    }:
        return f"{first} {arguments[1]}"
    return first


def _is_boolean_option(option: str, arguments: list[str]) -> bool:
    if option in BOOLEAN_OPTIONS:
        return True
    return option == "--resolve" and command_path(arguments) == "comments reply"


def event_command_path(arguments: list[str]) -> str:
    path = command_path(arguments)
    if path == "comments reply" and "--resolve" in _option_names(arguments):
        return "comments reply --resolve"
    if path == "comments add" and "--parent" in _option_names(arguments):
        # `comments add --parent` is the documented reply shorthand. Telemetry
        # records semantic actions so equivalent public spellings receive the
        # same protocol credit without retaining argument values.
        return "comments reply"
    return path


class MarginGateway:
    def __init__(
        self,
        binary: Path,
        workspace: Path,
        actor: Actor,
        role: str,
        *,
        event_log: Path | None = None,
        state_home: Path | None = None,
        policy: ToolPolicy | None = None,
    ):
        self.binary = binary.expanduser().resolve()
        self.workspace = workspace.expanduser().resolve()
        self.actor = actor
        self.role = role
        self.event_log = event_log
        self.state_home = state_home or self.workspace.parent / ".marginbench-state"
        self.policy = policy or ToolPolicy()
        if not self.binary.is_file() or not os.access(self.binary, os.X_OK):
            raise ValueError(f"Margin executable is unavailable: {self.binary}")
        if not self.workspace.is_dir():
            raise ValueError(f"MarginBench workspace is unavailable: {self.workspace}")

    def _blocked(self, code: str, message: str, arguments: list[str], started: float) -> GatewayResponse:
        response = GatewayResponse(
            exit_code=64,
            stdout="",
            stderr=json.dumps({"error": {"code": code, "message": message}}, separators=(",", ":")),
            duration_ms=(time.perf_counter() - started) * 1000,
            error_code=code,
            blocked=True,
        )
        self._record(arguments, None, response)
        return response

    def call(self, arguments: list[str], stdin: str | bytes | None = None) -> GatewayResponse:
        started = time.perf_counter()
        if not isinstance(arguments, list) or not arguments or not all(isinstance(item, str) for item in arguments):
            return self._blocked("MARGINBENCH_INVALID_ARGUMENTS", "arguments must be a non-empty string array", [], started)
        if len(arguments) > self.policy.max_arguments:
            return self._blocked("MARGINBENCH_ARGUMENT_LIMIT", "too many arguments", arguments, started)
        if any(len(item.encode("utf-8")) > self.policy.max_argument_bytes for item in arguments):
            return self._blocked("MARGINBENCH_ARGUMENT_LIMIT", "an argument exceeds its byte limit", arguments, started)
        first = arguments[0]
        if first not in ALLOWED_COMMANDS and first not in {"-h", "--help", "--version"}:
            directory_hint = (
                " Use 'context . --json --max-files 16' to inspect a directory or "
                "'inbox . --status open --max-contributions 64' to find open work."
                if first in {"ls", "find", "pwd", "tree"}
                else " Run 'man agents' or focused command help to choose a Margin command."
            )
            return self._blocked(
                "MARGINBENCH_COMMAND_BLOCKED",
                "Only headless Margin collaboration commands are allowed." + directory_hint,
                arguments,
                started,
            )
        if _option_names(arguments) & IDENTITY_FLAGS:
            recipient_hint = (
                " To name the recipient of a handoff, remove actor flags and use "
                "'--next-actor ACTOR_ID'."
                if command_path(arguments) == "handoff add"
                else " Remove actor flags and retry as the bound collaborator."
            )
            return self._blocked(
                "MARGINBENCH_IDENTITY_BOUND",
                "The gateway already binds your collaborator identity." + recipient_hint,
                arguments,
                started,
            )
        if any(
            _path_escapes_workspace(item) or _resolves_outside_workspace(item, self.workspace)
            for item in _path_arguments(arguments)
        ):
            return self._blocked("MARGINBENCH_WORKSPACE_ESCAPE", "paths must remain inside the episode workspace", arguments, started)
        if stdin is None:
            input_bytes = None
        elif isinstance(stdin, str):
            input_bytes = stdin.encode("utf-8")
        elif isinstance(stdin, bytes):
            input_bytes = stdin
        else:
            return self._blocked("MARGINBENCH_INVALID_STDIN", "stdin must be text or bytes", arguments, started)
        if input_bytes is not None and len(input_bytes) > self.policy.max_stdin_bytes:
            return self._blocked("MARGINBENCH_STDIN_LIMIT", "stdin exceeds its byte limit", arguments, started)

        self.state_home.mkdir(parents=True, exist_ok=True)
        environment = {
            "HOME": str(self.state_home),
            "LANG": os.environ.get("LANG", "C.UTF-8"),
            "LC_ALL": os.environ.get("LC_ALL", "C.UTF-8"),
            "PATH": os.environ.get("PATH", "/usr/local/bin:/usr/bin:/bin"),
            "MARGIN_ACTOR_ID": self.actor.id,
            "MARGIN_ACTOR_NAME": self.actor.name,
            "MARGIN_ACTOR_TYPE": self.actor.type,
        }
        try:
            completed = subprocess.run(
                [str(self.binary), *arguments],
                cwd=self.workspace,
                env=environment,
                input=input_bytes,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
                timeout=self.policy.timeout_seconds,
            )
            stdout_bytes = completed.stdout[: self.policy.max_output_bytes]
            stderr_bytes = completed.stderr[: self.policy.max_output_bytes]
            truncated = len(completed.stdout) > len(stdout_bytes) or len(completed.stderr) > len(stderr_bytes)
            stdout = stdout_bytes.decode("utf-8", errors="replace")
            stderr = stderr_bytes.decode("utf-8", errors="replace")
            code = _error_code(stdout, stderr)
            if truncated:
                code = code or "MARGINBENCH_OUTPUT_LIMIT"
                suffix = "\n[MarginBench output truncated]"
                stderr = (stderr + suffix)[-self.policy.max_output_bytes :]
            response = GatewayResponse(
                exit_code=completed.returncode,
                stdout=stdout,
                stderr=stderr,
                duration_ms=(time.perf_counter() - started) * 1000,
                error_code=code,
            )
        except subprocess.TimeoutExpired:
            response = GatewayResponse(
                exit_code=74,
                stdout="",
                stderr='{"error":{"code":"MARGINBENCH_TIMEOUT","message":"Margin command timed out."}}',
                duration_ms=(time.perf_counter() - started) * 1000,
                error_code="MARGINBENCH_TIMEOUT",
            )
        except OSError as error:
            response = GatewayResponse(
                exit_code=74,
                stdout="",
                stderr='{"error":{"code":"MARGINBENCH_EXECUTION","message":"Margin could not be executed."}}',
                duration_ms=(time.perf_counter() - started) * 1000,
                error_code="MARGINBENCH_EXECUTION",
            )
            _ = error
        self._record(arguments, input_bytes, response)
        return response

    def _record(self, arguments: list[str], stdin: bytes | None, response: GatewayResponse) -> None:
        if self.event_log is None:
            return
        self.event_log.parent.mkdir(parents=True, exist_ok=True)
        event = CommandEvent(
            role=self.role,
            command=event_command_path(arguments),
            exit_code=response.exit_code,
            duration_ms=round(response.duration_ms, 3),
            stdin_bytes=len(stdin or b""),
            stdout_bytes=len(response.stdout.encode("utf-8")),
            stderr_bytes=len(response.stderr.encode("utf-8")),
            error_code=response.error_code,
            blocked=response.blocked,
        )
        line = canonical_json(asdict(event)) + b"\n"
        descriptor = os.open(self.event_log, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX)
            os.write(descriptor, line)
            os.fsync(descriptor)
        finally:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
            os.close(descriptor)


def read_command_events(path: Path) -> tuple[CommandEvent, ...]:
    if not path.exists():
        return ()
    events: list[CommandEvent] = []
    for raw in path.read_bytes().splitlines():
        try:
            payload = json.loads(raw)
            events.append(CommandEvent(**payload))
        except (json.JSONDecodeError, TypeError, ValueError):
            continue
    return tuple(events)


def binary_sha256(path: Path) -> str:
    return sha256_bytes(path.read_bytes())
