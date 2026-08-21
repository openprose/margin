#!/usr/bin/env python3
"""Resumable, budget-gated Prime controller for topology crossover studies.

Dry-run is the default. A paid execution follows each case's frozen profile
order, runs one cell at a time, never retries automatically, and stops on the
first unsafe, incomplete, or unvalidated result.
"""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import math
import os
import shutil
import stat
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, Callable

sys.dont_write_bytecode = True
PACKAGE_ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(PACKAGE_ROOT))

from marginbench.candidates import CandidateManifest  # noqa: E402
from marginbench.controls import per_agent_compute_multiplier, planned_topology  # noqa: E402
from marginbench.crossover import (  # noqa: E402
    ROLE_SEPARATED_PROFILE,
    analyze_crossover,
    load_crossover_evidence,
    load_crossover_evidence_set,
    load_crossover_plan,
)
from marginbench.entropy import PUBLIC_DEVELOPMENT_KEY  # noqa: E402
from marginbench.keys import read_holdout_key  # noqa: E402
from marginbench.prime_study import PrimeStudyError, file_sha256  # noqa: E402
from marginbench.provenance import implementation_sha256  # noqa: E402
from marginbench.schema import canonical_json  # noqa: E402
from marginbench.scenarios import generate_episode  # noqa: E402
from marginbench.validation import MAX_ARTIFACT_BYTES, submission_identifier, validate_bytes  # noqa: E402
from paired_pilot import _atomic_write, _frozen_binary, _frozen_bytes  # noqa: E402
from prime_pilot import (  # noqa: E402
    BENCHMARK_VERSION,
    CONFIRMATION as CHILD_CONFIRMATION,
    DEFAULT_PROVIDER_RESPONSE_TOKEN_ALLOWANCE,
    claim_paid_start,
    estimate_maximum_cost,
    wallet,
)


CONFIRMATION = "RUN_PAID_MARGINBENCH_CROSSOVER_STUDY"
PLAN_SCHEMA = "urn:marginbench:crossover-prime-plan:v1"
COMPLETION_SCHEMA = "urn:marginbench:crossover-prime-completion:v1"
MAX_STUDY_CAP_USD = 50.0
MAX_CELL_CAP_USD = 15.0


def _snapshot(path: Path, schema: str) -> tuple[dict[str, Any], bytes, str]:
    if path.is_symlink():
        raise PrimeStudyError("Crossover controller inputs must not be symbolic links.")
    try:
        with path.expanduser().open("rb") as handle:
            raw = handle.read(MAX_ARTIFACT_BYTES + 1)
    except OSError as error:
        raise PrimeStudyError("A crossover controller input could not be read.") from error
    receipt = validate_bytes(raw)
    if not receipt["valid"] or receipt["artifactSchema"] != schema:
        details = "; ".join(receipt.get("errors", ())[:3])
        raise PrimeStudyError(details or "A crossover controller input is invalid.")
    return json.loads(raw), raw, receipt["sha256"]


def _positive_integer(values: dict[str, Any], name: str) -> int:
    value = values.get(name)
    if not isinstance(value, int) or isinstance(value, bool) or value < 1:
        raise PrimeStudyError(f"{name} must be a positive integer.")
    return value


def _nonnegative_number(values: dict[str, Any], name: str) -> float:
    value = values.get(name)
    if (
        not isinstance(value, (int, float))
        or isinstance(value, bool)
        or not math.isfinite(value)
        or value < 0
    ):
        raise PrimeStudyError(f"{name} must be a nonnegative number.")
    return float(value)


def _generation_key(
    key_file: Path | None,
    *,
    development_cases: bool,
) -> tuple[bytes, str]:
    if development_cases:
        if key_file is not None:
            raise PrimeStudyError("Public-development crossover plans must not use a private key.")
        value = PUBLIC_DEVELOPMENT_KEY
        return value, "sha256:" + hashlib.sha256(value).hexdigest()
    if key_file is None:
        raise PrimeStudyError("Private crossover plans require a mode-0600 holdout key.")
    try:
        return read_holdout_key(key_file)
    except ValueError as error:
        raise PrimeStudyError(str(error)) from error


