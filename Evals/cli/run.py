#!/usr/bin/env python3
"""Run the reproducible Margin CLI agent-evaluation matrix through Prime Agent."""

from __future__ import annotations

import argparse
import json
import os
import platform
import shlex
import shutil
import signal
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

sys.dont_write_bytecode = True
from eval_lib import (  # noqa: E402
    EVAL_DIR,
    EvalError,
    canonical_model,
    find_margin_binary,
    git_is_dirty,
    git_revision,
    harness_fingerprint,
    load_models,
    load_suite,
    prepare_case,
    safe_slug,
    scenario_fingerprint,
    sha256_bytes,
    sha256_file,
    usage_and_trace,
    utc_now,
)
from report import aggregate, render  # noqa: E402
from score import render_markdown, score_case  # noqa: E402


PAID_CONFIRMATION = "RUN_PAID_EVALS"


def resolve_models(requested: list[str], run_all: bool) -> list[dict[str, str]]:
    available = load_models()
    if run_all:
        return available
    if not requested:
        return []
    by_name: dict[str, dict[str, str]] = {}
    for item in available:
        by_name[canonical_model(item)] = item
        by_name.setdefault(item["model"], item)
    result: list[dict[str, str]] = []
    for name in requested:
        if name not in by_name:
            raise EvalError(f"Unknown eval model {name!r}.")
        if by_name[name] not in result:
            result.append(by_name[name])
    return result


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
    output = completed.stdout + completed.stderr
    text = output.decode("utf-8", errors="replace").lower()
    required = ["inspect", "outline", "slice", "review", "comments"]
    return {
        "exitCode": completed.returncode,
        "helpSha256": sha256_bytes(output),
        "path": str(binary),
        "ready": completed.returncode == 0 and all(item in text for item in required),
        "reason": None if completed.returncode == 0 else "help_failed",
    }


def model_readiness(prime_agent: str | None, model: dict[str, str]) -> dict[str, Any]:
    name = canonical_model(model)
    if not prime_agent:
        return {"available": False, "model": name, "reason": "prime_agent_not_found"}
    try:
        completed = subprocess.run(
            [prime_agent, "model", "list", model["model"]],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=20,
        )
    except subprocess.TimeoutExpired:
        return {"available": False, "model": name, "reason": "readiness_timeout"}
    output = completed.stdout + completed.stderr
    text = output.decode("utf-8", errors="replace")
    return {
        "available": completed.returncode == 0 and model["provider"] in text and model["model"] in text,
        "exitCode": completed.returncode,
        "model": name,
        "outputSha256": sha256_bytes(output),
    }


