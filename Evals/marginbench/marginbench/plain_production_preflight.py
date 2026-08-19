"""Zero-cost rehearsal of the complete Prime plain-control result path."""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path
from types import SimpleNamespace

from .budget_proxy import InferenceBudgetPolicy, InferenceBudgetProxy
from .controls import planned_topology, require_implemented_profile
from .entropy import PUBLIC_DEVELOPMENT_KEY
from .plain_fake_model import plain_fake_model_server
from .scenarios import SCENARIO_IDS, generate_episode
from .schema import canonical_json, sha256_bytes
from .validation import validate_bytes


PLAIN_PRODUCTION_PREFLIGHT_SCHEMA = (
    "urn:marginbench:neutral-production-preflight:v1"
)
PLAIN_PROFILE = "role-separated-plain-markdown-v1"
PROXY_KEY_ENV = "MARGINBENCH_PLAIN_PRODUCTION_PREFLIGHT_TOKEN"


def _arguments(scenarios: tuple[str, ...], repetitions: int) -> SimpleNamespace:
    return SimpleNamespace(
        scenario=list(scenarios),
        repetitions=repetitions,
        repetition_id=[],
        model="marginbench-plain-fake",
        candidate="plain-markdown-control-production-preflight",
        control_profile=PLAIN_PROFILE,
        margin_bin=Path("/plain-production-preflight-does-not-use-margin"),
        temperature=0.0,
        max_tokens_per_call=1_200,
        provider_response_token_allowance=8,
        max_turns=24,
        max_input_tokens=64_000,
        max_output_tokens=8_000,
        max_total_tokens=72_000,
        input_token_ceiling_per_call=1_000_000,
        upstream_attempts_per_turn=1,
        billing_overhead_usd_per_call=0.0,
        rollout_timeout_seconds=120.0,
        wall_timeout_seconds=300.0,
        live_proxy_timeout_seconds=120.0,
        minimum_start_interval_seconds=0.0,
        max_concurrent=1,
        input_price_per_million=0.0,
        output_price_per_million=0.0,
        max_cost_usd=0.01,
        prior_infrastructure_attempts=0,
        holdout_key_file=None,
    )


def _expected_role_processes(
    scenarios: tuple[str, ...],
    repetitions: int,
) -> int:
    return sum(
        planned_topology(
            PLAIN_PROFILE,
            [role.seat for role in generate_episode(scenario, PUBLIC_DEVELOPMENT_KEY, repetition).roles],
        )["agentProcessCount"]
        for repetition in range(repetitions)
        for scenario in scenarios
    )