def build_crossover_prime_plan(
    *,
    crossover_plan: Path,
    candidate_manifest: Path,
    candidate_binary: Path,
    model: str,
    limits: dict[str, Any],
    pricing: dict[str, Any],
    live_proxy_cap_per_cell_usd: float,
    hard_study_cap_usd: float,
    minimum_wallet_reserve_usd: float,
    package_root: Path,
    key_file: Path | None = None,
    track: str = "team",
) -> dict[str, Any]:
    """Freeze case order, topology, executable, conditions, and budget without spending."""
    crossover, _, crossover_sha = _snapshot(
        crossover_plan,
        "urn:marginbench:crossover-plan:v1",
    )
    # Re-run semantic checks that JSON Schema alone cannot express.
    if load_crossover_plan(crossover_plan) != crossover:
        raise PrimeStudyError("Crossover plan changed while it was being loaded.")
    payload, _, manifest_sha = _snapshot(
        candidate_manifest,
        "urn:marginbench:candidate:v1",
    )
    try:
        candidate = CandidateManifest(**payload)
    except (TypeError, ValueError) as error:
        raise PrimeStudyError("Candidate manifest is invalid.") from error
    binary = candidate_binary.expanduser().resolve()
    if candidate.id != crossover["candidateID"]:
        raise PrimeStudyError("Candidate manifest does not match the crossover plan.")
    if not binary.is_file() or not os.access(binary, os.X_OK):
        raise PrimeStudyError("Candidate Margin executable is unavailable.")
    if file_sha256(binary) != candidate.margin_sha256:
        raise PrimeStudyError("Candidate manifest does not match its Margin executable.")
    if not model or len(model.encode("utf-8")) > 256:
        raise PrimeStudyError("Model ID must contain between 1 and 256 UTF-8 bytes.")
    if track != "team":
        raise PrimeStudyError("Topology crossover execution must use the team track.")
    if (
        not math.isfinite(live_proxy_cap_per_cell_usd)
        or not 0 < live_proxy_cap_per_cell_usd <= MAX_CELL_CAP_USD
    ):
        raise PrimeStudyError(
            f"Live cell cap must be above zero and at most ${MAX_CELL_CAP_USD:.2f}."
        )
    if (
        not math.isfinite(hard_study_cap_usd)
        or not 0 < hard_study_cap_usd <= MAX_STUDY_CAP_USD
    ):
        raise PrimeStudyError(
            f"Hard study cap must be above zero and at most ${MAX_STUDY_CAP_USD:.2f}."
        )
    if not math.isfinite(minimum_wallet_reserve_usd) or minimum_wallet_reserve_usd < 0:
        raise PrimeStudyError("Minimum wallet reserve cannot be negative.")
    for name in (
        "maxTurns",
        "maxInputTokens",
        "maxOutputTokens",
        "maxTotalTokens",
        "inputTokenCeilingPerCall",
        "upstreamAttemptsPerTurn",
        "maxTokensPerCall",
        "maxConcurrent",
        "liveProxyMaxRequestBytes",
    ):
        _positive_integer(limits, name)
    if limits["maxConcurrent"] != 1:
        raise PrimeStudyError("Crossover cells must run serially with maxConcurrent equal to one.")
    if limits["maxTokensPerCall"] > limits["maxOutputTokens"]:
        raise PrimeStudyError("maxTokensPerCall cannot exceed maxOutputTokens.")
    allowance = limits.get("providerResponseTokenAllowance")
    if (
        not isinstance(allowance, int)
        or isinstance(allowance, bool)
        or not 0 <= allowance <= 4096
    ):
        raise PrimeStudyError("providerResponseTokenAllowance must be between 0 and 4096.")
    template_allowance = limits.get("liveProxyTemplateTokenAllowance")
    if (
        not isinstance(template_allowance, int)
        or isinstance(template_allowance, bool)
        or not 0 <= template_allowance <= 1_000_000
    ):
        raise PrimeStudyError("liveProxyTemplateTokenAllowance must be between 0 and 1000000.")
    if limits["liveProxyMaxRequestBytes"] > 16 * 1024 * 1024:
        raise PrimeStudyError("liveProxyMaxRequestBytes cannot exceed 16777216.")
    for name in (
        "rolloutTimeoutSeconds",
        "wallTimeoutSeconds",
        "liveProxyTimeoutSeconds",
    ):
        if _nonnegative_number(limits, name) <= 0:
            raise PrimeStudyError(f"{name} must be above zero.")
    if _nonnegative_number(limits, "minimumStartIntervalSeconds") > 3600:
        raise PrimeStudyError(
            "minimumStartIntervalSeconds must be between zero and 3600."
        )
    if _nonnegative_number(limits, "minimumRequestIntervalSeconds") > 60:
        raise PrimeStudyError(
            "minimumRequestIntervalSeconds must be between zero and 60."
        )
    if _nonnegative_number(limits, "temperature") > 2:
        raise PrimeStudyError("temperature must be between zero and two.")
    ceiling_source = limits.get("inputTokenCeilingSource")
    if not isinstance(ceiling_source, str) or not ceiling_source.startswith("https://"):
        raise PrimeStudyError("inputTokenCeilingSource must be an HTTPS evidence URL.")
    for name in (
        "inputPricePerMillion",
        "outputPricePerMillion",
        "billingOverheadUSDPerCall",
    ):
        _nonnegative_number(pricing, name)
    if pricing["billingOverheadUSDPerCall"] > 1:
        raise PrimeStudyError("billingOverheadUSDPerCall must be between zero and one.")
    pricing_source = pricing.get("source")
    if not isinstance(pricing_source, str) or not pricing_source.startswith("https://"):
        raise PrimeStudyError("Pricing source must be an HTTPS evidence URL.")

    key, key_id = _generation_key(
        key_file,
        development_cases=bool(crossover["developmentCases"]),
    )
    jobs: list[dict[str, Any]] = []
    ordinal = 1
    for planned in crossover["episodes"]:
        episode = generate_episode(planned["scenario"], key, planned["repetition"])
        if episode.public_id != planned["id"] or episode.fingerprint != planned["fingerprint"]:
            raise PrimeStudyError("Generation key does not reproduce the frozen crossover case.")
        logical_roles = [role.seat for role in episode.roles]
        if logical_roles != planned["roles"]:
            raise PrimeStudyError("Crossover plan roles differ from the generated case.")
        for profile in planned["profileOrder"]:
            topology = planned_topology(profile, logical_roles)
            contract = estimate_maximum_cost(
                [planned["scenario"]],
                1,
                limits["maxTurns"],
                limits["upstreamAttemptsPerTurn"],
                limits["inputTokenCeilingPerCall"],
                limits["maxTokensPerCall"] + allowance,
                pricing["inputPricePerMillion"],
                pricing["outputPricePerMillion"],
                pricing["billingOverheadUSDPerCall"],
                [planned["repetition"]],
                profile,
            )
            live_cap = round(min(contract, live_proxy_cap_per_cell_usd), 6)
            identity = {
                "schema": "urn:marginbench:crossover-prime-job:v1",
                "ordinal": ordinal,
                "episodeID": planned["id"],
                "candidateID": candidate.id,
                "controlProfile": profile,
            }
            jobs.append({
                **identity,
                "id": submission_identifier(identity),
                "scenario": planned["scenario"],
                "repetition": planned["repetition"],
                "fingerprint": planned["fingerprint"],
                "roles": logical_roles,
                "agentProcessCount": topology["agentProcessCount"],
                "traceSeats": topology["traceSeats"],
                "phasePolicy": topology["phasePolicy"],
                "contractMaximumCostUSD": contract,
                "liveProxyCapUSD": live_cap,
            })
            ordinal += 1
    estimated_maximum = round(sum(job["liveProxyCapUSD"] for job in jobs), 6)
    contract_maximum = round(sum(job["contractMaximumCostUSD"] for job in jobs), 6)
    if estimated_maximum > hard_study_cap_usd + 0.000001:
        raise PrimeStudyError(
            f"Crossover live caps total ${estimated_maximum:.6f}, above the "
            f"${hard_study_cap_usd:.6f} hard study cap."
        )
    plan = {
        "schema": PLAN_SCHEMA,
        "candidate": {
            "id": candidate.id,
            "manifestSha256": manifest_sha,
            "manifestDigest": candidate.digest(),
            "marginSha256": candidate.margin_sha256,
            "manualSha256": candidate.manual_sha256,
            "settingsSha256": candidate.settings_sha256,
        },
        "benchmarkImplementationSha256": implementation_sha256(package_root),
        "crossoverPlanSha256": crossover_sha,
        "taskSet": crossover["taskSet"],
        "developmentCases": crossover["developmentCases"],
        "generationKeyID": key_id,
        "model": model,
        "track": track,
        "limits": dict(limits),
        "pricing": dict(pricing),
        "budget": {
            "currency": "USD",
            "contractMaximumCostUSD": contract_maximum,
            "estimatedMaximumCostUSD": estimated_maximum,
            "liveProxyCapPerCellUSD": round(live_proxy_cap_per_cell_usd, 6),
            "hardStudyCapUSD": round(hard_study_cap_usd, 6),
            "minimumWalletReserveUSD": round(minimum_wallet_reserve_usd, 6),
        },
        "failurePolicy": {
            "automaticPaidRetry": False,
            "continueAfterUnsafeOrIncompleteCell": False,
            "completedCellReplay": "verify-and-skip",
            "orphanedAttempt": "stop-for-operator-review",
        },
        "jobCount": len(jobs),
        "agentProcessCount": sum(job["agentProcessCount"] for job in jobs),
        "jobs": jobs,
    }
    plan["id"] = submission_identifier(plan)
    validation = validate_bytes(canonical_json(plan))
    if not validation["valid"]:
        details = "; ".join(validation.get("errors", ())[:3])
        raise RuntimeError(details or "Generated crossover Prime plan is invalid.")
    return plan


