#!/usr/bin/env python3
"""Shared loading, preparation, invocation, and privacy helpers for CLI evals."""

from __future__ import annotations

import fcntl
import hashlib
import json
import os
import re
import shutil
import subprocess
import tempfile
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable


ROOT = Path(__file__).resolve().parents[2]
EVAL_DIR = Path(__file__).resolve().parent
SCENARIOS_DIR = EVAL_DIR / "scenarios"
SUITE_PATH = EVAL_DIR / "suite.json"
MODELS_PATH = EVAL_DIR / "models.json"
DOCUMENT_NAME = "review.md"


class EvalError(RuntimeError):
    pass


@dataclass(frozen=True)
class Scenario:
    id: str
    directory: Path
    manifest: dict[str, Any]
    fixture: Path
    prompt: Path
    oracle: Path
    weight: float

    @property
    def checks(self) -> list[dict[str, Any]]:
        return [item for item in self.manifest.get("checks", []) if isinstance(item, dict)]


@dataclass
class Invocation:
    argv: list[str]
    exit_code: int
    stdout: bytes
    stderr: bytes
    duration_ms: float

    @property
    def json(self) -> Any | None:
        return parse_json(self.stdout)


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    return sha256_bytes(path.read_bytes())


def canonical_json_hash(value: Any) -> str:
    encoded = json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return sha256_bytes(encoded)


def scenario_fingerprint(scenario: Scenario) -> str:
    return canonical_json_hash({
        "fixtureSha256": sha256_file(scenario.fixture),
        "manifest": scenario.manifest,
        "oracleSha256": sha256_file(scenario.oracle),
        "promptSha256": sha256_file(scenario.prompt),
        "weight": scenario.weight,
    })


def harness_fingerprint() -> str:
    names = ["eval_lib.py", "gate.py", "proxy.py", "run.py", "score.py"]
    return canonical_json_hash({name: sha256_file(EVAL_DIR / name) for name in names})


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def safe_slug(value: str) -> str:
    slug = "".join(character if character.isalnum() else "-" for character in value)
    return slug.strip("-").lower() or "unnamed"


def load_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise EvalError(f"Could not load {path}: {error}") from error


def _resolve_scenario_file(directory: Path, raw: Any, field: str) -> Path:
    if not isinstance(raw, str) or not raw:
        raise EvalError(f"Scenario {directory.name} requires a nonempty {field} path.")
    path = (directory / raw).resolve()
    if not path.is_file():
        raise EvalError(f"Scenario {directory.name} {field} does not exist: {path}")
    return path


def load_suite(selected: Iterable[str] | None = None) -> list[Scenario]:
    suite = load_json(SUITE_PATH)
    entries = suite.get("scenarios", []) if isinstance(suite, dict) else []
    requested = set(selected or [])
    scenarios: list[Scenario] = []
    seen: set[str] = set()
    for entry in entries:
        if not isinstance(entry, dict) or not isinstance(entry.get("id"), str):
            raise EvalError("Every suite scenario entry requires an id.")
        scenario_id = entry["id"]
        if requested and scenario_id not in requested:
            continue
        directory = SCENARIOS_DIR / scenario_id
        manifest_path = directory / "scenario.json"
        manifest = load_json(manifest_path)
        if not isinstance(manifest, dict) or manifest.get("id") != scenario_id:
            raise EvalError(f"Scenario manifest id mismatch for {scenario_id}.")
        if scenario_id in seen:
            raise EvalError(f"Duplicate scenario id {scenario_id}.")
        seen.add(scenario_id)
        checks = manifest.get("checks")
        if not isinstance(checks, list) or not checks:
            raise EvalError(f"Scenario {scenario_id} has no checks.")
        check_ids = [check.get("id") for check in checks if isinstance(check, dict)]
        if len(check_ids) != len(checks) or len(set(check_ids)) != len(check_ids):
            raise EvalError(f"Scenario {scenario_id} check ids must be unique strings.")
        possible = sum(int(check.get("points", 0)) for check in checks if isinstance(check, dict))
        if possible != 100:
            raise EvalError(f"Scenario {scenario_id} defines {possible} points instead of 100.")
        scenarios.append(Scenario(
            id=scenario_id,
            directory=directory,
            manifest=manifest,
            fixture=_resolve_scenario_file(directory, manifest.get("fixture"), "fixture"),
            prompt=_resolve_scenario_file(directory, manifest.get("prompt"), "prompt"),
            oracle=_resolve_scenario_file(directory, manifest.get("oracle"), "oracle"),
            weight=float(entry.get("weight", 1.0)),
        ))
    missing = requested - seen
    if missing:
        raise EvalError(f"Unknown scenarios: {', '.join(sorted(missing))}")
    if not scenarios:
        raise EvalError("No scenarios selected.")
    return scenarios


def load_models(path: Path = MODELS_PATH) -> list[dict[str, str]]:
    payload = load_json(path)
    values = payload.get("models", []) if isinstance(payload, dict) else []
    result: list[dict[str, str]] = []
    for item in values:
        if isinstance(item, dict) and isinstance(item.get("provider"), str) and isinstance(item.get("model"), str):
            result.append({"provider": item["provider"], "model": item["model"]})
    return result