def run_plain_production_preflight(
    *,
    scenarios: list[str] | tuple[str, ...] = SCENARIO_IDS,
    repetitions: int = 1,
) -> dict[str, object]:
    """Run Prime's real CLI and official aggregation path without a paid model."""
    selected = tuple(scenarios)
    if (
        not 1 <= repetitions <= 5
        or not selected
        or len(selected) > len(SCENARIO_IDS)
        or len(selected) != len(set(selected))
        or any(scenario not in SCENARIO_IDS for scenario in selected)
    ):
        raise ValueError("Plain production preflight selection is invalid.")
    require_implemented_profile(PLAIN_PROFILE)

    prime = shutil.which("prime")
    if not prime:
        raise ValueError("Prime CLI is required for the production preflight.")
    evaluator = Path(prime).resolve().parent / "eval"
    if not evaluator.is_file():
        raise ValueError("Prime Verifiers v1 eval executable is unavailable.")

    # Import the exact paid-run aggregation/builders only after the profile and
    # Prime runtime checks succeed. This keeps the ordinary local package usable
    # without Prime's optional dependencies.
    from prime_pilot import (  # noqa: PLC0415
        _execution_status,
        _neutral_execution_summary,
        _neutral_run_manifest,
        _summarize_neutral_traces,
        build_eval_command,
    )

    arguments = _arguments(selected, repetitions)
    expected_role_processes = _expected_role_processes(selected, repetitions)
    package_root = Path(__file__).resolve().parent.parent
    started_at = datetime.now(timezone.utc).isoformat(timespec="seconds").replace(
        "+00:00", "Z"
    )
    started = time.perf_counter()

    policy = InferenceBudgetPolicy(
        allowed_model=arguments.model,
        max_request_bytes=1_048_576,
        template_token_allowance=8_192,
        input_token_ceiling=arguments.input_token_ceiling_per_call,
        max_output_tokens=arguments.max_tokens_per_call,
        input_price_per_million=0.0,
        output_price_per_million=0.0,
        billing_overhead_usd_per_call=0.0,
        max_total_cost_usd=arguments.max_cost_usd,
        response_token_allowance=arguments.provider_response_token_allowance,
    )
    with (
        plain_fake_model_server() as (server, handler),
        InferenceBudgetProxy(
            f"http://127.0.0.1:{server.server_port}/v1",
            "local-production-preflight-upstream-only",
            policy,
        ) as proxy,
        tempfile.TemporaryDirectory(prefix="marginbench-plain-production-") as temporary,
    ):
        output = Path(temporary)
        environment = os.environ.copy()
        for name in (
            "MARGINBENCH_HOLDOUT_KEY",
            "PRIME_API_KEY",
            "PRIME_TEAM_ID",
            "PRIME_INFERENCE_URL",
        ):
            environment.pop(name, None)
        environment.update({
            "PYTHONDONTWRITEBYTECODE": "1",
            "PYTHONPATH": str(package_root),
            PROXY_KEY_ENV: proxy.client_token,
        })
        command = build_eval_command(
            arguments,
            evaluator,
            output,
            client_base_url=proxy.base_url,
            client_api_key_var=PROXY_KEY_ENV,
        )
        try:
            completed = subprocess.run(
                command,
                cwd=package_root.parent.parent,
                env=environment,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.STDOUT,
                check=False,
                timeout=180,
            )
            prime_exit_code = completed.returncode
        except subprocess.TimeoutExpired:
            prime_exit_code = 124

        live_budget = proxy.gate.report()
        trace_summary = _summarize_neutral_traces(output)
        infrastructure_codes: list[str] = []
        if prime_exit_code == 124:
            infrastructure_codes.append("WALL_TIMEOUT")
        if live_budget["rejectedRequestCount"]:
            infrastructure_codes.append("LOCAL_BUDGET_PROXY_REJECTED_REQUEST")
        if live_budget["providerBoundViolationCount"]:
            infrastructure_codes.append("PROVIDER_USAGE_BOUND_VIOLATION")
        status = _execution_status(
            prime_exit_code,
            trace_summary,
            infrastructure_codes,
        )
        duration_ms = round((time.perf_counter() - started) * 1_000, 3)

        wallet_state = {"balanceUSD": 0.0, "totalBillings": 0}
        summary = _neutral_execution_summary(
            arguments,
            trace_summary,
            status=status,
            duration_ms=round(duration_ms),
            exit_code=prime_exit_code,
            wallet_before=wallet_state,
            wallet_after=wallet_state,
            observed_wallet_debit=0.0,
            estimated_maximum_cost=0.0,
            contract_maximum_cost=0.0,
            live_budget_cap=arguments.max_cost_usd,
            live_budget=live_budget,
            infrastructure_codes=infrastructure_codes,
            paid_models_invoked=False,
        )
        summary_bytes = canonical_json(summary)
        summary_receipt = validate_bytes(summary_bytes)

        run_bytes: bytes | None = None
        run_valid = False
        run_errors: list[str] = []
        if trace_summary["episodeCount"]:
            manifest = _neutral_run_manifest(
                arguments,
                trace_summary,
                status=status,
                started_at=started_at,
                duration_ms=round(duration_ms),
                observed_wallet_debit=0.0,
                live_budget=live_budget,
                provider="local-scripted-endpoint",
                runtime="prime-eval-cli-with-local-scripted-endpoint",
            )
            run_bytes = canonical_json(manifest)
            run_receipt = validate_bytes(run_bytes)
            run_valid = bool(
                run_receipt["valid"]
                and run_receipt["artifactSchema"] == "urn:marginbench:neutral-run:v1"
            )
            run_errors = list(run_receipt["errors"][:16])

        episodes = [
            {
                "episodeID": episode["episodeID"],
                "scenario": episode["scenario"],
                "repetition": episode["repetition"],
                "roleProcessCount": len(episode["roleRuns"]),
                "implementedChecksPassed": episode["implementedChecksPassed"],
                "safetyPassed": episode["safetyPassed"],
                "sourcePreserved": episode["sourcePreserved"],
                "toolCallCount": episode["efficiencyObservations"]["toolCallCount"],
                "modelCallCount": episode["usage"]["modelCalls"],
            }
            for episode in trace_summary["episodes"]
        ]
        expected_echoes = handler.request_count - len(handler.prompt_digests)
        summary_valid = bool(
            summary_receipt["valid"]
            and summary_receipt["artifactSchema"]
            == "urn:marginbench:neutral-prime-run-summary:v1"
        )
        passed = bool(
            status == "completed"
            and prime_exit_code == 0
            and trace_summary["traceConsistencyPassed"]
            and trace_summary["traceCount"] == expected_role_processes
            and trace_summary["episodeCount"] == len(selected) * repetitions
            and all(
                episode["implementedChecksPassed"]
                and episode["safetyPassed"]
                and episode["sourcePreserved"]
                for episode in episodes
            )
            and len(handler.prompt_digests) == expected_role_processes
            and handler.request_count >= expected_role_processes
            and handler.own_canary_echo_count == expected_echoes
            and handler.own_canary_missing_count == 0
            and handler.cross_role_canary_leak_count == 0
            and handler.malformed_request_count == 0
            and live_budget["forwardedRequestCount"] == handler.request_count
            and live_budget["rejectedRequestCount"] == 0
            and live_budget["providerBoundViolationCount"] == 0
            and summary_valid
            and run_valid
        )
        receipt = {
            "schema": PLAIN_PRODUCTION_PREFLIGHT_SCHEMA,
            "passed": passed,
            "paidModelsInvoked": False,
            "controlProfile": PLAIN_PROFILE,
            "controlRunnable": True,
            "marginBinaryUsed": False,
            "primeEvalInvoked": True,
            "modelEndpoint": "loopback-scripted-openai-compatible",
            "executionBoundary": "prime-eval-cli-with-fresh-subprocess-rollouts",
            "toolSurface": ["workspace"],
            "rawPromptsRetained": False,
            "rawTranscriptsRetained": False,
            "scenarioCount": len(selected),
            "repetitionCount": repetitions,
            "episodeCount": trace_summary["episodeCount"],
            "expectedRoleProcessCount": expected_role_processes,
            "traceCount": trace_summary["traceCount"],
            "traceConsistencyPassed": trace_summary["traceConsistencyPassed"],
            "primeExitCode": prime_exit_code,
            "fakeModelRequestCount": handler.request_count,
            "distinctRolePromptCount": len(handler.prompt_digests),
            "ownCanaryEchoCount": handler.own_canary_echo_count,
            "ownCanaryMissingCount": handler.own_canary_missing_count,
            "crossRoleCanaryLeakCount": handler.cross_role_canary_leak_count,
            "malformedRequestCount": handler.malformed_request_count,
            "officialSummaryValidated": summary_valid,
            "officialSummaryValidationErrors": list(summary_receipt["errors"][:16]),
            "officialSummarySha256": sha256_bytes(summary_bytes),
            "officialRunValidated": run_valid,
            "officialRunValidationErrors": run_errors,
            "officialRunSha256": sha256_bytes(run_bytes) if run_bytes is not None else None,
            "liveBudget": live_budget,
            "durationMs": duration_ms,
            "episodes": episodes,
        }
    canonical_json(receipt)
    return receipt