def _job_stem(job: dict[str, Any]) -> str:
    profile = "role" if job["controlProfile"] == ROLE_SEPARATED_PROFILE else "continuing"
    scenario = job["scenario"].replace("_", "-")
    return f"{job['ordinal']:04d}-{scenario}-{profile}-{job['id'].split(':', 1)[1][:10]}"


def _job_paths(work: Path, job: dict[str, Any]) -> dict[str, Path]:
    stem = _job_stem(job)
    return {
        "raw": work / "raw" / stem,
        "summary": work / "cells" / f"{stem}.summary.json",
        "run": work / "cells" / f"{stem}.run.json",
        "receipt": work / "cells" / f"{stem}.receipt.json",
        "attempt": work / "cells" / f"{stem}.attempt.json",
    }


def _read_canonical(path: Path) -> tuple[dict[str, Any], bytes]:
    if path.is_symlink():
        raise PrimeStudyError("Controller state must not be a symbolic link.")
    try:
        raw = path.read_bytes()
        value = json.loads(raw)
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise PrimeStudyError("Controller state is unreadable or malformed.") from error
    if not isinstance(value, dict) or canonical_json(value) != raw:
        raise PrimeStudyError("Controller state must be canonical JSON.")
    return value, raw


def _expected_execution_limits(plan: dict[str, Any]) -> dict[str, Any]:
    limits = plan["limits"]
    return {
        "maxConcurrentEpisodes": limits["maxConcurrent"],
        "maxInputTokens": limits["maxInputTokens"],
        "maxOutputTokens": limits["maxOutputTokens"],
        "maxTotalTokens": limits["maxTotalTokens"],
        "inputTokenCeilingPerCall": limits["inputTokenCeilingPerCall"],
        "upstreamAttemptsPerTurn": limits["upstreamAttemptsPerTurn"],
        "billingOverheadUSDPerCall": plan["pricing"]["billingOverheadUSDPerCall"],
        "maxTokensPerCall": limits["maxTokensPerCall"],
        "providerResponseTokenAllowance": limits["providerResponseTokenAllowance"],
        "maxTurns": limits["maxTurns"],
        "rolloutTimeoutSeconds": limits["rolloutTimeoutSeconds"],
        "wallTimeoutSeconds": limits["wallTimeoutSeconds"],
        "liveProxyTimeoutSeconds": limits["liveProxyTimeoutSeconds"],
        "minimumStartIntervalSeconds": limits["minimumStartIntervalSeconds"],
        "minimumRequestIntervalSeconds": limits["minimumRequestIntervalSeconds"],
        "temperature": limits["temperature"],
        "liveProxyMaxRequestBytes": limits["liveProxyMaxRequestBytes"],
        "liveProxyTemplateTokenAllowance": limits["liveProxyTemplateTokenAllowance"],
    }


def _expected_bound_basis(plan: dict[str, Any], job: dict[str, Any]) -> dict[str, Any]:
    limits = plan["limits"]
    pricing = plan["pricing"]
    return {
        "inputTokenCeilingPerCall": limits["inputTokenCeilingPerCall"],
        "outputTokenCeilingPerCall": (
            limits["maxTokensPerCall"] + limits["providerResponseTokenAllowance"]
        ),
        "modelCallsPerAgentAtMost": (
            limits["maxTurns"]
            * per_agent_compute_multiplier(job["controlProfile"], job["roles"])
        ),
        "upstreamAttemptsPerTurnAtMost": limits["upstreamAttemptsPerTurn"],
        "inputPricePerMillion": pricing["inputPricePerMillion"],
        "outputPricePerMillion": pricing["outputPricePerMillion"],
        "billingOverheadUSDPerCall": pricing["billingOverheadUSDPerCall"],
    }


def _expected_live_budget_policy(
    plan: dict[str, Any],
    job: dict[str, Any],
) -> dict[str, Any]:
    limits = plan["limits"]
    pricing = plan["pricing"]
    return {
        "allowedModel": plan["model"],
        "maxRequestBytes": limits["liveProxyMaxRequestBytes"],
        "templateTokenAllowance": limits["liveProxyTemplateTokenAllowance"],
        "inputTokenCeiling": limits["inputTokenCeilingPerCall"],
        "maxOutputTokens": limits["maxTokensPerCall"],
        "responseTokenAllowance": limits["providerResponseTokenAllowance"],
        "inputPricePerMillion": pricing["inputPricePerMillion"],
        "outputPricePerMillion": pricing["outputPricePerMillion"],
        "billingOverheadUSDPerCall": pricing["billingOverheadUSDPerCall"],
        "maxTotalCostUSD": job["liveProxyCapUSD"],
    }