def canonical_model(model: dict[str, str]) -> str:
    return f"{model['provider']}/{model['model']}"


def find_margin_binary(explicit: Path | None) -> Path | None:
    candidates: list[Path] = []
    if explicit:
        candidates.append(explicit.expanduser())
    installed = shutil.which("margin")
    if installed:
        candidates.append(Path(installed))
    candidates.extend([
        ROOT / "build" / "margin",
        ROOT / ".build" / "release" / "margin-cli",
        ROOT / ".build" / "debug" / "margin-cli",
    ])
    for candidate in candidates:
        if candidate.exists() and os.access(candidate, os.X_OK):
            return candidate.resolve()
    return None


def parse_json(data: bytes) -> Any | None:
    text = data.decode("utf-8", errors="replace").strip()
    if not text:
        return None
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        for line in reversed(text.splitlines()):
            try:
                return json.loads(line)
            except json.JSONDecodeError:
                continue
    return None


def invoke(binary: Path, argv: list[str], environment: dict[str, str] | None = None, timeout: int = 30) -> Invocation:
    started = time.monotonic()
    try:
        completed = subprocess.run(
            [str(binary), *argv],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=environment,
            check=False,
            timeout=timeout,
        )
        return Invocation(
            argv=argv,
            exit_code=completed.returncode,
            stdout=completed.stdout,
            stderr=completed.stderr,
            duration_ms=(time.monotonic() - started) * 1000,
        )
    except subprocess.TimeoutExpired as error:
        return Invocation(
            argv=argv,
            exit_code=124,
            stdout=error.stdout or b"",
            stderr=error.stderr or b"",
            duration_ms=(time.monotonic() - started) * 1000,
        )


def substitute_document(argv: list[Any], document: Path) -> list[str]:
    return [str(document) if value == "$DOCUMENT" else str(value) for value in argv]


def actor_environment(actor: dict[str, Any] | None = None) -> dict[str, str]:
    environment = os.environ.copy()
    if actor:
        mapping = {
            "id": "MARGIN_ACTOR_ID",
            "name": "MARGIN_ACTOR_NAME",
            "type": "MARGIN_ACTOR_TYPE",
        }
        for key, variable in mapping.items():
            if isinstance(actor.get(key), str):
                environment[variable] = actor[key]
    return environment


def sanitized_invocation(invocation: Invocation) -> dict[str, Any]:
    return {
        "argvSha256": sha256_bytes(json.dumps(invocation.argv, separators=(",", ":")).encode("utf-8")),
        "durationMs": round(invocation.duration_ms, 3),
        "exitCode": invocation.exit_code,
        "stderr": {"bytes": len(invocation.stderr), "sha256": sha256_bytes(invocation.stderr)},
        "stdout": {"bytes": len(invocation.stdout), "sha256": sha256_bytes(invocation.stdout)},
    }


