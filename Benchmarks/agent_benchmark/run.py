#!/usr/bin/env python3
"""Run or dry-run the fixed Margin CLI benchmark through Prime Agent."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

sys.dont_write_bytecode = True
from score import render_markdown, score


ROOT = Path(__file__).resolve().parents[2]
BENCHMARK_DIR = Path(__file__).resolve().parent
FIXTURE = ROOT / "Fixtures" / "agent-benchmark" / "atlas-launch-review.md"
EXPECTED = ROOT / "Fixtures" / "agent-benchmark" / "expected.json"
TASK = BENCHMARK_DIR / "task.md"
MODELS = BENCHMARK_DIR / "models.json"
PROXY = BENCHMARK_DIR / "margin_proxy.py"
SCORER = BENCHMARK_DIR / "score.py"
PAID_CONFIRMATION = "RUN_PAID_MODELS"


def file_hash(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_models() -> list[dict[str, str]]:
    payload = json.loads(MODELS.read_text(encoding="utf-8"))
    return [item for item in payload["models"] if isinstance(item, dict)]


def canonical_model(item: dict[str, str]) -> str:
    return f"{item['provider']}/{item['model']}"


def resolve_models(requested: list[str], run_all: bool) -> list[dict[str, str]]:
    available = load_models()
    if run_all:
        return available
    if not requested:
        return []
    by_name = {canonical_model(item): item for item in available}
    selected: list[dict[str, str]] = []
    for name in requested:
        if name not in by_name:
            raise ValueError(f"Unknown benchmark model '{name}'.")
        selected.append(by_name[name])
    return selected


def find_margin_binary(explicit: Path | None) -> Path | None:
    candidates: list[Path] = []
    if explicit:
        candidates.append(explicit.expanduser())
    installed = shutil.which("margin")
    if installed:
        candidates.append(Path(installed))
    candidates.extend([
        ROOT / ".build" / "release" / "margin-cli",
        ROOT / ".build" / "debug" / "margin-cli",
    ])
    for candidate in candidates:
        if candidate.exists() and os.access(candidate, os.X_OK):
            return candidate.resolve()
    return None


def margin_readiness(binary: Path | None) -> dict[str, Any]:
    if binary is None:
        return {"path": None, "ready": False, "reason": "binary_not_found"}
    try:
        completed = subprocess.run(
            [str(binary), "--help"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        return {"path": str(binary), "ready": False, "reason": type(error).__name__}
    text = (completed.stdout + completed.stderr).decode("utf-8", errors="replace").lower()
    required = ["inspect", "outline", "slice", "comments"]
    return {
        "exitCode": completed.returncode,
        "helpSha256": hashlib.sha256(completed.stdout + completed.stderr).hexdigest(),
        "path": str(binary),
        "ready": completed.returncode == 0 and all(word in text for word in required),
        "reason": None if completed.returncode == 0 else "help_failed",
    }


def model_readiness(prime_agent: str | None, model: dict[str, str]) -> dict[str, Any]:
    if not prime_agent:
        return {"available": False, "model": canonical_model(model), "reason": "prime_agent_not_found"}
    completed = subprocess.run(
        [prime_agent, "model", "list", model["model"]],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
        timeout=15,
    )
    output = (completed.stdout + completed.stderr).decode("utf-8", errors="replace")
    available = completed.returncode == 0 and model["provider"] in output and model["model"] in output
    return {
        "available": available,
        "exitCode": completed.returncode,
        "model": canonical_model(model),
        "outputSha256": hashlib.sha256(completed.stdout + completed.stderr).hexdigest(),
    }


def validate_fixture() -> dict[str, Any]:
    expected = json.loads(EXPECTED.read_text(encoding="utf-8"))
    text = FIXTURE.read_text(encoding="utf-8")
    quote = expected["comments"]["quote"]["anchorExact"]
    range_text = expected["comments"]["range"]["anchorExact"]
    ambiguous = expected["comments"]["ambiguous_second"]["anchorExact"]
    valid = text.count(quote) == 1 and text.count(range_text) == 1 and text.count(ambiguous) == 2
    with tempfile.TemporaryDirectory(prefix="margin-benchmark-dry-") as temporary:
        copy = Path(temporary) / "review.md"
        shutil.copy2(FIXTURE, copy)
        isolated_copy = copy.read_bytes() == FIXTURE.read_bytes()
    return {
        "fixtureSha256": file_hash(FIXTURE),
        "isolatedCopy": isolated_copy,
        "quoteOccurrences": text.count(quote),
        "rangeOccurrences": text.count(range_text),
        "sharedSignalOccurrences": text.count(ambiguous),
        "valid": valid and isolated_copy,
    }


def usage_metrics(jsonl: bytes) -> dict[str, Any]:
    messages: list[dict[str, Any]] = []
    event_counts: dict[str, int] = {}

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
        if event_type == "message_update":
            update = event.get("assistantMessageEvent")
            update_type = update.get("type") if isinstance(update, dict) else None
            if isinstance(update_type, str):
                key = f"message_update.{update_type}"
                event_counts[key] = event_counts.get(key, 0) + 1
        if event_type != "message_end":
            continue
        message = event.get("message")
        if not isinstance(message, dict) or message.get("role") != "assistant":
            continue
        usage = message.get("usage")
        if isinstance(usage, dict):
            messages.append(usage)

    totals = {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0, "cost": 0.0}
    for usage in messages:
        for key in ("input", "output", "cacheRead", "cacheWrite"):
            value = usage.get(key)
            if isinstance(value, (int, float)):
                totals[key] += int(value)
        cost = usage.get("cost")
        if isinstance(cost, dict) and isinstance(cost.get("total"), (int, float)):
            totals["cost"] += float(cost["total"])
    totals["assistantMessages"] = len(messages)
    totals["eventCounts"] = event_counts
    return totals


def safe_slug(value: str) -> str:
    return "".join(character if character.isalnum() else "-" for character in value).strip("-").lower()


def run_process(command: list[str], environment: dict[str, str], timeout_seconds: int) -> tuple[int, bytes, bytes, bool]:
    process = subprocess.Popen(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=environment,
        start_new_session=True,
    )
    try:
        stdout, stderr = process.communicate(timeout=timeout_seconds + 30)
        return process.returncode, stdout, stderr, False
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            stdout, stderr = process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            stdout, stderr = process.communicate()
        return 124, stdout, stderr, True


def run_one(
    model: dict[str, str],
    margin_binary: Path,
    prime_agent: str,
    runs_dir: Path,
    token_budget: int,
    timeout_seconds: int,
    max_turns: int,
    thinking: str,
) -> Path:
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    run_dir = runs_dir / f"{stamp}-{safe_slug(canonical_model(model))}"
    workspace = run_dir / "workspace"
    proxy_bin = run_dir / "bin"
    workspace.mkdir(parents=True)
    proxy_bin.mkdir(parents=True)
    document = workspace / "review.md"
    shutil.copy2(FIXTURE, document)
    proxy = proxy_bin / "margin"
    shutil.copy2(PROXY, proxy)
    proxy.chmod(0o755)

    command_log = run_dir / "command-log.jsonl"
    task_text = TASK.read_text(encoding="utf-8")
    gate_command = " ".join([
        shlex.quote(sys.executable),
        shlex.quote(str(SCORER)),
        "--run-dir", shlex.quote(str(run_dir)),
        "--margin-bin", shlex.quote(str(margin_binary)),
        "--no-write",
    ])
    command = [
        prime_agent,
        "--print",
        "--mode", "json",
        "--cwd", str(workspace),
        "--provider", model["provider"],
        "--model", model["model"],
        "--thinking", thinking,
        "--no-session",
        "--no-context-files",
        "--no-skills",
        "--no-prompt-templates",
        "--autonomous",
        "--autonomous-gate", gate_command,
        "--autonomous-gate-retries", str(max(12, max_turns * 4)),
        "--autonomous-gate-timeout-ms", "30000",
        "--autonomous-max-continuations", "2",
        "--autonomous-max-turns", str(max_turns),
        "--autonomous-max-tokens", str(token_budget),
        "--autonomous-timeout-ms", str(timeout_seconds * 1000),
        "--",
        task_text,
    ]
    environment = os.environ.copy()  # Prime Agent consumes the user's existing auth implicitly.
    environment["PATH"] = f"{proxy_bin}{os.pathsep}{environment.get('PATH', '')}"
    environment["MARGIN_BENCH_REAL_BIN"] = str(margin_binary)
    environment["MARGIN_BENCH_COMMAND_LOG"] = str(command_log)
    environment["MARGIN_ACTOR_ID"] = f"urn:margin:benchmark:{safe_slug(canonical_model(model))}"
    environment["MARGIN_ACTOR_NAME"] = f"Benchmark {canonical_model(model)}"
    environment["MARGIN_ACTOR_TYPE"] = "software"

    started = time.monotonic()
    started_at = datetime.now(timezone.utc).isoformat()
    exit_code, stdout, stderr, timed_out = run_process(command, environment, timeout_seconds)
    duration = time.monotonic() - started

    benchmark_score = score(run_dir, margin_binary)
    (run_dir / "score.json").write_text(json.dumps(benchmark_score, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    (run_dir / "report.md").write_text(render_markdown(benchmark_score), encoding="utf-8")
    metadata = {
        "budget": {"maxTokens": token_budget, "maxTurns": max_turns, "timeoutSeconds": timeout_seconds},
        "durationSeconds": round(duration, 3),
        "finishedAt": datetime.now(timezone.utc).isoformat(),
        "fixtureSha256": file_hash(FIXTURE),
        "model": canonical_model(model),
        "primeAgentExitCode": exit_code,
        "promptSha256": file_hash(TASK),
        "schema": "urn:margin:agent-benchmark-run:v1",
        "startedAt": started_at,
        "stderr": {"bytes": len(stderr), "sha256": hashlib.sha256(stderr).hexdigest()},
        "stdout": {"bytes": len(stdout), "sha256": hashlib.sha256(stdout).hexdigest()},
        "thinking": thinking,
        "timedOut": timed_out,
        "usage": usage_metrics(stdout),
    }
    (run_dir / "run.json").write_text(json.dumps(metadata, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return run_dir


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--dry-run", action="store_true", help="Validate the harness without invoking a model.")
    mode.add_argument("--execute", action="store_true", help="Invoke paid/remote models.")
    selection = parser.add_mutually_exclusive_group()
    selection.add_argument("--all", action="store_true")
    selection.add_argument("--model", action="append", default=[], help="Canonical provider/model from models.json.")
    parser.add_argument("--confirm-paid", default="", help=f"Must equal {PAID_CONFIRMATION} with --execute.")
    parser.add_argument("--margin-bin", type=Path)
    parser.add_argument("--runs-dir", type=Path, default=BENCHMARK_DIR / "runs")
    parser.add_argument("--token-budget", type=int, default=24_000)
    parser.add_argument("--timeout-seconds", type=int, default=420)
    parser.add_argument("--max-turns", type=int, default=8)
    parser.add_argument("--thinking", choices=("off", "minimal", "low", "medium", "high", "xhigh", "max"), default="medium")
    arguments = parser.parse_args()

    if min(arguments.token_budget, arguments.timeout_seconds, arguments.max_turns) <= 0:
        parser.error("Budget and timeout values must be positive.")
    try:
        selected = resolve_models(arguments.model, arguments.all)
    except ValueError as error:
        parser.error(str(error))
    if not selected:
        selected = load_models() if not arguments.execute else []
    if arguments.execute and not selected:
        parser.error("Select --all or at least one --model for an execution.")
    if arguments.execute and arguments.confirm_paid != PAID_CONFIRMATION:
        parser.error(f"Paid execution requires --confirm-paid {PAID_CONFIRMATION}.")

    prime_agent = shutil.which("prime-agent")
    margin_binary = find_margin_binary(arguments.margin_bin)
    readiness = margin_readiness(margin_binary)
    preflight = {
        "fixture": validate_fixture(),
        "margin": readiness,
        "models": [model_readiness(prime_agent, item) for item in selected],
        "paidModelsInvoked": False,
        "primeAgentPath": prime_agent,
        "schema": "urn:margin:agent-benchmark-dry-run:v1",
        "taskSha256": file_hash(TASK),
    }

    if not arguments.execute:
        print(json.dumps(preflight, indent=2, sort_keys=True))
        return 0 if preflight["fixture"]["valid"] and prime_agent else 1
    if not readiness["ready"] or margin_binary is None:
        print(json.dumps(preflight, indent=2, sort_keys=True), file=sys.stderr)
        print("Refusing paid runs until the complete Margin CLI passes its help preflight.", file=sys.stderr)
        return 2
    unavailable = [item["model"] for item in preflight["models"] if not item["available"]]
    if unavailable:
        print(f"Unavailable configured models: {', '.join(unavailable)}", file=sys.stderr)
        return 2
    assert prime_agent is not None

    arguments.runs_dir.mkdir(parents=True, exist_ok=True)
    completed: list[str] = []
    for item in selected:
        run_dir = run_one(
            item,
            margin_binary,
            prime_agent,
            arguments.runs_dir.resolve(),
            arguments.token_budget,
            arguments.timeout_seconds,
            arguments.max_turns,
            arguments.thinking,
        )
        completed.append(str(run_dir))
        print(json.dumps({"completed": str(run_dir), "model": canonical_model(item)}))
    print(json.dumps({"paidModelsInvoked": True, "runs": completed}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