def _validate_job_outputs(
    plan: dict[str, Any],
    job: dict[str, Any],
    paths: dict[str, Path],
) -> dict[str, Any]:
    summary, summary_raw, summary_sha = _snapshot(
        paths["summary"],
        "urn:marginbench:prime-run-summary:v1",
    )
    run, run_raw, run_sha = _snapshot(paths["run"], "urn:marginbench:run:v1")
    try:
        evidence = load_crossover_evidence(paths["run"])
    except ValueError as error:
        raise PrimeStudyError(
            "Completed crossover cell is infrastructure-invalid or malformed."
        ) from error
    if len(evidence.measurements) != 1:
        raise PrimeStudyError("A crossover cell must contain exactly one measured episode.")
    measurement = evidence.measurements[0]
    if (
        measurement.episode_id != job["episodeID"]
        or measurement.scenario != job["scenario"]
        or measurement.repetition != job["repetition"]
        or measurement.fingerprint != job["fingerprint"]
        or measurement.control_profile != job["controlProfile"]
        or measurement.candidate_id != plan["candidate"]["id"]
        or measurement.margin_sha256 != plan["candidate"]["marginSha256"]
    ):
        raise PrimeStudyError("Completed crossover evidence does not match its planned cell.")
    execution = run.get("execution") or {}
    benchmark = run.get("benchmark") or {}
    expected_benchmark = {
        "name": "MarginBench",
        "version": BENCHMARK_VERSION,
        "taskSet": plan["taskSet"],
        "developmentCases": plan["developmentCases"],
        "implementationSha256": plan["benchmarkImplementationSha256"],
    }
    expected_candidate = {
        "id": plan["candidate"]["id"],
        "marginSha256": plan["candidate"]["marginSha256"],
        "manualSha256": plan["candidate"]["manualSha256"],
        "settingsSha256": plan["candidate"]["settingsSha256"],
    }
    expected_execution = {
        "adapter": "prime-verifiers-v1",
        "provider": "Prime Intellect",
        "model": plan["model"],
        "harness": "null-with-one-margin-tool",
        "runtime": "local-subprocess-environment-with-prime-inference",
        "controlProfile": job["controlProfile"],
        "agentProcessCount": job["agentProcessCount"],
        "roles": job["roles"],
        "traceSeats": job["traceSeats"],
        "phasePolicy": job["phasePolicy"],
        "limits": _expected_execution_limits(plan),
        "retryPolicy": (
            "No automatic paid model retries; later attempts are separate capped "
            "runs after cooldown."
        ),
        "priorInfrastructureAttempts": 0,
    }
    if (
        run.get("status") != "completed"
        or run.get("track") != plan["track"]
        or benchmark != expected_benchmark
        or run.get("candidate") != expected_candidate
        or any(execution.get(key) != value for key, value in expected_execution.items())
    ):
        raise PrimeStudyError("Completed crossover evidence changed its frozen experiment contract.")
    cost = run.get("cost") or {}
    live = summary.get("liveBudget") or {}
    run_live = cost.get("liveBudget") or {}
    wallet_value = summary.get("wallet") or {}
    observed = wallet_value.get("observedDebitUSD")
    wallet_is_unattributed = (
        wallet_value.get("observationScope") == "account-wide"
        and wallet_value.get("debitAttribution") == "unattributed"
    )
    proxy_accounted_upper = live.get("reservedCostUpperBoundUSD")
    expected_policy = _expected_live_budget_policy(plan, job)
    expected_basis = _expected_bound_basis(plan, job)
    summary_episodes = summary.get("episodes") or []
    summary_episode = summary_episodes[0] if len(summary_episodes) == 1 else {}
    logical_actors = summary_episode.get("logicalActors") or []
    role_runs = summary_episode.get("roleRuns") or []
    if (
        summary.get("status") != "completed"
        or summary.get("exitCode") != 0
        or summary.get("paidModelsInvoked") is not True
        or summary.get("traceConsistencyPassed") is not True
        or summary.get("candidate") != plan["candidate"]["id"]
        or summary.get("model") != plan["model"]
        or summary.get("marginSha256") != plan["candidate"]["marginSha256"]
        or summary.get("scenarios") != [job["scenario"]]
        or summary.get("repetitions") != 1
        or summary.get("episodeCount") != 1
        or summary.get("traceCount") != job["agentProcessCount"]
        or summary.get("estimatedMaximumCostUSD") != job["liveProxyCapUSD"]
        or summary.get("contractMaximumCostUSD") != job["contractMaximumCostUSD"]
        or summary.get("liveBudgetCapUSD") != job["liveProxyCapUSD"]
        or summary_episode.get("episodeID") != job["episodeID"]
        or summary_episode.get("scenario") != job["scenario"]
        or summary_episode.get("repetition") != job["repetition"]
        or summary_episode.get("fingerprint") != job["fingerprint"]
        or summary_episode.get("controlProfile") != job["controlProfile"]
        or summary_episode.get("agentProcessCount") != job["agentProcessCount"]
        or summary_episode.get("traceSeats") != job["traceSeats"]
        or summary_episode.get("phasePolicy") != job["phasePolicy"]
        or [actor.get("seat") for actor in logical_actors] != job["roles"]
        or sorted(role.get("seat") for role in role_runs) != sorted(job["traceSeats"])
        or live != run_live
        or live.get("enabled") is not True
        or live.get("policy") != expected_policy
        or live.get("latchedClosed") is not False
        or live.get("outstandingReservationCount") != 0
        or live.get("providerBoundViolationCount") != 0
        or not isinstance(observed, (int, float))
        or isinstance(observed, bool)
        or not math.isfinite(observed)
        or observed < 0
        or (
            not wallet_is_unattributed
            and observed > job["liveProxyCapUSD"] + 0.000001
        )
        or not isinstance(proxy_accounted_upper, (int, float))
        or isinstance(proxy_accounted_upper, bool)
        or proxy_accounted_upper > job["liveProxyCapUSD"] + 0.000001
        or cost.get("currency") != "USD"
        or cost.get("hardAdmissionCap") != job["liveProxyCapUSD"]
        or cost.get("admissionBound") != job["liveProxyCapUSD"]
        or cost.get("contractBound") != job["contractMaximumCostUSD"]
        or cost.get("liveBudgetCap") != job["liveProxyCapUSD"]
        or cost.get("boundBasis") != expected_basis
        or cost.get("observedWalletDebit") != observed
        or (
            wallet_is_unattributed
            and (
                cost.get("observedWalletDebitScope") != "account-wide"
                or cost.get("observedWalletDebitAttribution") != "unattributed"
            )
        )
    ):
        raise PrimeStudyError("Completed crossover summary violates its cell contract or budget.")
    if not measurement.safety_passed or not measurement.source_preserved:
        raise PrimeStudyError("Crossover execution stopped after an unsafe or source-damaging cell.")
    return {
        "schema": "urn:marginbench:crossover-prime-job-receipt:v1",
        "planID": plan["id"],
        "jobID": job["id"],
        "ordinal": job["ordinal"],
        "episodeID": job["episodeID"],
        "controlProfile": job["controlProfile"],
        "summary": {"sha256": summary_sha, "byteCount": len(summary_raw)},
        "run": {"sha256": run_sha, "byteCount": len(run_raw)},
        "observedWalletDebitUSD": round(float(observed), 6),
        **(
            {
                "proxyAccountedCostUpperBoundUSD": round(
                    float(proxy_accounted_upper),
                    6,
                ),
                "walletObservationScope": "account-wide",
                "walletDebitAttribution": "unattributed",
            }
            if wallet_is_unattributed
            else {}
        ),
        "reportedCostUSD": round(float(measurement.reported_cost_usd), 6),
        "modelCalls": measurement.model_calls,
        "safetyPassed": True,
        "sourcePreserved": True,
    }


