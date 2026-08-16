#!/usr/bin/env python3
"""Privacy-preserving `margin` proxy used inside an isolated eval workspace."""

from __future__ import annotations

import fcntl
import hashlib
import json
import os
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


SENSITIVE_VALUE_FLAGS = {
    "-m", "--message", "--body", "--message-file", "--quote", "--prefix", "--suffix", "--expect",
    "--actor-id", "--actor-name",
}
SENSITIVE_INLINE_PREFIXES = tuple(f"{flag}=" for flag in SENSITIVE_VALUE_FLAGS if flag.startswith("--"))
HEADLESS_COMMANDS = {
    "-h", "--help", "help", "-v", "--version", "version", "inspect", "outline",
    "read", "slice", "review", "comments", "comment",
}


def digest(value: bytes) -> str:
    return "sha256:" + hashlib.sha256(value).hexdigest()


def normalize_argv(argv: list[str], document: str | None) -> list[str]:
    result: list[str] = []
    redact_next = False
    normalized_document = os.path.realpath(document) if document else None
    for value in argv:
        if redact_next:
            result.append(digest(value.encode("utf-8", errors="replace")))
            redact_next = False
        elif value.startswith(SENSITIVE_INLINE_PREFIXES):
            flag, sensitive = value.split("=", 1)
            result.append(f"{flag}={digest(sensitive.encode('utf-8', errors='replace'))}")
        elif normalized_document and os.path.realpath(value) == normalized_document:
            result.append("$DOCUMENT")
        else:
            result.append(value)
            redact_next = value in SENSITIVE_VALUE_FLAGS
    return result


def parse_output(data: bytes) -> Any | None:
    try:
        return json.loads(data.decode("utf-8", errors="replace"))
    except json.JSONDecodeError:
        return None


def recursive_first(value: Any, key: str) -> Any | None:
    if isinstance(value, dict):
        if key in value:
            return value[key]
        for child in value.values():
            found = recursive_first(child, key)
            if found is not None:
                return found
    elif isinstance(value, list):
        for child in value:
            found = recursive_first(child, key)
            if found is not None:
                return found
    return None


def append(path: Path, record: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
        handle.write(json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n")
        handle.flush()
        os.fsync(handle.fileno())
        fcntl.flock(handle.fileno(), fcntl.LOCK_UN)


def would_launch_gui(argv: list[str]) -> bool:
    return not argv or argv[0] not in HEADLESS_COMMANDS


def main() -> int:
    binary = os.environ.get("MARGIN_EVAL_REAL_BIN")
    log_path = os.environ.get("MARGIN_EVAL_COMMAND_LOG")
    if not binary or not log_path:
        print("margin eval proxy is missing its harness configuration", file=sys.stderr)
        return 70
    stdin = sys.stdin.buffer.read() if not sys.stdin.isatty() else None
    started = time.monotonic()
    if os.environ.get("MARGIN_EVAL_HEADLESS") == "1" and would_launch_gui(sys.argv[1:]):
        error = {
            "error": {
                "code": "EVAL_GUI_DISABLED",
                "message": "GUI launches are disabled in headless agent cases; use a documented reading or comment command.",
            },
            "ok": False,
            "schema": "urn:margin:cli-eval-error:v1",
        }
        completed = subprocess.CompletedProcess(
            args=[binary, *sys.argv[1:]],
            returncode=64,
            stdout=b"",
            stderr=(json.dumps(error, sort_keys=True) + "\n").encode(),
        )
    else:
        completed = subprocess.run(
            [binary, *sys.argv[1:]],
            input=stdin,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
    stdout_json = parse_output(completed.stdout)
    stderr_json = parse_output(completed.stderr)
    document = os.environ.get("MARGIN_EVAL_DOCUMENT_REALPATH")
    record = {
        "argv": normalize_argv(sys.argv[1:], document),
        "changed": recursive_first(stdout_json, "changed"),
        "durationMs": round((time.monotonic() - started) * 1000, 3),
        "errorCode": recursive_first(stderr_json, "code"),
        "exitCode": completed.returncode,
        "revision": recursive_first(stdout_json, "revision"),
        "schema": "urn:margin:cli-eval-command:v1",
        "stderr": {"bytes": len(completed.stderr), "sha256": digest(completed.stderr)},
        "stdin": None if stdin is None else {"bytes": len(stdin), "sha256": digest(stdin)},
        "stdout": {"bytes": len(completed.stdout), "sha256": digest(completed.stdout)},
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }
    append(Path(log_path), record)
    sys.stdout.buffer.write(completed.stdout)
    sys.stderr.buffer.write(completed.stderr)
    return completed.returncode


if __name__ == "__main__":
    raise SystemExit(main())