def executable_version(executable: str) -> str | None:
    try:
        completed = subprocess.run(
            [executable, "--version"],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
            timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    value = completed.stdout.decode("utf-8", errors="replace").strip()
    return value if completed.returncode == 0 and value else None


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


def load_jsonl(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    result: list[dict[str, Any]] = []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict):
            result.append(value)
    return result


def repair_cycles(gates: list[dict[str, Any]], commands: list[dict[str, Any]]) -> int:
    command_times = [str(item.get("timestamp")) for item in commands if isinstance(item.get("timestamp"), str)]
    cycles = 0
    for gate in gates:
        failures = gate.get("gateFailedCheckIDs", gate.get("failedCheckIDs", []))
        if not failures:
            continue
        timestamp = gate.get("timestamp")
        if isinstance(timestamp, str) and any(command_time > timestamp for command_time in command_times):
            cycles += 1
    return cycles


def telemetry_integrity(gates: list[dict[str, Any]], commands: list[dict[str, Any]]) -> dict[str, Any]:
    gate_counts = [int(item["commandCount"]) for item in gates if isinstance(item.get("commandCount"), int)]
    attempts = [int(item["attempt"]) for item in gates if isinstance(item.get("attempt"), int)]
    reasons: list[str] = []
    if gate_counts and len(commands) < max(gate_counts):
        reasons.append("command_log_shrank_after_gate")
    if attempts and attempts != list(range(1, len(attempts) + 1)):
        reasons.append("gate_history_sequence_invalid")
    return {
        "commandCount": len(commands),
        "gateCommandCountMaximum": max(gate_counts) if gate_counts else None,
        "gateCount": len(gates),
        "ok": not reasons,
        "reasons": reasons,
        "schema": "urn:margin:cli-eval-integrity:v1",
    }


def trace_cap(scenario: Any) -> int:
    caps = [
        int(item.get("maxScore", 100))
        for item in scenario.manifest.get("caps", [])
        if item.get("ifCheckFails") == "cli_only_policy"
    ]
    return min(caps) if caps else 100


def adjust_first_pass_for_trace(
    score_value: int,
    failed_check_ids: list[str],
    checks: list[dict[str, Any]],
    trace: dict[str, Any],
    scenario: Any,
) -> tuple[int, list[str]]:
    failed = list(failed_check_ids)
    if trace.get("policyCompliant", True):
        return score_value, failed
    policy_check = next((item for item in checks if item["id"] == "cli_only_policy"), None)
    if policy_check and "cli_only_policy" not in failed:
        score_value = max(0, score_value - int(policy_check["possible"]))
        failed.append("cli_only_policy")
    return min(score_value, trace_cap(scenario)), failed


def run_one(
    *,
    scenario: Any,
    model: dict[str, str],
    repetition: int,
    run_dir: Path,
    margin_binary: Path,
    prime_agent: str,
    token_budget: int,
    timeout_seconds: int,
    max_turns: int,
    max_continuations: int,
    thinking: str,
) -> dict[str, Any]:
    document = prepare_case(scenario, run_dir, margin_binary)
    bin_dir = run_dir / "bin"
    bin_dir.mkdir()
    proxy = bin_dir / "margin"
    shutil.copy2(EVAL_DIR / "proxy.py", proxy)
    proxy.chmod(0o755)
    command_log = run_dir / "command-log.jsonl"

    gate_command = " ".join([
        shlex.quote(sys.executable),
        shlex.quote(str(EVAL_DIR / "gate.py")),
        "--case-dir", shlex.quote(str(run_dir)),
        "--scenario", shlex.quote(scenario.id),
        "--margin-bin", shlex.quote(str(margin_binary)),
    ])
    prompt = scenario.prompt.read_text(encoding="utf-8")
    command = [
        prime_agent,
        "--print",
        "--mode", "json",
        "--cwd", str(document.parent),
        "--offline",
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
        "--autonomous-max-continuations", str(max_continuations),
        "--autonomous-max-turns", str(max_turns),
        "--autonomous-max-tokens", str(token_budget),
        "--autonomous-timeout-ms", str(timeout_seconds * 1000),
        "--",
        prompt,
    ]
    environment = os.environ.copy()
    environment["PATH"] = f"{bin_dir}{os.pathsep}{environment.get('PATH', '')}"
    environment["MARGIN_EVAL_REAL_BIN"] = str(margin_binary)
    environment["MARGIN_EVAL_COMMAND_LOG"] = str(command_log)
    environment["MARGIN_EVAL_DOCUMENT_REALPATH"] = str(document.resolve())
    environment["MARGIN_EVAL_HEADLESS"] = "1"
    actor_slug = safe_slug(f"{canonical_model(model)}-{scenario.id}-r{repetition}")
    environment["MARGIN_ACTOR_ID"] = f"urn:margin:eval:{actor_slug}"
    environment["MARGIN_ACTOR_NAME"] = f"Eval {canonical_model(model)}"
    environment["MARGIN_ACTOR_TYPE"] = "software"

    started_at = utc_now()
    started = time.monotonic()
    exit_code, stdout, stderr, timed_out = run_process(command, environment, timeout_seconds)
    duration = time.monotonic() - started
    usage, trace = usage_and_trace(stdout)
    (run_dir / "trace.json").write_text(json.dumps(trace, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    gate_history = load_jsonl(run_dir / "gate-history.jsonl")
    command_history = load_jsonl(command_log)
    integrity = telemetry_integrity(gate_history, command_history)
    (run_dir / "integrity.json").write_text(json.dumps(integrity, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    score = score_case(run_dir, scenario, margin_binary)
    (run_dir / "score.json").write_text(json.dumps(score, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    (run_dir / "report.md").write_text(render_markdown(score), encoding="utf-8")

    repairs = repair_cycles(gate_history, command_history)
    first_pass = int(gate_history[0].get("score", 0)) if gate_history else int(score["score"])
    first_failed = list(gate_history[0].get("failedCheckIDs", [])) if gate_history else list(score["failedCheckIDs"])
    first_pass, first_failed = adjust_first_pass_for_trace(
        first_pass, first_failed, score["checks"], trace, scenario
    )
    if not integrity["ok"]:
        first_pass = min(first_pass, 30)
        if "telemetry_integrity" not in first_failed:
            first_failed.append("telemetry_integrity")
    failed_checks = {item["id"]: item for item in score["checks"]}
    protocol_valid = bool(failed_checks.get("protocol_validation", {}).get("passed", True))
    run_metadata = {
        "budget": {
            "maxContinuations": max_continuations,
            "maxTokens": token_budget,
            "maxTurns": max_turns,
            "timeoutSeconds": timeout_seconds,
        },
        "durationSeconds": round(duration, 3),
        "finishedAt": utc_now(),
        "gateAttempts": len(gate_history),
        "model": canonical_model(model),
        "primeAgentExitCode": exit_code,
        "promptSha256": sha256_file(scenario.prompt),
        "schema": "urn:margin:cli-eval-run:v1",
        "startedAt": started_at,
        "stderr": {"bytes": len(stderr), "sha256": sha256_bytes(stderr)},
        "stdout": {"bytes": len(stdout), "sha256": sha256_bytes(stdout)},
        "thinking": thinking,
        "timedOut": timed_out,
        "usage": usage,
    }
    (run_dir / "run.json").write_text(json.dumps(run_metadata, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return {
        "budget": run_metadata["budget"],
        "commandCount": score["commandCount"],
        "dimensions": score["dimensions"],
        "durationSeconds": round(duration, 3),
        "failedCheckIDs": score["failedCheckIDs"],
        "finalScore": score["score"],
        "firstPassDimensions": gate_history[0].get("dimensions", {}) if gate_history else score["dimensions"],
        "firstPassFailedCheckIDs": first_failed,
        "firstPassScore": first_pass,
        "gateAttempts": len(gate_history),
        "model": canonical_model(model),
        "policyCompliant": bool(trace.get("policyCompliant", True)),
        "primeAgentExitCode": exit_code,
        "protocolValid": protocol_valid,
        "repairAttempts": repairs,
        "repetition": repetition,
        "runDir": str(run_dir),
        "scenario": scenario.id,
        "sourcePreserved": bool(score["sourcePreserved"]),
        "telemetryIntegrity": bool(integrity["ok"]),
        "thinking": thinking,
        "timedOut": timed_out,
        "usage": usage,
        "weight": scenario.weight,
    }


def self_test(scenarios: list[Any], binary: Path) -> tuple[int, dict[str, Any]]:
    command = [sys.executable, str(EVAL_DIR / "self_test.py"), "--margin-bin", str(binary)]
    for scenario in scenarios:
        command.extend(["--scenario", scenario.id])
    completed = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False, timeout=90)
    try:
        result = json.loads(completed.stdout.decode("utf-8"))
    except json.JSONDecodeError:
        result = {
            "error": completed.stderr.decode("utf-8", errors="replace")[:1000],
            "passed": False,
        }
    return completed.returncode, result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--execute", action="store_true", help="Invoke paid/remote model runs.")
    parser.add_argument("--confirm-paid", default="", help=f"Must equal {PAID_CONFIRMATION} with --execute.")
    parser.add_argument("--scenario", action="append", default=[])
    model_group = parser.add_mutually_exclusive_group()
    model_group.add_argument("--model", action="append", default=[])
    model_group.add_argument("--all-models", action="store_true")
    parser.add_argument("--margin-bin", type=Path)
    parser.add_argument("--runs-dir", type=Path, default=EVAL_DIR / "runs")
    parser.add_argument("--experiment", default="baseline")
    parser.add_argument("--repetitions", type=int, default=1)
    parser.add_argument("--repetition-start", type=int, default=1, help="First repetition index, for extending an existing matrix.")
    parser.add_argument("--token-budget", type=int, default=32_000)
    parser.add_argument("--timeout-seconds", type=int, default=420)
    parser.add_argument("--max-turns", type=int, default=20)
    parser.add_argument("--max-continuations", type=int, default=2)
    parser.add_argument("--thinking", choices=("off", "minimal", "low", "medium", "high", "xhigh", "max"), default="medium")
    parser.add_argument("--fail-under", type=float)
    arguments = parser.parse_args()
    try:
        if min(arguments.repetitions, arguments.repetition_start, arguments.token_budget, arguments.timeout_seconds, arguments.max_turns, arguments.max_continuations) <= 0:
            raise EvalError("Repetitions and all execution budgets must be positive.")
        scenarios = load_suite(arguments.scenario)
        models = resolve_models(arguments.model, arguments.all_models)
        if arguments.execute and not models:
            raise EvalError("Paid execution requires --model or --all-models.")
        if arguments.execute and arguments.confirm_paid != PAID_CONFIRMATION:
            raise EvalError(f"Paid execution requires --confirm-paid {PAID_CONFIRMATION}.")
        if not arguments.execute and not models:
            models = load_models()
        margin_binary = find_margin_binary(arguments.margin_bin)
        readiness = margin_readiness(margin_binary)
        prime_agent = shutil.which("prime-agent")
        model_checks = [model_readiness(prime_agent, model) for model in models]
        preflight: dict[str, Any] = {
            "margin": readiness,
            "models": model_checks,
            "paidModelsInvoked": False,
            "primeAgentPath": prime_agent,
            "primeAgentVersion": executable_version(prime_agent) if prime_agent else None,
            "harnessSha256": harness_fingerprint(),
            "scenarioHashes": {scenario.id: scenario_fingerprint(scenario) for scenario in scenarios},
            "schema": "urn:margin:cli-eval-preflight:v1",
        }
        if margin_binary is None or not readiness["ready"]:
            print(json.dumps(preflight, indent=2, sort_keys=True), file=sys.stderr)
            return 2
        test_code, test_result = self_test(scenarios, margin_binary)
        preflight["selfTest"] = test_result
        if not arguments.execute:
            print(json.dumps(preflight, indent=2, sort_keys=True))
            return 0 if test_code == 0 and prime_agent else 1
        if test_code != 0:
            print(json.dumps(preflight, indent=2, sort_keys=True), file=sys.stderr)
            return 2
        unavailable = [item["model"] for item in model_checks if not item.get("available")]
        if not prime_agent or unavailable:
            preflight["unavailableModels"] = unavailable
            print(json.dumps(preflight, indent=2, sort_keys=True), file=sys.stderr)
            return 2

        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
        set_dir = arguments.runs_dir.resolve() / f"{stamp}-{safe_slug(arguments.experiment)}"
        set_dir.mkdir(parents=True, exist_ok=False)
        runs: list[dict[str, Any]] = []
        for model in models:
            for scenario in scenarios:
                for repetition in range(arguments.repetition_start, arguments.repetition_start + arguments.repetitions):
                    run_dir = set_dir / safe_slug(canonical_model(model)) / scenario.id / f"r{repetition:02d}"
                    result = run_one(
                        scenario=scenario,
                        model=model,
                        repetition=repetition,
                        run_dir=run_dir,
                        margin_binary=margin_binary,
                        prime_agent=prime_agent,
                        token_budget=arguments.token_budget,
                        timeout_seconds=arguments.timeout_seconds,
                        max_turns=arguments.max_turns,
                        max_continuations=arguments.max_continuations,
                        thinking=arguments.thinking,
                    )
                    result["runDir"] = str(run_dir.relative_to(set_dir))
                    runs.append(result)
                    print(json.dumps({
                        "finalScore": result["finalScore"],
                        "firstPassScore": result["firstPassScore"],
                        "model": result["model"],
                        "scenario": result["scenario"],
                    }, sort_keys=True), flush=True)

        payload: dict[str, Any] = {
            "metadata": {
                "createdAt": utc_now(),
                "experiment": arguments.experiment,
                "gitRevision": git_revision(),
                "repositoryDirty": git_is_dirty(),
                "host": {"machine": platform.machine(), "macOS": platform.mac_ver()[0]},
                "harnessSha256": preflight["harnessSha256"],
                "marginBinary": str(margin_binary),
                "marginBinarySha256": sha256_file(margin_binary),
                "marginHelpSha256": readiness.get("helpSha256"),
                "paidModelsInvoked": True,
                "primeAgentPath": prime_agent,
                "primeAgentVersion": preflight["primeAgentVersion"],
                "python": platform.python_version(),
                "scenarioHashes": preflight["scenarioHashes"],
                "thinking": arguments.thinking,
            },
            "runs": runs,
            "schema": "urn:margin:cli-eval-set:v1",
        }
        payload["aggregate"] = aggregate(payload)
        output = set_dir / "eval-set.json"
        output.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        (set_dir / "report.md").write_text(render(payload), encoding="utf-8")
        print(json.dumps({
            "evalSet": str(output),
            "finalScore": payload["aggregate"]["overall"]["finalScore"],
            "firstPassScore": payload["aggregate"]["overall"]["firstPassScore"],
            "paidModelsInvoked": True,
            "runs": len(runs),
        }, indent=2, sort_keys=True))
        if arguments.fail_under is not None and payload["aggregate"]["overall"]["finalScore"] < arguments.fail_under:
            return 1
        return 0
    except (EvalError, OSError, subprocess.TimeoutExpired) as error:
        print(json.dumps({"error": str(error), "ok": False}, indent=2), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