def _load_or_adopt_receipt(
    plan: dict[str, Any],
    job: dict[str, Any],
    paths: dict[str, Path],
) -> dict[str, Any] | None:
    if paths["receipt"].exists():
        saved, raw = _read_canonical(paths["receipt"])
        expected = _validate_job_outputs(plan, job, paths)
        if saved != expected or raw != canonical_json(expected):
            raise PrimeStudyError("Saved crossover receipt no longer matches its evidence.")
        return saved
    present = {name: path.exists() for name, path in paths.items()}
    if not any(present.values()):
        return None
    if present["summary"] and present["run"]:
        receipt = _validate_job_outputs(plan, job, paths)
        _atomic_write(paths["receipt"], canonical_json(receipt))
        return receipt
    raise PrimeStudyError(
        "An unreceipted crossover attempt is incomplete. It will not be retried "
        "automatically; inspect the private raw directory first."
    )


def _freeze_inputs(
    arguments: argparse.Namespace,
    plan: dict[str, Any],
    work: Path,
) -> dict[str, Path | None]:
    root = work / "frozen-inputs"
    root.mkdir(mode=0o700, exist_ok=True)
    identity = root.stat()
    if identity.st_uid != os.getuid() or identity.st_mode & 0o077:
        raise PrimeStudyError("Frozen-input directory must be private and owned by this user.")
    frozen: dict[str, Path | None] = {
        "crossoverPlan": _frozen_bytes(
            arguments.crossover_plan,
            root / "crossover-plan.json",
            plan["crossoverPlanSha256"],
        ),
        "candidateManifest": _frozen_bytes(
            arguments.candidate_manifest,
            root / "candidate.json",
            plan["candidate"]["manifestSha256"],
        ),
        "candidateBinary": _frozen_binary(
            arguments.candidate_bin,
            root / "margin-candidate",
            plan["candidate"]["marginSha256"],
        ),
        "holdoutKey": None,
    }
    if not plan["developmentCases"]:
        if arguments.holdout_key_file is None:
            raise PrimeStudyError("Private crossover execution requires its planned key.")
        value, key_id = read_holdout_key(arguments.holdout_key_file)
        if key_id != plan["generationKeyID"]:
            raise PrimeStudyError("Holdout key changed before crossover execution.")
        destination = root / "holdout.key"
        if destination.exists():
            frozen_value, frozen_id = read_holdout_key(destination)
            if frozen_value != value or frozen_id != key_id:
                raise PrimeStudyError("Frozen holdout key no longer matches the plan.")
        else:
            _atomic_write(destination, value + b"\n")
        frozen["holdoutKey"] = destination
    return frozen


def _child_command(
    plan: dict[str, Any],
    job: dict[str, Any],
    paths: dict[str, Path],
    frozen: dict[str, Path | None],
) -> list[str]:
    limits = plan["limits"]
    pricing = plan["pricing"]
    command = [
        sys.executable,
        str(PACKAGE_ROOT / "prime_pilot.py"),
        "--margin-bin", str(frozen["candidateBinary"]),
        "--model", plan["model"],
        "--scenario", job["scenario"],
        "--repetition-id", str(job["repetition"]),
        "--candidate", plan["candidate"]["id"],
        "--candidate-manifest", str(frozen["candidateManifest"]),
        "--control-profile", job["controlProfile"],
        "--track", plan["track"],
        "--temperature", str(limits["temperature"]),
        "--max-tokens-per-call", str(limits["maxTokensPerCall"]),
        "--provider-response-token-allowance", str(limits["providerResponseTokenAllowance"]),
        "--max-turns", str(limits["maxTurns"]),
        "--max-input-tokens", str(limits["maxInputTokens"]),
        "--max-output-tokens", str(limits["maxOutputTokens"]),
        "--max-total-tokens", str(limits["maxTotalTokens"]),
        "--input-token-ceiling-per-call", str(limits["inputTokenCeilingPerCall"]),
        "--upstream-attempts-per-turn", str(limits["upstreamAttemptsPerTurn"]),
        "--billing-overhead-usd-per-call", str(pricing["billingOverheadUSDPerCall"]),
        "--rollout-timeout-seconds", str(limits["rolloutTimeoutSeconds"]),
        "--wall-timeout-seconds", str(limits["wallTimeoutSeconds"]),
        "--live-proxy-timeout-seconds", str(limits["liveProxyTimeoutSeconds"]),
        "--max-concurrent", "1",
        "--minimum-start-interval-seconds", str(
            limits["minimumStartIntervalSeconds"]
        ),
        "--minimum-request-interval-seconds", str(
            limits["minimumRequestIntervalSeconds"]
        ),
        "--input-price-per-million", str(pricing["inputPricePerMillion"]),
        "--output-price-per-million", str(pricing["outputPricePerMillion"]),
        "--max-cost-usd", str(max(job["liveProxyCapUSD"], 0.000001)),
        "--live-proxy-cost-cap-usd", str(job["liveProxyCapUSD"]),
        "--live-proxy-max-request-bytes", str(limits["liveProxyMaxRequestBytes"]),
        "--live-proxy-template-token-allowance", str(limits["liveProxyTemplateTokenAllowance"]),
        "--output-dir", str(paths["raw"]),
        "--summary-file", str(paths["summary"]),
        "--run-manifest-file", str(paths["run"]),
        "--execute",
        "--confirm-paid", CHILD_CONFIRMATION,
    ]
    if frozen["holdoutKey"] is not None:
        command += ["--holdout-key-file", str(frozen["holdoutKey"])]
    return command


