#!/usr/bin/env python3
"""Headless Margin proxy with privacy-minimized collaboration telemetry."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
from eval_lib import CommandResult, append_jsonl, command_evidence, sha256_text, utc_now  # noqa: E402


AGENT_COMMANDS = frozenset({
    "capabilities", "collaborators", "comment", "comments", "context", "handoff",
    "help", "inbox", "inspect", "man", "merge", "outline", "read", "reconcile", "review",
    "slice", "stage", "submit", "suggest", "suggestions", "transact", "version",
    "workspace",
})
MAX_STDIN_BYTES = 128 * 1024


def would_launch_gui(arguments: list[str]) -> bool:
    if not arguments:
        return True
    first = arguments[0]
    if first in {"-h", "--help", "--version"}:
        return False
    return first == "open" or first not in AGENT_COMMANDS


def path_escapes_workspace(argument: str) -> bool:
    """Reject path spellings that can escape the trusted tool's fixed cwd.

    The proxy cannot know which arbitrary option values are paths, so confined
    mode deliberately applies this conservative check to every argv entry and
    to the value portion of --option=value spellings.  Literal body text may
    contain slashes, but cannot begin at an absolute/home path or traverse a
    parent component.
    """
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


def arguments_are_confined(arguments: list[str]) -> bool:
    return bool(arguments) and not any(path_escapes_workspace(argument) for argument in arguments)


def _trusted_stdin() -> bytes | None:
    if os.environ.get("MARGIN_COLLAB_STDIN_PRESENT") != "1":
        return None
    payload = sys.stdin.buffer.read(MAX_STDIN_BYTES + 1)
    if len(payload) > MAX_STDIN_BYTES:
        raise ValueError("Trusted Margin CLI standard input exceeds its byte limit.")
    return payload


def main() -> int:
    real = os.environ.get("MARGIN_COLLAB_REAL_BIN")
    log = os.environ.get("MARGIN_COLLAB_COMMAND_LOG")
    workspace_raw = os.environ.get("MARGIN_COLLAB_WORKSPACE")
    role_hash = os.environ.get("MARGIN_COLLAB_ROLE_HASH")
    if not real or not log or not workspace_raw:
        sys.stderr.write('{"error":{"code":"EVAL_CONFIGURATION","message":"Collaboration proxy is not configured."}}\n')
        return 78
    arguments = sys.argv[1:]
    workspace = Path(workspace_raw)
    if os.environ.get("MARGIN_COLLAB_CONFINED") == "1" and not arguments_are_confined(arguments):
        event = {
            "argv": ["$WORKSPACE_ESCAPE_BLOCKED"],
            "durationMs": 0.0,
            "errorCode": "HEADLESS_WORKSPACE_ESCAPE_BLOCKED",
            "exitCode": 64,
            "roleHash": role_hash,
            "schema": "urn:margin:collaboration-eval-command:v1",
            "timestamp": utc_now(),
        }
        append_jsonl(Path(log), event)
        sys.stderr.write(
            '{"error":{"code":"HEADLESS_WORKSPACE_ESCAPE_BLOCKED",'
            '"message":"Paths must remain inside the evaluation workspace."}}\n'
        )
        return 64
    if would_launch_gui(arguments):
        event = {
            "argv": ["$GUI_ROUTE_BLOCKED"],
            "durationMs": 0.0,
            "errorCode": "HEADLESS_GUI_BLOCKED",
            "exitCode": 64,
            "roleHash": role_hash,
            "schema": "urn:margin:collaboration-eval-command:v1",
            "timestamp": utc_now(),
        }
        append_jsonl(Path(log), event)
        sys.stderr.write('{"error":{"code":"HEADLESS_GUI_BLOCKED","message":"Use a Margin agent command in this evaluation."}}\n')
        return 64
    try:
        stdin = _trusted_stdin()
        started = time.perf_counter()
        completed = subprocess.run(
            [real, *arguments],
            input=stdin,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=90,
        )
        result = CommandResult(
            argv=tuple(arguments),
            exit_code=completed.returncode,
            stdout=completed.stdout,
            stderr=completed.stderr,
            duration_ms=(time.perf_counter() - started) * 1000,
        )
        event = command_evidence(result, workspace)
        event.update({
            "roleHash": role_hash,
            "schema": "urn:margin:collaboration-eval-command:v1",
            "timestamp": utc_now(),
        })
        append_jsonl(Path(log), event)
        sys.stdout.buffer.write(completed.stdout)
        sys.stderr.buffer.write(completed.stderr)
        return completed.returncode
    except (OSError, subprocess.TimeoutExpired, ValueError) as error:
        append_jsonl(Path(log), {
            "argv": ["$PROXY_FAILURE"],
            "errorCode": type(error).__name__.upper(),
            "errorSha256": sha256_text(f"{type(error).__name__}:{error}"),
            "exitCode": 74,
            "roleHash": role_hash,
            "schema": "urn:margin:collaboration-eval-command:v1",
            "timestamp": utc_now(),
        })
        sys.stderr.write(json.dumps({"error": {"code": "EVAL_PROXY_FAILURE", "message": "Margin proxy failed."}}) + "\n")
        return 74


if __name__ == "__main__":
    raise SystemExit(main())
