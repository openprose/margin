#!/usr/bin/env python3
"""Budget-gated Prime Verifiers v1 runner with redacted output.

Without --execute this prints the complete, no-model spend plan. A paid run also
requires the literal confirmation token and writes raw Prime traces only under
the ignored local runs directory.
"""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from collections import Counter
from dataclasses import asdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

sys.dont_write_bytecode = True
PACKAGE_ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(PACKAGE_ROOT))

from marginbench.candidates import CandidateManifest  # noqa: E402
from marginbench.budget_proxy import InferenceBudgetPolicy, InferenceBudgetProxy  # noqa: E402
from marginbench.controls import DEFAULT_CONTROL_PROFILE, require_implemented_profile  # noqa: E402
from marginbench.provenance import implementation_sha256  # noqa: E402
from marginbench.scenarios import SCENARIO_IDS, generate_episode  # noqa: E402
from marginbench.entropy import PUBLIC_DEVELOPMENT_KEY  # noqa: E402
from marginbench.keys import read_holdout_key  # noqa: E402
from marginbench.validation import MAX_ARTIFACT_BYTES, validate_bytes  # noqa: E402


CONFIRMATION = "RUN_PAID_MARGINBENCH"
HARD_MAX_COST_USD = 15.0
BENCHMARK_VERSION = "0.1.0"
DEFAULT_PRIME_INFERENCE_URL = "https://api.pinference.ai/api/v1"
PROXY_API_KEY_ENV = "MARGINBENCH_PROXY_TOKEN"
MAX_PRIME_CONFIG_BYTES = 1024 * 1024