def wait_until_paid_start_allowed(
    path: Path,
    minimum_interval_seconds: float,
    *,
    clock: Callable[[], float] = time.time,
    sleeper: Callable[[float], None] = time.sleep,
) -> None:
    """Wait without claiming; the child atomically claims immediately before inference."""
    if minimum_interval_seconds <= 0:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    while True:
        descriptor = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX)
            os.lseek(descriptor, 0, os.SEEK_SET)
            raw = os.read(descriptor, 128).decode("ascii", errors="ignore").strip()
        finally:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
            os.close(descriptor)
        try:
            previous = float(raw)
        except ValueError:
            previous = 0.0
        remaining = minimum_interval_seconds - (clock() - previous)
        if previous <= 0 or remaining <= 0:
            return
        sleeper(remaining)


def _cost_totals(receipts: list[dict[str, Any]]) -> tuple[float, float, bool]:
    observed = round(sum(item["observedWalletDebitUSD"] for item in receipts), 6)
    fully_attributed = all(
        "proxyAccountedCostUpperBoundUSD" in item for item in receipts
    )
    accounted = round(
        sum(
            item.get(
                "proxyAccountedCostUpperBoundUSD",
                item["observedWalletDebitUSD"],
            )
            for item in receipts
        ),
        6,
    )
    return observed, accounted, fully_attributed


def _finalize(
    plan: dict[str, Any],
    crossover_plan_path: Path,
    work: Path,
    receipts: list[dict[str, Any]],
) -> dict[str, Any]:
    role_paths = []
    continuing_paths = []
    for job in plan["jobs"]:
        path = _job_paths(work, job)["run"]
        destination = role_paths if job["controlProfile"] == ROLE_SEPARATED_PROFILE else continuing_paths
        destination.append(path)
    role = load_crossover_evidence_set(role_paths)
    continuing = load_crossover_evidence_set(continuing_paths)
    if canonical_json(role.experiment_contract) != canonical_json(continuing.experiment_contract):
        raise PrimeStudyError("Completed crossover cells do not share one experiment contract.")
    report = analyze_crossover(
        role.measurements,
        continuing.measurements,
        analysis_mode="measured-model",
        plan=load_crossover_plan(crossover_plan_path),
        experiment_contract=role.experiment_contract,
    )
    report_raw = canonical_json(report)
    validation = validate_bytes(report_raw)
    if not validation["valid"]:
        details = "; ".join(validation.get("errors", ())[:3])
        raise PrimeStudyError(
            "Completed crossover report failed bounded validation"
            + (f": {details}" if details else ".")
        )
    report_path = work / "crossover-report.json"
    if report_path.exists():
        saved, raw = _read_canonical(report_path)
        if saved != report or raw != report_raw:
            raise PrimeStudyError("Existing crossover report differs from completed evidence.")
    else:
        _atomic_write(report_path, report_raw, 0o644)
    observed, accounted, fully_attributed = _cost_totals(receipts)
    completion = {
        "schema": COMPLETION_SCHEMA,
        "completed": True,
        "paidModelsInvoked": True,
        "planID": plan["id"],
        "jobCount": len(receipts),
        "observedWalletDebitUSD": observed,
        **(
            {
                "proxyAccountedCostUpperBoundUSD": accounted,
                "walletObservationScope": "account-wide",
                "walletDebitAttribution": "unattributed",
            }
            if fully_attributed
            else {}
        ),
        "reportedCostUSD": round(sum(item["reportedCostUSD"] for item in receipts), 6),
        "modelCalls": sum(item["modelCalls"] for item in receipts),
        "allSafe": report["allPairsSafe"],
        "sampleSizeSufficient": report["sampleSizeSufficient"],
        "directionalConclusion": report["overall"]["directionalConclusion"],
        "descriptiveLeader": report["overall"]["descriptiveLeader"],
        "report": {
            "path": "crossover-report.json",
            "sha256": validation["sha256"],
            "byteCount": validation["byteCount"],
        },
        "automaticRetryPerformed": False,
    }
    completion_validation = validate_bytes(canonical_json(completion))
    if not completion_validation["valid"]:
        details = "; ".join(completion_validation.get("errors", ())[:3])
        raise PrimeStudyError(details or "Completed crossover receipt failed validation.")
    return completion


