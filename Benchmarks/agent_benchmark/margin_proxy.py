#!/usr/bin/env python3
"""A transparent Margin proxy that records command shape and exit status, never output."""

from __future__ import annotations

import fcntl
import json
import os
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path


SENSITIVE_WORDS = ("key", "token", "secret", "password", "authorization", "credential")


def is_sensitive_flag(value: str) -> bool:
    lowered = value.lower().lstrip("-")
    return any(word in lowered for word in SENSITIVE_WORDS)


def redacted_arguments(arguments: list[str]) -> list[str]:
    result: list[str] = []
    redact_next = False
    for argument in arguments:
        if redact_next:
            result.append("<redacted>")
            redact_next = False
            continue
        if argument.startswith("-") and "=" in argument:
            name, _value = argument.split("=", 1)
            if is_sensitive_flag(name):
                result.append(f"{name}=<redacted>")
                continue
        result.append(argument)
        if argument.startswith("-") and is_sensitive_flag(argument):
            redact_next = True
    return result


def append_record(path: Path, record: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
        handle.write(json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n")
        handle.flush()
        os.fsync(handle.fileno())
        fcntl.flock(handle.fileno(), fcntl.LOCK_UN)


def main() -> int:
    real_binary = os.environ.get("MARGIN_BENCH_REAL_BIN")
    log_path = os.environ.get("MARGIN_BENCH_COMMAND_LOG")
    if not real_binary or not log_path:
        print("margin benchmark proxy is missing its runner configuration", file=sys.stderr)
        return 78

    resolved_binary = str(Path(real_binary).expanduser().resolve())
    if resolved_binary == str(Path(__file__).resolve()):
        print("margin benchmark proxy cannot invoke itself", file=sys.stderr)
        return 78

    arguments = sys.argv[1:]
    child_environment = os.environ.copy()
    child_environment.pop("MARGIN_BENCH_REAL_BIN", None)
    child_environment.pop("MARGIN_BENCH_COMMAND_LOG", None)
    started = time.monotonic()
    try:
        completed = subprocess.run(
            [resolved_binary, *arguments],
            env=child_environment,
            check=False,
        )
        exit_code = completed.returncode
    except OSError as error:
        print(f"could not execute Margin: {error}", file=sys.stderr)
        exit_code = 74

    append_record(
        Path(log_path),
        {
            "argv": redacted_arguments(arguments),
            "durationMs": round((time.monotonic() - started) * 1000, 3),
            "exitCode": exit_code,
            "timestamp": datetime.now(timezone.utc).isoformat(),
        },
    )
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