def canonical(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _require_fresh_output_targets(
    output: Path,
    summary: Path | None,
    run_manifest: Path | None,
) -> None:
    """Fail before a paid start if any durable output could be replaced."""
    original_named = [path.expanduser() for path in (summary, run_manifest) if path is not None]
    named = [path.resolve(strict=False) for path in original_named]
    if len(named) != len(set(named)):
        raise ValueError("Summary and run manifest must use distinct paths.")
    originals = (output.expanduser(), *original_named)
    for original in originals:
        path = original.resolve(strict=False)
        if original.is_symlink() or path.exists():
            raise ValueError(f"Refusing to replace an existing output: {original}")


def _write_new_artifact(path: Path, raw: bytes, *, mode: int = 0o600) -> None:
    """Publish a complete new artifact atomically without replacing another file."""
    path = path.expanduser()
    if path.is_symlink():
        raise ValueError(f"Refusing to replace an existing output: {path}")
    path = path.resolve(strict=False)
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        os.fchmod(descriptor, mode)
        written = 0
        while written < len(raw):
            count = os.write(descriptor, raw[written:])
            if count <= 0:
                raise OSError("Artifact write did not make progress.")
            written += count
        os.fsync(descriptor)
        os.close(descriptor)
        descriptor = -1
        try:
            os.link(temporary, path, follow_symlinks=False)
        except FileExistsError as error:
            raise ValueError(f"Refusing to replace an existing output: {path}") from error
        if hasattr(os, "O_DIRECTORY"):
            directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def load_candidate_manifest(
    path: Path,
    *,
    binary: Path,
    candidate_id: str,
) -> CandidateManifest:
    target = path.expanduser().resolve()
    try:
        with target.open("rb") as handle:
            raw = handle.read(MAX_ARTIFACT_BYTES + 1)
    except OSError as error:
        raise ValueError("Candidate manifest could not be read.") from error
    receipt = validate_bytes(raw)
    if not receipt["valid"] or receipt["artifactSchema"] != "urn:marginbench:candidate:v1":
        details = "; ".join(receipt.get("errors", ())[:3])
        raise ValueError(details or "Candidate manifest is invalid.")
    value = CandidateManifest(**json.loads(raw))
    if value.id != candidate_id:
        raise ValueError("Candidate manifest ID does not match --candidate.")
    if value.margin_sha256 != sha256(binary):
        raise ValueError("Candidate manifest Margin digest does not match --margin-bin.")
    return value


def load_holdout_key(path: Path) -> tuple[str, str]:
    value, key_id = read_holdout_key(path)
    return value.decode("ascii"), key_id


def _candidate(arguments: argparse.Namespace) -> CandidateManifest:
    frozen = getattr(arguments, "frozen_candidate", None)
    if frozen is not None:
        return frozen
    repository = PACKAGE_ROOT.parent.parent
    manual = repository / "Sources" / "MarginCLI" / "MarginManual.swift"
    candidate_settings = {
        "adapter": "prime-verifiers-v1",
        "benchmarkVersion": BENCHMARK_VERSION,
        "budgetProxySha256": sha256(PACKAGE_ROOT / "marginbench" / "budget_proxy.py"),
        "gatewayAdapterSha256": sha256(PACKAGE_ROOT / "marginbench" / "servers" / "gateway.py"),
        "gatewayPolicySha256": sha256(PACKAGE_ROOT / "marginbench" / "gateway.py"),
        "scenarioProtocolSha256": sha256(PACKAGE_ROOT / "marginbench" / "scenarios.py"),
        "toolSurface": ["margin"],
        "controlProfile": arguments.control_profile,
    }
    return CandidateManifest.create(
        arguments.candidate,
        arguments.margin_bin,
        manual=manual if manual.is_file() else None,
        settings=candidate_settings,
    )


def _repetition_values(repetitions: int, repetition_ids: list[int] | None = None) -> list[int]:
    return list(repetition_ids) if repetition_ids else list(range(repetitions))


def agent_process_count(
    scenarios: list[str],
    repetitions: int,
    repetition_ids: list[int] | None = None,
) -> int:
    return sum(
        len(generate_episode(scenario, PUBLIC_DEVELOPMENT_KEY, repetition).roles)
        for repetition in _repetition_values(repetitions, repetition_ids)
        for scenario in scenarios
    )


def estimate_maximum_cost(
    scenarios: list[str],
    repetitions: int,
    max_turns: int,
    upstream_attempts_per_turn: int,
    input_token_ceiling_per_call: int,
    max_tokens_per_call: int,
    input_price_per_million: float,
    output_price_per_million: float,
    billing_overhead_usd_per_call: float,
    repetition_ids: list[int] | None = None,
) -> float:
    """Bound provider charges without mistaking Verifiers' soft caps for billing caps.

    Verifiers' ``max_input_tokens`` counts the deduplicated message graph and is
    checked between turns. Providers bill the complete prompt again on every
    call. The only honest pre-run USD ceiling therefore uses a separately
    asserted maximum billable prompt size for *each* possible model call.
    ``max_tokens_per_call`` is the hard sampling ceiling for each response.
    """
    role_runs = agent_process_count(scenarios, repetitions, repetition_ids)
    billable_call_attempts = max_turns * upstream_attempts_per_turn
    value = role_runs * billable_call_attempts * (
        input_token_ceiling_per_call * input_price_per_million / 1_000_000
        + max_tokens_per_call * output_price_per_million / 1_000_000
        + billing_overhead_usd_per_call
    )
    return round(value, 6)


def wallet(prime: Path) -> dict[str, Any]:
    completed = subprocess.run(
        [str(prime), "--plain", "wallet", "--limit", "5", "--output", "json"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=True,
        timeout=30,
    )
    payload = json.loads(completed.stdout)
    return {
        "balanceUSD": float(payload["balance_usd"]),
        "totalBillings": int(payload["total_billings"]),
    }


def load_prime_inference_credentials() -> tuple[str, str, str | None]:
    """Resolve Prime inference credentials without exposing them to the child runner."""
    config: dict[str, Any] = {}
    config_path = Path.home() / ".prime" / "config.json"
    if config_path.exists():
        if config_path.is_symlink() or config_path.stat().st_mode & 0o077:
            raise ValueError("Prime config must be a private regular file.")
        with config_path.open("rb") as handle:
            raw = handle.read(MAX_PRIME_CONFIG_BYTES + 1)
        if len(raw) > MAX_PRIME_CONFIG_BYTES:
            raise ValueError("Prime config exceeds its size limit.")
        try:
            value = json.loads(raw)
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise ValueError("Prime config is not valid JSON.") from error
        if not isinstance(value, dict):
            raise ValueError("Prime config must contain a JSON object.")
        config = value

    api_key = os.environ.get("PRIME_API_KEY") or config.get("api_key")
    inference_url = (
        os.environ.get("PRIME_INFERENCE_URL")
        or config.get("inference_url")
        or DEFAULT_PRIME_INFERENCE_URL
    )
    team_id = os.environ.get("PRIME_TEAM_ID") or config.get("team_id")
    if not isinstance(api_key, str) or not api_key:
        raise ValueError("Prime inference authentication is unavailable.")
    if not isinstance(inference_url, str) or not inference_url:
        raise ValueError("Prime inference URL is unavailable.")
    if team_id is not None and (not isinstance(team_id, str) or not team_id):
        raise ValueError("Prime team identity is invalid.")
    return inference_url, api_key, team_id


def claim_paid_start(path: Path, *, now: float, minimum_interval_seconds: float) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        previous_raw = os.read(descriptor, 128).decode("ascii", errors="ignore").strip()
        try:
            previous = float(previous_raw)
        except ValueError:
            previous = 0.0
        remaining = minimum_interval_seconds - (now - previous)
        if previous > 0 and remaining > 0:
            raise RuntimeError(
                f"paid-run cooldown has {remaining:.0f} seconds remaining; rerun later"
            )
        os.lseek(descriptor, 0, os.SEEK_SET)
        os.ftruncate(descriptor, 0)
        os.write(descriptor, f"{now:.6f}\n".encode("ascii"))
        os.fsync(descriptor)
    finally:
        fcntl.flock(descriptor, fcntl.LOCK_UN)
        os.close(descriptor)


def build_eval_command(
    arguments: argparse.Namespace,
    v1_eval: Path,
    output: Path,
    *,
    client_base_url: str | None = None,
    client_api_key_var: str | None = None,
) -> list[str]:
    if (client_base_url is None) != (client_api_key_var is None):
        raise ValueError("client base URL and API-key variable must be supplied together")
    repetition_ids = getattr(arguments, "repetition_id", None) or []
    task_count = len(arguments.scenario) * len(
        _repetition_values(arguments.repetitions, repetition_ids)
    )
    command = [
        str(v1_eval),
        "marginbench",
        "--model", arguments.model,
        "--num-tasks", str(task_count),
        "--num-rollouts", "1",
        "--max-concurrent", str(arguments.max_concurrent),
        "--push", "false",
        "--rich", "false",
        "--output-dir", str(output),
        "--env.taskset.scenario-ids", *arguments.scenario,
        "--env.taskset.repetitions", str(arguments.repetitions),
        "--env.taskset.margin-binary", str(arguments.margin_bin),
        "--env.taskset.control-profile", arguments.control_profile,
        "--sampling.temperature", str(arguments.temperature),
        "--sampling.max-tokens", str(arguments.max_tokens_per_call),
    ]
    if repetition_ids:
        command += ["--env.taskset.repetition-ids", *(str(value) for value in repetition_ids)]
    for role in ("author", "reviewer"):
        command += [
            f"--env.{role}.max-turns", str(arguments.max_turns),
            f"--env.{role}.max-input-tokens", str(arguments.max_input_tokens),
            f"--env.{role}.max-output-tokens", str(arguments.max_output_tokens),
            f"--env.{role}.max-total-tokens", str(arguments.max_total_tokens),
            f"--env.{role}.timeout.rollout", str(arguments.rollout_timeout_seconds),
        ]
    if client_base_url is not None and client_api_key_var is not None:
        command += [
            "--client.base-url", client_base_url,
            "--client.api-key-var", client_api_key_var,
        ]
    return command


def _summarize_traces(output: Path) -> dict[str, Any]:
    traces_path = output / "traces.jsonl"
    traces: list[dict[str, Any]] = []
    if traces_path.is_file():
        for line in traces_path.read_text(encoding="utf-8").splitlines():
            try:
                envelope = json.loads(line)
            except json.JSONDecodeError:
                continue
            traces.extend(item for item in envelope.get("traces", []) if isinstance(item, dict))
    episodes: dict[str, dict[str, Any]] = {}
    consistent = True
    for trace in traces:
        calls = trace.get("calls") if isinstance(trace.get("calls"), list) else []
        usage = {
            "modelCalls": len(calls),
            "promptTokens": sum(int(call.get("usage", {}).get("prompt_tokens", 0)) for call in calls),
            "completionTokens": sum(int(call.get("usage", {}).get("completion_tokens", 0)) for call in calls),
            "cachedInputTokens": sum(int(call.get("usage", {}).get("cached_input_tokens", 0)) for call in calls),
            "reasoningTokens": sum(int(call.get("usage", {}).get("reasoning_tokens", 0)) for call in calls),
            "reportedCostUSD": round(sum(float(call.get("usage", {}).get("cost", 0)) for call in calls), 6),
        }
        marginbench = trace.get("info", {}).get("marginbench", {})
        task_data = trace.get("task", {}).get("data", {})
        episode_id = marginbench.get("episodeID")
        if not isinstance(episode_id, str) or not episode_id:
            consistent = False
            continue
        task_name = task_data.get("name") if isinstance(task_data.get("name"), str) else ""
        seat = task_name.rsplit(":", 1)[-1] if ":" in task_name else "unknown"
        immutable_result = {
            "score": marginbench.get("score"),
            "safetyPassed": marginbench.get("safetyPassed"),
            "sourcePreserved": marginbench.get("sourcePreserved"),
            "commandCount": marginbench.get("commandCount"),
            "invalidCommandCount": marginbench.get("invalidCommandCount"),
            "durationMs": marginbench.get("durationMs"),
            "marginSha256": marginbench.get("marginSha256"),
            "checks": marginbench.get("checks"),
            "dimensions": marginbench.get("dimensions"),
        }
        if episode_id not in episodes:
            episodes[episode_id] = {
                "episodeID": episode_id,
                "scenario": task_data.get("scenario_id"),
                "repetition": task_data.get("repetition"),
                "fingerprint": task_data.get("fingerprint"),
                **immutable_result,
                "roleRuns": [],
                "usage": {
                    "modelCalls": 0,
                    "promptTokens": 0,
                    "completionTokens": 0,
                    "cachedInputTokens": 0,
                    "reasoningTokens": 0,
                    "reportedCostUSD": 0.0,
                },
            }
        episode = episodes[episode_id]
        if any(episode.get(key) != value for key, value in immutable_result.items()):
            consistent = False
        episode["roleRuns"].append({
            "seat": seat,
            "stopCondition": trace.get("stop_condition"),
            "usage": usage,
        })
        for key in (
            "modelCalls", "promptTokens", "completionTokens", "cachedInputTokens",
            "reasoningTokens",
        ):
            episode["usage"][key] += usage[key]
        episode["usage"]["reportedCostUSD"] = round(
            episode["usage"]["reportedCostUSD"] + usage["reportedCostUSD"],
            6,
        )
    summaries = []
    for episode_id in sorted(episodes):
        episode = episodes[episode_id]
        episode["roleRuns"].sort(key=lambda value: (value["seat"], value["stopCondition"] or ""))
        summaries.append(episode)
    return {
        "traceCount": len(traces),
        "episodeCount": len(summaries),
        "traceConsistencyPassed": consistent,
        "episodes": summaries,
    }


def _run_manifest(
    arguments: argparse.Namespace,
    trace_summary: dict[str, Any],
    *,
    status: str,
    started_at: str,
    duration_ms: int,
    observed_wallet_debit: float,
    live_budget: dict[str, Any] | None = None,
) -> dict[str, Any]:
    candidate = _candidate(arguments)
    episode_values = []
    for episode in trace_summary["episodes"]:
        stop_conditions = Counter(
            role["stopCondition"]
            for role in episode["roleRuns"]
            if isinstance(role.get("stopCondition"), str)
        )
        episode_values.append({
            "id": episode["episodeID"],
            "scenario": episode["scenario"],
            "fingerprint": episode["fingerprint"],
            "repetition": episode["repetition"],
            "score": episode["score"],
            "safetyPassed": episode["safetyPassed"],
            "sourcePreserved": episode["sourcePreserved"],
            "commandCount": episode["commandCount"],
            "invalidCommandCount": episode["invalidCommandCount"],
            "durationMs": episode["durationMs"],
            "marginSha256": episode["marginSha256"],
            "checks": episode["checks"],
            "dimensions": episode["dimensions"],
            "stopConditions": [
                {"name": name, "count": count}
                for name, count in sorted(stop_conditions.items())
            ],
            "usage": episode["usage"],
        })
    trace_reported = round(
        sum(float(episode["usage"]["reportedCostUSD"]) for episode in episode_values),
        6,
    )
    roles = sorted({
        role["seat"]
        for episode in trace_summary["episodes"]
        for role in episode["roleRuns"]
    })
    manifest_status = "completed" if status == "completed" else "infrastructure-error"
    contract_bound = estimate_maximum_cost(
        arguments.scenario,
        arguments.repetitions,
        arguments.max_turns,
        arguments.upstream_attempts_per_turn,
        arguments.input_token_ceiling_per_call,
        arguments.max_tokens_per_call,
        arguments.input_price_per_million,
        arguments.output_price_per_million,
        arguments.billing_overhead_usd_per_call,
        getattr(arguments, "repetition_id", None),
    )
    run_id = hashlib.sha256(canonical({
        "candidate": candidate.digest(),
        "episodes": [episode["id"] for episode in episode_values],
        "model": arguments.model,
        "startedAt": started_at,
    }).encode("utf-8")).hexdigest()[:32]
    live_budget_cap = (
        float(live_budget["policy"]["maxTotalCostUSD"])
        if live_budget is not None
        else contract_bound
    )
    admission_bound = round(min(contract_bound, live_budget_cap), 6)
    return {
        "schema": "urn:marginbench:run:v1",
        "runID": run_id,
        "status": manifest_status,
        "track": arguments.track,
        "benchmark": {
            "name": "MarginBench",
            "version": BENCHMARK_VERSION,
            "taskSet": (
                "private-holdout-v1"
                if getattr(arguments, "holdout_key_file", None)
                else "public-development-v1"
            ),
            "developmentCases": not bool(getattr(arguments, "holdout_key_file", None)),
            "implementationSha256": implementation_sha256(PACKAGE_ROOT),
        },
        "candidate": {
            "id": candidate.id,
            "marginSha256": candidate.margin_sha256,
            "manualSha256": candidate.manual_sha256,
            "settingsSha256": candidate.settings_sha256,
        },
        "execution": {
            "adapter": "prime-verifiers-v1",
            "provider": "Prime Intellect",
            "model": arguments.model,
            "harness": "null-with-one-margin-tool",
            "runtime": "local-subprocess-environment-with-prime-inference",
            "controlProfile": arguments.control_profile,
            "agentProcessCount": agent_process_count(
                arguments.scenario,
                arguments.repetitions,
                getattr(arguments, "repetition_id", None),
            ),
            "roles": roles,
            "startedAt": started_at,
            "durationMs": duration_ms,
            "limits": {
                "maxConcurrentEpisodes": arguments.max_concurrent,
                "maxInputTokens": arguments.max_input_tokens,
                "maxOutputTokens": arguments.max_output_tokens,
                "maxTotalTokens": arguments.max_total_tokens,
                "inputTokenCeilingPerCall": arguments.input_token_ceiling_per_call,
                "upstreamAttemptsPerTurn": arguments.upstream_attempts_per_turn,
                "billingOverheadUSDPerCall": arguments.billing_overhead_usd_per_call,
                "maxTokensPerCall": arguments.max_tokens_per_call,
                "maxTurns": arguments.max_turns,
                "rolloutTimeoutSeconds": arguments.rollout_timeout_seconds,
                "temperature": arguments.temperature,
                **(
                    {
                        "liveProxyMaxRequestBytes": live_budget["policy"]["maxRequestBytes"],
                        "liveProxyTemplateTokenAllowance": live_budget["policy"][
                            "templateTokenAllowance"
                        ],
                    }
                    if live_budget is not None
                    else {}
                ),
            },
            "retryPolicy": "No automatic paid model retries; later attempts are separate capped runs after cooldown.",
            "priorInfrastructureAttempts": arguments.prior_infrastructure_attempts,
        },
        "episodes": episode_values,
        "cost": {
            "currency": "USD",
            "traceReported": trace_reported,
            "observedWalletDebit": observed_wallet_debit,
            "unreconciled": round(abs(observed_wallet_debit - trace_reported), 6),
            "admissionBound": admission_bound,
            **(
                {
                    "contractBound": contract_bound,
                    "liveBudgetCap": live_budget_cap,
                }
                if live_budget is not None
                else {}
            ),
            "hardAdmissionCap": arguments.max_cost_usd,
            "boundBasis": {
                "inputTokenCeilingPerCall": arguments.input_token_ceiling_per_call,
                "outputTokenCeilingPerCall": arguments.max_tokens_per_call,
                "modelCallsPerAgentAtMost": arguments.max_turns,
                "upstreamAttemptsPerTurnAtMost": arguments.upstream_attempts_per_turn,
                "inputPricePerMillion": arguments.input_price_per_million,
                "outputPricePerMillion": arguments.output_price_per_million,
                "billingOverheadUSDPerCall": arguments.billing_overhead_usd_per_call,
            },
            **({"liveBudget": live_budget} if live_budget is not None else {}),
        },
        "privacy": {
            "rawTracesPublished": False,
            "credentialsPresent": False,
            "promptsPublished": False,
            "holdoutKeyPublished": False,
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--margin-bin", type=Path, required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--scenario", action="append", choices=SCENARIO_IDS, required=True)
    parser.add_argument("--repetitions", type=int, default=1)
    parser.add_argument(
        "--repetition-id",
        type=int,
        action="append",
        help="run an exact repetition index; repeat this flag to select more than one",
    )
    parser.add_argument("--temperature", type=float, default=0.0)
    parser.add_argument("--max-tokens-per-call", type=int, default=1200)
    parser.add_argument("--max-turns", type=int, default=12)
    parser.add_argument("--max-input-tokens", type=int, default=40000)
    parser.add_argument("--max-output-tokens", type=int, default=6000)
    parser.add_argument("--max-total-tokens", type=int, default=16000)
    parser.add_argument(
        "--input-token-ceiling-per-call",
        type=int,
        required=True,
        help=(
            "Provider/model contract ceiling for billable prompt tokens in one call; "
            "required because Verifiers' max-input-tokens is a soft graph limit, not a billing cap."
        ),
    )
    parser.add_argument(
        "--upstream-attempts-per-turn",
        type=int,
        default=3,
        help="Admission allowance for the initial provider request plus SDK retries.",
    )
    parser.add_argument(
        "--billing-overhead-usd-per-call",
        type=float,
        default=0.0002,
        help="Additional per-attempt allowance for provider rounding or minimum billing.",
    )
    parser.add_argument("--rollout-timeout-seconds", type=float, default=120.0)
    parser.add_argument("--wall-timeout-seconds", type=float, default=300.0)
    parser.add_argument("--max-concurrent", type=int, default=1)
    parser.add_argument("--minimum-start-interval-seconds", type=float, default=300.0)
    parser.add_argument("--input-price-per-million", type=float, required=True)
    parser.add_argument("--output-price-per-million", type=float, required=True)
    parser.add_argument("--max-cost-usd", type=float, default=2.0)
    parser.add_argument(
        "--live-proxy-cost-cap-usd",
        type=float,
        help="hard cumulative provider-request reservation cap; defaults to --max-cost-usd",
    )
    parser.add_argument(
        "--live-proxy-max-request-bytes",
        type=int,
        default=1024 * 1024,
        help="maximum encoded inference request size accepted by the loopback spend gate",
    )
    parser.add_argument(
        "--live-proxy-template-token-allowance",
        type=int,
        default=8192,
        help="extra conservative input-token allowance per forwarded request",
    )
    parser.add_argument(
        "--live-proxy-timeout-seconds",
        type=float,
        default=120.0,
        help="upstream request timeout enforced by the loopback spend gate",
    )
    parser.add_argument("--candidate", default="baseline")
    parser.add_argument(
        "--candidate-manifest",
        type=Path,
        help="frozen candidate manifest whose ID and Margin digest must match this run",
    )
    parser.add_argument(
        "--holdout-key-file",
        type=Path,
        help="mode-0600 private generation key; passed only to the taskset process",
    )
    parser.add_argument("--control-profile", default=DEFAULT_CONTROL_PROFILE)
    parser.add_argument("--track", choices=("model", "interface", "team", "open-systems"), default="interface")
    parser.add_argument("--prior-infrastructure-attempts", type=int, default=0)
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--summary-file", type=Path)
    parser.add_argument("--run-manifest-file", type=Path)
    parser.add_argument("--execute", action="store_true")
    parser.add_argument("--confirm-paid", default="")
    arguments = parser.parse_args()

    try:
        require_implemented_profile(arguments.control_profile)
    except ValueError as error:
        raise SystemExit(str(error)) from error

    arguments.margin_bin = arguments.margin_bin.expanduser().resolve()
    if not arguments.margin_bin.is_file() or not os.access(arguments.margin_bin, os.X_OK):
        raise SystemExit("Margin executable is unavailable.")
    if arguments.repetitions < 1 or arguments.repetitions > 20:
        raise SystemExit("repetitions must be between 1 and 20")
    repetition_ids = arguments.repetition_id or []
    if (
        len(repetition_ids) > 100
        or len(repetition_ids) != len(set(repetition_ids))
        or any(value < 0 or value >= 100 for value in repetition_ids)
    ):
        raise SystemExit("repetition-id values must be unique and between 0 and 99")
    if repetition_ids and arguments.repetitions != 1:
        raise SystemExit("use either repetitions or repetition-id, not both")
    numeric_limits = [
        arguments.max_tokens_per_call,
        arguments.max_turns,
        arguments.max_input_tokens,
        arguments.max_output_tokens,
        arguments.max_total_tokens,
        arguments.input_token_ceiling_per_call,
        arguments.upstream_attempts_per_turn,
        arguments.max_concurrent,
    ]
    if any(value < 1 for value in numeric_limits):
        raise SystemExit("all run limits must be positive")
    if arguments.max_tokens_per_call > arguments.max_output_tokens:
        raise SystemExit("max-tokens-per-call cannot exceed max-output-tokens")
    if arguments.input_price_per_million < 0 or arguments.output_price_per_million < 0:
        raise SystemExit("token prices cannot be negative")
    if not (0 <= arguments.billing_overhead_usd_per_call <= 1):
        raise SystemExit("billing-overhead-usd-per-call must be between zero and one")
    if arguments.prior_infrastructure_attempts < 0:
        raise SystemExit("prior-infrastructure-attempts must be nonnegative")
    if not (0 < arguments.max_cost_usd <= HARD_MAX_COST_USD):
        raise SystemExit(f"max-cost-usd must be above zero and at most {HARD_MAX_COST_USD}")
    live_proxy_cost_cap = (
        arguments.max_cost_usd
        if arguments.live_proxy_cost_cap_usd is None
        else arguments.live_proxy_cost_cap_usd
    )
    if not (0 < live_proxy_cost_cap <= arguments.max_cost_usd):
        raise SystemExit("live-proxy-cost-cap-usd must be above zero and at most max-cost-usd")
    try:
        live_budget_policy = InferenceBudgetPolicy(
            allowed_model=arguments.model,
            max_request_bytes=arguments.live_proxy_max_request_bytes,
            template_token_allowance=arguments.live_proxy_template_token_allowance,
            input_token_ceiling=arguments.input_token_ceiling_per_call,
            max_output_tokens=arguments.max_tokens_per_call,
            input_price_per_million=arguments.input_price_per_million,
            output_price_per_million=arguments.output_price_per_million,
            billing_overhead_usd_per_call=arguments.billing_overhead_usd_per_call,
            max_total_cost_usd=live_proxy_cost_cap,
        )
    except ValueError as error:
        raise SystemExit(str(error)) from error
    if not 0 < arguments.live_proxy_timeout_seconds <= 300:
        raise SystemExit("live-proxy-timeout-seconds must be between zero and 300")
    if not (0 <= arguments.minimum_start_interval_seconds <= 3_600):
        raise SystemExit("minimum-start-interval-seconds must be between 0 and 3600")
    try:
        arguments.frozen_candidate = (
            load_candidate_manifest(
                arguments.candidate_manifest,
                binary=arguments.margin_bin,
                candidate_id=arguments.candidate,
            )
            if arguments.candidate_manifest
            else _candidate(arguments)
        )
        if arguments.holdout_key_file:
            arguments.holdout_key_value, arguments.holdout_key_id = load_holdout_key(
                arguments.holdout_key_file
            )
        else:
            arguments.holdout_key_value = None
            arguments.holdout_key_id = None
    except ValueError as error:
        raise SystemExit(str(error)) from error

    prime_name = shutil.which("prime")
    if not prime_name:
        raise SystemExit("Prime CLI is not installed.")
    prime = Path(prime_name).resolve()
    v1_eval = prime.parent / "eval"
    if not v1_eval.is_file():
        raise SystemExit("Prime Verifiers v1 eval executable is unavailable.")

    contract_estimate = estimate_maximum_cost(
        arguments.scenario,
        arguments.repetitions,
        arguments.max_turns,
        arguments.upstream_attempts_per_turn,
        arguments.input_token_ceiling_per_call,
        arguments.max_tokens_per_call,
        arguments.input_price_per_million,
        arguments.output_price_per_million,
        arguments.billing_overhead_usd_per_call,
        repetition_ids,
    )
    estimate = round(min(contract_estimate, live_proxy_cost_cap), 6)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    output = (arguments.output_dir or PACKAGE_ROOT / "runs" / f"{stamp}-{arguments.candidate}").resolve()
    command = build_eval_command(
        arguments,
        v1_eval,
        output,
        client_base_url="http://127.0.0.1:<ephemeral>/api/v1",
        client_api_key_var=PROXY_API_KEY_ENV,
    )
    plan = {
        "schema": "urn:marginbench:prime-paid-plan:v1",
        "execute": arguments.execute,
        "model": arguments.model,
        "candidate": arguments.candidate,
        "candidateManifest": {
            "digest": arguments.frozen_candidate.digest(),
            **asdict(arguments.frozen_candidate),
        },
        "track": arguments.track,
        "controlProfile": arguments.control_profile,
        "taskSet": "private-holdout-v1" if arguments.holdout_key_id else "public-development-v1",
        "developmentCases": arguments.holdout_key_id is None,
        "holdoutKeyID": arguments.holdout_key_id,
        "scenarios": arguments.scenario,
        "repetitions": len(_repetition_values(arguments.repetitions, repetition_ids)),
        "repetitionIDs": _repetition_values(arguments.repetitions, repetition_ids),
        "agentProcessCount": agent_process_count(
            arguments.scenario,
            arguments.repetitions,
            repetition_ids,
        ),
        "estimatedMaximumCostUSD": estimate,
        "contractMaximumCostUSD": contract_estimate,
        "costBoundBasis": {
            "modelCallsPerAgentAtMost": arguments.max_turns,
            "upstreamAttemptsPerTurnAtMost": arguments.upstream_attempts_per_turn,
            "inputTokenCeilingPerCall": arguments.input_token_ceiling_per_call,
            "outputTokenCeilingPerCall": arguments.max_tokens_per_call,
            "billingOverheadUSDPerCall": arguments.billing_overhead_usd_per_call,
            "note": (
                "The input ceiling is an externally verified provider/model contract. "
                "The attempt allowance covers SDK retries, and the overhead allowance covers "
                "rounding. Verifiers soft token limits are not provider billing maxima."
            ),
        },
        "hardRunCapUSD": arguments.max_cost_usd,
        "liveBudgetProxy": {
            "enabled": True,
            "loopbackOnly": True,
            "credentialsExposedToChild": False,
            "requestOrResponseContentRetained": False,
            "policy": {
                "allowedModel": live_budget_policy.allowed_model,
                "maxRequestBytes": live_budget_policy.max_request_bytes,
                "templateTokenAllowance": live_budget_policy.template_token_allowance,
                "inputTokenCeiling": live_budget_policy.input_token_ceiling,
                "maxOutputTokens": live_budget_policy.max_output_tokens,
                "inputPricePerMillion": live_budget_policy.input_price_per_million,
                "outputPricePerMillion": live_budget_policy.output_price_per_million,
                "billingOverheadUSDPerCall": live_budget_policy.billing_overhead_usd_per_call,
                "maxTotalCostUSD": live_budget_policy.max_total_cost_usd,
            },
            "maximumSingleRequestReservationUSD": round(
                live_budget_policy.request_cost_upper_bound(
                    live_budget_policy.max_request_bytes,
                    live_budget_policy.max_output_tokens,
                ),
                6,
            ),
        },
        "limits": {
            "maxConcurrent": arguments.max_concurrent,
            "maxTurns": arguments.max_turns,
            "maxInputTokens": arguments.max_input_tokens,
            "maxOutputTokens": arguments.max_output_tokens,
            "maxTotalTokens": arguments.max_total_tokens,
            "inputTokenCeilingPerCall": arguments.input_token_ceiling_per_call,
            "upstreamAttemptsPerTurn": arguments.upstream_attempts_per_turn,
            "billingOverheadUSDPerCall": arguments.billing_overhead_usd_per_call,
            "rolloutTimeoutSeconds": arguments.rollout_timeout_seconds,
            "wallTimeoutSeconds": arguments.wall_timeout_seconds,
            "minimumStartIntervalSeconds": arguments.minimum_start_interval_seconds,
        },
        "marginSha256": sha256(arguments.margin_bin),
        "rawOutputIgnored": "Evals/marginbench/runs/",
        "runManifestRequested": arguments.run_manifest_file is not None,
        "command": command,
    }
    if not arguments.execute:
        print(canonical(plan))
        return 0
    if arguments.confirm_paid != CONFIRMATION:
        raise SystemExit(f"paid execution requires --confirm-paid {CONFIRMATION}")

    try:
        _require_fresh_output_targets(
            output,
            arguments.summary_file,
            arguments.run_manifest_file,
        )
    except ValueError as error:
        raise SystemExit(str(error)) from error

    try:
        upstream_url, upstream_api_key, upstream_team_id = load_prime_inference_credentials()
    except (OSError, ValueError) as error:
        raise SystemExit(str(error)) from error

    try:
        claim_paid_start(
            PACKAGE_ROOT / "runs" / ".last-paid-start",
            now=time.time(),
            minimum_interval_seconds=arguments.minimum_start_interval_seconds,
        )
    except RuntimeError as error:
        raise SystemExit(str(error)) from error

    output.mkdir(parents=True, exist_ok=False)
    before = wallet(prime)
    environment = os.environ.copy()
    environment.update({"PYTHONDONTWRITEBYTECODE": "1", "PYTHONPATH": str(PACKAGE_ROOT)})
    for inherited_secret in ("PRIME_API_KEY", "PRIME_TEAM_ID", "PRIME_INFERENCE_URL"):
        environment.pop(inherited_secret, None)
    if arguments.holdout_key_value is not None:
        environment["MARGINBENCH_HOLDOUT_KEY"] = arguments.holdout_key_value
    started_at = datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")
    started = time.perf_counter()
    timed_out = False
    with InferenceBudgetProxy(
        upstream_url,
        upstream_api_key,
        live_budget_policy,
        team_id=upstream_team_id,
        timeout_seconds=arguments.live_proxy_timeout_seconds,
    ) as proxy:
        environment[PROXY_API_KEY_ENV] = proxy.client_token
        execution_command = build_eval_command(
            arguments,
            v1_eval,
            output,
            client_base_url=proxy.base_url,
            client_api_key_var=PROXY_API_KEY_ENV,
        )
        with (output / "runner.log").open("wb") as log:
            try:
                completed = subprocess.run(
                    execution_command,
                    cwd=PACKAGE_ROOT.parent.parent,
                    env=environment,
                    stdout=log,
                    stderr=subprocess.STDOUT,
                    check=False,
                    timeout=arguments.wall_timeout_seconds,
                )
                exit_code = completed.returncode
            except subprocess.TimeoutExpired:
                timed_out = True
                exit_code = 124
        live_budget_report = proxy.gate.report()
    after = wallet(prime)
    trace_summary = _summarize_traces(output)
    log_text = (output / "runner.log").read_text(encoding="utf-8", errors="replace")
    infrastructure_codes = []
    if "BUDGET_PROXY_COST_LIMIT" in log_text:
        infrastructure_codes.append("LIVE_BUDGET_EXHAUSTED")
    elif "upstream 429" in log_text or "rate_limit" in log_text:
        infrastructure_codes.append("PROVIDER_RATE_LIMIT")
    for proxy_code, infrastructure_code in (
        ("BUDGET_PROXY_REQUEST_LIMIT", "LIVE_REQUEST_SIZE_LIMIT"),
        ("BUDGET_PROXY_OUTPUT_LIMIT", "LIVE_OUTPUT_LIMIT"),
        ("BUDGET_PROXY_UPSTREAM", "LIVE_PROXY_UPSTREAM_ERROR"),
    ):
        if proxy_code in log_text:
            infrastructure_codes.append(infrastructure_code)
    if timed_out:
        infrastructure_codes.append("WALL_TIMEOUT")
    status = (
        "completed"
        if exit_code == 0
        and trace_summary["traceCount"]
        and trace_summary["traceConsistencyPassed"]
        else "infrastructure_error"
    )
    duration_ms = round((time.perf_counter() - started) * 1000)
    observed_wallet_debit = round(before["balanceUSD"] - after["balanceUSD"], 6)
    summary = {
        "schema": "urn:marginbench:prime-run-summary:v1",
        "status": status,
        "paidModelsInvoked": True,
        "model": arguments.model,
        "candidate": arguments.candidate,
        "scenarios": arguments.scenario,
        "repetitions": len(_repetition_values(arguments.repetitions, repetition_ids)),
        "marginSha256": plan["marginSha256"],
        "durationMs": duration_ms,
        "exitCode": exit_code,
        "wallet": {
            "before": before,
            "after": after,
            "observedDebitUSD": observed_wallet_debit,
        },
        "estimatedMaximumCostUSD": estimate,
        "contractMaximumCostUSD": contract_estimate,
        "liveBudgetCapUSD": live_proxy_cost_cap,
        "costBoundBasis": plan["costBoundBasis"],
        "liveBudget": live_budget_report,
        "infrastructureCodes": infrastructure_codes,
        **trace_summary,
        "rawTracesCommitted": False,
    }
    rendered = canonical(summary)
    print(rendered)
    if arguments.summary_file:
        encoded = (rendered + "\n").encode("utf-8")
        receipt = validate_bytes(encoded)
        if not receipt["valid"] or receipt["artifactSchema"] != summary["schema"]:
            raise SystemExit("Generated Prime summary failed validation.")
        _write_new_artifact(arguments.summary_file, encoded)
    if arguments.run_manifest_file and trace_summary["episodeCount"]:
        manifest = _run_manifest(
            arguments,
            trace_summary,
            status=status,
            started_at=started_at,
            duration_ms=duration_ms,
            observed_wallet_debit=observed_wallet_debit,
            live_budget=live_budget_report,
        )
        encoded = (canonical(manifest) + "\n").encode("utf-8")
        receipt = validate_bytes(encoded)
        if not receipt["valid"] or receipt["artifactSchema"] != manifest["schema"]:
            raise SystemExit("Generated run manifest failed validation.")
        _write_new_artifact(arguments.run_manifest_file, encoded)
    return 0 if status == "completed" else 75


if __name__ == "__main__":
    raise SystemExit(main())