def execute_study(
    arguments: argparse.Namespace,
    plan: dict[str, Any],
    *,
    wallet_reader: Callable[[Path], dict[str, Any]] = wallet,
    child_runner: Callable[..., subprocess.CompletedProcess] = subprocess.run,
    start_claimer: Callable[..., None] = claim_paid_start,
    start_pacer: Callable[[Path, float], None] = wait_until_paid_start_allowed,
    prime_resolver: Callable[[str], str | None] = shutil.which,
) -> dict[str, Any]:
    work = arguments.work_dir
    if work.exists() and (not work.is_dir() or work.is_symlink()):
        raise PrimeStudyError("Crossover work path must be a real directory.")
    if not work.exists():
        work.mkdir(mode=0o700, parents=False)
    identity = work.stat()
    if identity.st_uid != os.getuid() or identity.st_mode & 0o077:
        raise PrimeStudyError("Crossover work directory must be private and owned by this user.")
    (work / "cells").mkdir(mode=0o700, exist_ok=True)
    lock_flags = os.O_RDWR | os.O_CREAT
    if hasattr(os, "O_NOFOLLOW"):
        lock_flags |= os.O_NOFOLLOW
    descriptor = os.open(work / ".controller.lock", lock_flags, 0o600)
    lock_identity = os.fstat(descriptor)
    if not stat.S_ISREG(lock_identity.st_mode) or lock_identity.st_uid != os.getuid():
        os.close(descriptor)
        raise PrimeStudyError("Crossover controller lock has an unsafe identity.")
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError as error:
        os.close(descriptor)
        raise PrimeStudyError("Another controller already owns this crossover study.") from error
    try:
        plan_path = work / "crossover-prime-plan.json"
        rendered = canonical_json(plan)
        if plan_path.exists():
            saved, raw = _read_canonical(plan_path)
            if saved != plan or raw != rendered:
                raise PrimeStudyError("Work directory belongs to a different crossover plan.")
        else:
            _atomic_write(plan_path, rendered)
        frozen = _freeze_inputs(arguments, plan, work)
        receipts: list[dict[str, Any]] = []
        for index, job in enumerate(plan["jobs"]):
            receipt = _load_or_adopt_receipt(plan, job, _job_paths(work, job))
            if receipt is None:
                for later in plan["jobs"][index + 1:]:
                    if any(path.exists() for path in _job_paths(work, later).values()):
                        raise PrimeStudyError("Saved crossover evidence is not a contiguous plan prefix.")
                break
            receipts.append(receipt)
        if len(receipts) == len(plan["jobs"]):
            return _finalize(plan, frozen["crossoverPlan"], work, receipts)

        prime_name = prime_resolver("prime")
        if not prime_name:
            raise PrimeStudyError("Prime CLI is not installed.")
        prime = Path(prime_name).resolve()
        remaining = round(sum(job["liveProxyCapUSD"] for job in plan["jobs"][len(receipts):]), 6)
        reserve = float(plan["budget"]["minimumWalletReserveUSD"])
        current = wallet_reader(prime)
        if float(current["balanceUSD"]) + 0.000001 < remaining + reserve:
            raise PrimeStudyError("Wallet cannot cover the remaining crossover cap and reserve.")
        start_claimer(
            PACKAGE_ROOT / "runs" / ".last-paid-crossover-study-start",
            now=time.time(),
            minimum_interval_seconds=arguments.minimum_start_interval_seconds,
        )

        new_jobs = 0
        for job in plan["jobs"][len(receipts):]:
            remaining = round(
                sum(item["liveProxyCapUSD"] for item in plan["jobs"] if item["ordinal"] >= job["ordinal"]),
                6,
            )
            current = wallet_reader(prime)
            if float(current["balanceUSD"]) + 0.000001 < remaining + reserve:
                raise PrimeStudyError("Wallet fell below the remaining crossover cap and reserve.")
            start_pacer(
                PACKAGE_ROOT / "runs" / ".last-paid-start",
                float(plan["limits"]["minimumStartIntervalSeconds"]),
            )
            paths = _job_paths(work, job)
            attempt = {
                "schema": "urn:marginbench:crossover-prime-attempt:v1",
                "planID": plan["id"],
                "jobID": job["id"],
                "ordinal": job["ordinal"],
                "automaticRetryAllowed": False,
            }
            _atomic_write(paths["attempt"], canonical_json(attempt))
            command = _child_command(plan, job, paths, frozen)
            try:
                completed = child_runner(
                    command,
                    cwd=PACKAGE_ROOT.parent.parent,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    check=False,
                    timeout=float(plan["limits"]["wallTimeoutSeconds"]) + 60,
                )
            except subprocess.TimeoutExpired as error:
                raise PrimeStudyError(
                    f"Paid crossover cell {job['ordinal']} timed out; its attempt marker prevents a retry."
                ) from error
            try:
                receipt = _load_or_adopt_receipt(plan, job, paths)
            except PrimeStudyError as error:
                raise PrimeStudyError(
                    f"Paid crossover cell {job['ordinal']} produced no adoptable evidence "
                    f"(exit {completed.returncode}); no retry was attempted: {error}"
                ) from error
            if receipt is None or completed.returncode != 0:
                raise PrimeStudyError(
                    f"Paid crossover cell {job['ordinal']} did not complete cleanly; no retry was attempted."
                )
            receipts.append(receipt)
            new_jobs += 1
            observed, accounted, fully_attributed = _cost_totals(receipts)
            if accounted > plan["budget"]["hardStudyCapUSD"] + 0.000001:
                raise PrimeStudyError(
                    "Benchmark-attributable cost exceeded the hard crossover cap."
                )
            progress = {
                "schema": "urn:marginbench:crossover-prime-progress:v1",
                "planID": plan["id"],
                "completedJobs": len(receipts),
                "jobCount": plan["jobCount"],
                "lastJobID": job["id"],
                "observedWalletDebitUSD": observed,
                **(
                    {
                        "proxyAccountedCostUpperBoundUSD": accounted,
                        "walletObservationScope": "account-wide",
                        "walletDebitAttribution": "unattributed",
                    }
                    if fully_attributed
                    else {}
                ),
            }
            print(canonical_json(progress).decode("utf-8"), file=sys.stderr, flush=True)
            if new_jobs >= arguments.max_new_jobs and len(receipts) < plan["jobCount"]:
                return {
                    **progress,
                    "status": "paused",
                    "paidModelsInvoked": True,
                    "nextOrdinal": plan["jobs"][len(receipts)]["ordinal"],
                    "automaticRetryPerformed": False,
                }
        return _finalize(plan, frozen["crossoverPlan"], work, receipts)
    finally:
        fcntl.flock(descriptor, fcntl.LOCK_UN)
        os.close(descriptor)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    parser.add_argument("--crossover-plan", type=Path, required=True)
    parser.add_argument("--candidate-manifest", type=Path, required=True)
    parser.add_argument("--candidate-bin", type=Path, required=True)
    parser.add_argument("--holdout-key-file", type=Path)
    parser.add_argument("--model", required=True)
    parser.add_argument("--track", default="team", choices=("team",))
    parser.add_argument("--max-turns", type=int, default=8)
    parser.add_argument("--max-input-tokens", type=int, default=40_000)
    parser.add_argument("--max-output-tokens", type=int, default=6_000)
    parser.add_argument("--max-total-tokens", type=int, default=16_000)
    parser.add_argument("--input-token-ceiling-per-call", type=int, required=True)
    parser.add_argument("--input-token-ceiling-source", required=True)
    parser.add_argument("--upstream-attempts-per-turn", type=int, default=3)
    parser.add_argument("--max-tokens-per-call", type=int, default=1_800)
    parser.add_argument(
        "--provider-response-token-allowance",
        type=int,
        default=DEFAULT_PROVIDER_RESPONSE_TOKEN_ALLOWANCE,
    )
    parser.add_argument("--rollout-timeout-seconds", type=float, default=180.0)
    parser.add_argument("--wall-timeout-seconds", type=float, default=300.0)
    parser.add_argument("--live-proxy-timeout-seconds", type=float, default=120.0)
    parser.add_argument("--temperature", type=float, default=0.0)
    parser.add_argument("--input-price-per-million", type=float, required=True)
    parser.add_argument("--output-price-per-million", type=float, required=True)
    parser.add_argument("--pricing-source", required=True)
    parser.add_argument("--billing-overhead-usd-per-call", type=float, default=0.0002)
    parser.add_argument("--live-proxy-cap-per-cell-usd", type=float, required=True)
    parser.add_argument("--max-study-cost-usd", type=float, required=True)
    parser.add_argument("--live-proxy-max-request-bytes", type=int, default=1024 * 1024)
    parser.add_argument("--live-proxy-template-token-allowance", type=int, default=8192)
    parser.add_argument("--minimum-wallet-reserve-usd", type=float, default=80.0)
    parser.add_argument("--minimum-start-interval-seconds", type=float, default=300.0)
    parser.add_argument("--minimum-request-interval-seconds", type=float, default=0.0)
    parser.add_argument("--max-new-jobs", type=int, default=1000)
    parser.add_argument("--work-dir", type=Path)
    parser.add_argument("--plan-file", type=Path)
    parser.add_argument("--execute", action="store_true")
    parser.add_argument("--confirm-paid", default="")
    return parser