def prepare_case(scenario: Scenario, case_dir: Path, margin_binary: Path) -> Path:
    workspace = case_dir / "workspace"
    workspace.mkdir(parents=True, exist_ok=False)
    document = workspace / DOCUMENT_NAME
    shutil.copy2(scenario.fixture, document)
    setup_records: list[dict[str, Any]] = []
    for index, step in enumerate(scenario.manifest.get("setup", [])):
        if not isinstance(step, dict) or not isinstance(step.get("argv"), list):
            raise EvalError(f"Scenario {scenario.id} setup step {index} is malformed.")
        invocation = invoke(
            margin_binary,
            substitute_document(step["argv"], document),
            actor_environment(step.get("actor") if isinstance(step.get("actor"), dict) else None),
        )
        setup_records.append(sanitized_invocation(invocation))
        expected_exit = int(step.get("expectedExit", 0))
        if invocation.exit_code != expected_exit:
            detail = invocation.stderr.decode("utf-8", errors="replace")[:500]
            raise EvalError(
                f"Scenario {scenario.id} setup step {index} returned {invocation.exit_code}, "
                f"expected {expected_exit}: {detail}"
            )
    validation = invoke(margin_binary, ["comments", "validate", str(document)])
    if validation.exit_code != 0:
        raise EvalError(f"Scenario {scenario.id} setup produced an invalid document.")
    metadata = {
        "document": DOCUMENT_NAME,
        "fixtureSha256": sha256_file(scenario.fixture),
        "scenario": scenario.id,
        "scenarioSha256": scenario_fingerprint(scenario),
        "schema": "urn:margin:cli-eval-setup:v1",
        "steps": setup_records,
    }
    (case_dir / "setup.json").write_text(json.dumps(metadata, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return document


def load_command_log(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    records: list[dict[str, Any]] = []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict) and isinstance(value.get("argv"), list):
            records.append(value)
    return records


def append_jsonl(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
        handle.write(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n")
        handle.flush()
        os.fsync(handle.fileno())
        fcntl.flock(handle.fileno(), fcntl.LOCK_UN)


def usage_and_trace(jsonl: bytes) -> tuple[dict[str, Any], dict[str, Any]]:
    messages: list[dict[str, Any]] = []
    event_counts: dict[str, int] = {}
    tool_calls = 0
    direct_reads: list[str] = []
    direct_writes: list[str] = []
    harness_accesses: list[str] = []
    sensitive_accesses: list[str] = []
    read_pattern = re.compile(
        r"(?:read_text|read_bytes|\bcat\b|\bsed\b|\bhead\b|\btail\b|\bless\b|\bmore\b|"
        r"\bgrep\b|\brg\b|\bawk\b|\bperl\b|\bruby\b|\bpython(?:3)?\b|\bdd\b|\bxxd\b|"
        r"\bstrings\b|\bwc\b|<\s*[^|;&\n]+|open\s*\([^\n]{0,160})",
        re.IGNORECASE,
    )
    write_pattern = re.compile(
        r"(?:write_text|write_bytes|\btee\b|(?:^|[^>])>\s*[^|;&\n]+|\bcp\b|\bmv\b|\brm\b|"
        r"\btruncate\b|\bapply_patch\b|\bsed\b[^\n]*\s-i(?:\s|$)|>>|"
        r"open\s*\([^\n]{0,160}[\"'](?:w|a|x)[\"'])",
        re.IGNORECASE,
    )
    harness_pattern = re.compile(
        r"(?:scenario\.json|oracle\.json|gate-history|score\.py|gate\.py|Evals/cli)",
        re.IGNORECASE,
    )
    sensitive_pattern = re.compile(
        r"(?:os\.(?:environ|getenv)|environ\.get|\bprintenv\b|MARGIN_EVAL_|"
        r"(?:system|run|check_output)\s*\([^\n]{0,80}[\"']env[\"']|"
        r"\.prime/(?:agent/)?auth|\.claude|api[_-]?key|credentials|auth\.json)",
        re.IGNORECASE,
    )

    for line in jsonl.decode("utf-8", errors="replace").splitlines():
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(event, dict):
            continue
        event_type = event.get("type")
        if isinstance(event_type, str):
            event_counts[event_type] = event_counts.get(event_type, 0) + 1
        if event_type == "tool_execution_start":
            tool_calls += 1
            args = event.get("args")
            fragments: list[str] = []

            def collect(value: Any) -> None:
                if isinstance(value, str):
                    fragments.append(value)
                elif isinstance(value, dict):
                    for child in value.values():
                        collect(child)
                elif isinstance(value, list):
                    for child in value:
                        collect(child)

            collect(args)
            code = "\n".join(fragments)
            if DOCUMENT_NAME in code:
                digest = sha256_bytes(code.encode("utf-8", errors="replace"))
                if write_pattern.search(code):
                    direct_writes.append(digest)
                elif read_pattern.search(code):
                    direct_reads.append(digest)
            digest = sha256_bytes(code.encode("utf-8", errors="replace"))
            if harness_pattern.search(code) and read_pattern.search(code):
                harness_accesses.append(digest)
            if sensitive_pattern.search(code):
                sensitive_accesses.append(digest)
        if event_type != "message_end":
            continue
        message = event.get("message")
        if isinstance(message, dict) and message.get("role") == "assistant" and isinstance(message.get("usage"), dict):
            messages.append(message["usage"])

    totals: dict[str, Any] = {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0, "cost": 0.0}
    for usage in messages:
        for key in ("input", "output", "cacheRead", "cacheWrite"):
            if isinstance(usage.get(key), (int, float)):
                totals[key] += int(usage[key])
        cost = usage.get("cost")
        if isinstance(cost, dict) and isinstance(cost.get("total"), (int, float)):
            totals["cost"] += float(cost["total"])
    totals["assistantMessages"] = len(messages)
    totals["eventCounts"] = event_counts
    trace = {
        "directDocumentReadHashes": sorted(set(direct_reads)),
        "directDocumentReads": len(direct_reads),
        "directDocumentWriteHashes": sorted(set(direct_writes)),
        "directDocumentWrites": len(direct_writes),
        "harnessAccessHashes": sorted(set(harness_accesses)),
        "harnessAccesses": len(harness_accesses),
        "policyCompliant": not direct_reads and not direct_writes and not harness_accesses and not sensitive_accesses,
        "schema": "urn:margin:cli-eval-trace:v1",
        "sensitiveAccessHashes": sorted(set(sensitive_accesses)),
        "sensitiveAccesses": len(sensitive_accesses),
        "toolCalls": tool_calls,
    }
    return totals, trace


def git_revision() -> str | None:
    completed = subprocess.run(
        ["git", "-C", str(ROOT), "rev-parse", "HEAD"],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    value = completed.stdout.decode("utf-8", errors="replace").strip()
    return value if completed.returncode == 0 and value else None


def git_is_dirty() -> bool | None:
    completed = subprocess.run(
        ["git", "-C", str(ROOT), "status", "--porcelain"],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    if completed.returncode != 0:
        return None
    return bool(completed.stdout.strip())


def temporary_case(prefix: str = "margin-cli-eval-") -> tuple[Path, tempfile.TemporaryDirectory[str]]:
    owner = tempfile.TemporaryDirectory(prefix=prefix)
    return Path(owner.name), owner