def main(argv: list[str] | None = None) -> int:
    arguments = _parser().parse_args(argv)
    if not 1 <= arguments.max_new_jobs <= 1000:
        raise SystemExit("max-new-jobs must be between 1 and 1000")
    if not 0 <= arguments.minimum_start_interval_seconds <= 3600:
        raise SystemExit("minimum-start-interval-seconds must be between 0 and 3600")
    if not 0 < arguments.live_proxy_timeout_seconds <= 300:
        raise SystemExit("live-proxy-timeout-seconds must be between zero and 300")
    if not 0 <= arguments.minimum_request_interval_seconds <= 60:
        raise SystemExit("minimum-request-interval-seconds must be between 0 and 60")
    for name in ("crossover_plan", "candidate_manifest", "candidate_bin"):
        setattr(arguments, name, getattr(arguments, name).expanduser().resolve())
    if arguments.holdout_key_file is not None:
        arguments.holdout_key_file = arguments.holdout_key_file.expanduser().resolve()
    limits = {
        "maxTurns": arguments.max_turns,
        "maxInputTokens": arguments.max_input_tokens,
        "maxOutputTokens": arguments.max_output_tokens,
        "maxTotalTokens": arguments.max_total_tokens,
        "inputTokenCeilingPerCall": arguments.input_token_ceiling_per_call,
        "inputTokenCeilingSource": arguments.input_token_ceiling_source,
        "upstreamAttemptsPerTurn": arguments.upstream_attempts_per_turn,
        "maxTokensPerCall": arguments.max_tokens_per_call,
        "providerResponseTokenAllowance": arguments.provider_response_token_allowance,
        "maxConcurrent": 1,
        "rolloutTimeoutSeconds": arguments.rollout_timeout_seconds,
        "wallTimeoutSeconds": arguments.wall_timeout_seconds,
        "liveProxyTimeoutSeconds": arguments.live_proxy_timeout_seconds,
        "minimumStartIntervalSeconds": arguments.minimum_start_interval_seconds,
        "minimumRequestIntervalSeconds": arguments.minimum_request_interval_seconds,
        "temperature": arguments.temperature,
        "liveProxyMaxRequestBytes": arguments.live_proxy_max_request_bytes,
        "liveProxyTemplateTokenAllowance": arguments.live_proxy_template_token_allowance,
    }
    pricing = {
        "inputPricePerMillion": arguments.input_price_per_million,
        "outputPricePerMillion": arguments.output_price_per_million,
        "billingOverheadUSDPerCall": arguments.billing_overhead_usd_per_call,
        "source": arguments.pricing_source,
    }
    try:
        plan = build_crossover_prime_plan(
            crossover_plan=arguments.crossover_plan,
            candidate_manifest=arguments.candidate_manifest,
            candidate_binary=arguments.candidate_bin,
            model=arguments.model,
            limits=limits,
            pricing=pricing,
            live_proxy_cap_per_cell_usd=arguments.live_proxy_cap_per_cell_usd,
            hard_study_cap_usd=arguments.max_study_cost_usd,
            minimum_wallet_reserve_usd=arguments.minimum_wallet_reserve_usd,
            package_root=PACKAGE_ROOT,
            key_file=arguments.holdout_key_file,
            track=arguments.track,
        )
    except (PrimeStudyError, ValueError) as error:
        raise SystemExit(str(error)) from error
    rendered = canonical_json(plan)
    if arguments.plan_file:
        destination = arguments.plan_file.expanduser().resolve()
        if destination.exists() or not destination.parent.is_dir():
            raise SystemExit("Plan file must be a new path inside an existing directory.")
        _atomic_write(destination, rendered, 0o644)
    if not arguments.execute:
        print(rendered.decode("utf-8"))
        return 0
    if arguments.confirm_paid != CONFIRMATION:
        raise SystemExit(f"paid execution requires --confirm-paid {CONFIRMATION}")
    suffix = plan["id"].split(":", 1)[1][:16]
    arguments.work_dir = (
        arguments.work_dir or PACKAGE_ROOT / "runs" / f"crossover-{suffix}"
    ).expanduser().resolve()
    try:
        receipt = execute_study(arguments, plan)
    except (PrimeStudyError, RuntimeError, OSError) as error:
        raise SystemExit(str(error)) from error
    print(canonical_json(receipt).decode("utf-8"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
