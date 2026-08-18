"""Budget-bound plans and redacted evidence checks for paired Prime studies."""

from __future__ import annotations

import hashlib
import json
import math
import os
from pathlib import Path
from typing import Any

from .candidates import CandidateManifest
from .controls import require_implemented_profile
from .entropy import PUBLIC_DEVELOPMENT_KEY
from .keys import read_holdout_key
from .provenance import implementation_sha256
from .scenarios import generate_episode
from .schema import canonical_json
from .scheduling import build_execution_plan_from_study
from .validation import MAX_ARTIFACT_BYTES, submission_identifier, validate_bytes


PRIME_STUDY_PLAN_SCHEMA = "urn:marginbench:prime-study-plan:v1"
PRIME_STUDY_JOB_RECEIPT_SCHEMA = "urn:marginbench:prime-study-job-receipt:v1"
MAX_PRIME_STUDY_CAP_USD = 50.0
MAX_PRIME_JOB_CAP_USD = 15.0


class PrimeStudyError(ValueError):
    pass


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as handle:
            for block in iter(lambda: handle.read(1_048_576), b""):
                digest.update(block)
    except OSError as error:
        raise PrimeStudyError("A required executable or artifact could not be read.") from error
    return digest.hexdigest()


def _snapshot(path: Path, schema: str) -> tuple[dict[str, Any], bytes, str]:
    target = path.expanduser().resolve()
    try:
        with target.open("rb") as handle:
            raw = handle.read(MAX_ARTIFACT_BYTES + 1)
    except OSError as error:
        raise PrimeStudyError("A required study artifact could not be read.") from error
    receipt = validate_bytes(raw)
    if not receipt["valid"] or receipt["artifactSchema"] != schema:
        details = "; ".join(receipt.get("errors", ())[:3])
        raise PrimeStudyError(details or "A required study artifact is invalid.")
    return json.loads(raw), raw, receipt["sha256"]


def _candidate(path: Path, binary: Path, expected_id: str) -> tuple[CandidateManifest, str]:
    payload, _, manifest_sha256 = _snapshot(path, "urn:marginbench:candidate:v1")
    try:
        manifest = CandidateManifest(**payload)
    except (TypeError, ValueError) as error:
        raise PrimeStudyError("Candidate manifest is invalid.") from error
    executable = binary.expanduser().resolve()
    if manifest.id != expected_id:
        raise PrimeStudyError("Candidate manifest ID does not match the study plan.")
    if not executable.is_file() or not os.access(executable, os.X_OK):
        raise PrimeStudyError("Candidate Margin executable is unavailable.")
    if file_sha256(executable) != manifest.margin_sha256:
        raise PrimeStudyError("Candidate manifest does not match its Margin executable.")
    return manifest, manifest_sha256


def _generation_key(path: Path | None, development_cases: bool) -> tuple[bytes, str]:
    if path is None:
        if not development_cases:
            raise PrimeStudyError("Private studies require a mode-0600 holdout key.")
        value = PUBLIC_DEVELOPMENT_KEY
        return value, "sha256:" + hashlib.sha256(value).hexdigest()
    if development_cases:
        raise PrimeStudyError("Public-development studies must not use a private key.")
    try:
        return read_holdout_key(path)
    except ValueError as error:
        raise PrimeStudyError(str(error)) from error


def _positive_integer(limits: dict[str, Any], name: str) -> int:
    value = limits.get(name)
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


def _job_cost(role_count: int, limits: dict[str, Any], pricing: dict[str, Any]) -> float:
    attempts = (
        role_count
        * _positive_integer(limits, "maxTurns")
        * _positive_integer(limits, "upstreamAttemptsPerTurn")
    )
    per_attempt = (
        _positive_integer(limits, "inputTokenCeilingPerCall")
        * _nonnegative_number(pricing, "inputPricePerMillion")
        / 1_000_000
        + _positive_integer(limits, "maxTokensPerCall")
        * _nonnegative_number(pricing, "outputPricePerMillion")
        / 1_000_000
        + _nonnegative_number(pricing, "billingOverheadUSDPerCall")
    )
    return round(attempts * per_attempt, 6)


def build_prime_study_plan(
    *,
    study_plan: Path,
    execution_plan: Path,
    baseline_manifest: Path,
    baseline_binary: Path,
    candidate_manifest: Path,
    candidate_binary: Path,
    model: str,
    limits: dict[str, Any],
    pricing: dict[str, Any],
    hard_admission_cap_usd: float,
    minimum_wallet_reserve_usd: float,
    package_root: Path,
    live_proxy_cap_per_job_usd: float | None = None,
    key_file: Path | None = None,
    track: str = "interface",
) -> dict[str, Any]:
    """Freeze the complete paid schedule and its worst-case budget without spending."""
    limits = {
        "liveProxyMaxRequestBytes": 1024 * 1024,
        "liveProxyTemplateTokenAllowance": 8192,
        **limits,
    }
    if not model or len(model.encode("utf-8")) > 256:
        raise PrimeStudyError("Model ID must contain between 1 and 256 UTF-8 bytes.")
    if track != "interface":
        raise PrimeStudyError("The paired Prime controller currently supports only interface studies.")
    if (
        not math.isfinite(hard_admission_cap_usd)
        or not 0 < hard_admission_cap_usd <= MAX_PRIME_STUDY_CAP_USD
    ):
        raise PrimeStudyError(
            f"Hard study cap must be above zero and at most ${MAX_PRIME_STUDY_CAP_USD:.2f}."
        )
    if not math.isfinite(minimum_wallet_reserve_usd) or minimum_wallet_reserve_usd < 0:
        raise PrimeStudyError("Minimum wallet reserve cannot be negative.")
    if live_proxy_cap_per_job_usd is not None and (
        not math.isfinite(live_proxy_cap_per_job_usd)
        or not 0 < live_proxy_cap_per_job_usd <= MAX_PRIME_JOB_CAP_USD
    ):
        raise PrimeStudyError(
            f"Live proxy cap per job must be above zero and at most ${MAX_PRIME_JOB_CAP_USD:.2f}."
        )

    study, _, study_sha256 = _snapshot(study_plan, "urn:marginbench:study-plan:v1")
    execution, _, execution_sha256 = _snapshot(
        execution_plan,
        "urn:marginbench:execution-plan:v1",
    )
    expected_execution = build_execution_plan_from_study(study, study_sha256)
    if execution != expected_execution:
        raise PrimeStudyError("Execution plan is not the exact expansion of the study plan.")
    require_implemented_profile(study["controlProfile"])
    baseline, baseline_manifest_sha256 = _candidate(
        baseline_manifest,
        baseline_binary,
        study["baselineCandidate"],
    )
    candidate, candidate_manifest_sha256 = _candidate(
        candidate_manifest,
        candidate_binary,
        study["candidate"],
    )
    generation_key, generation_key_id = _generation_key(key_file, study["developmentCases"])
    expected_episodes = {item["id"]: item for item in study["episodes"]}
    for item in study["episodes"]:
        generated = generate_episode(item["scenario"], generation_key, item["repetition"])
        if generated.public_id != item["id"] or generated.fingerprint != item["fingerprint"]:
            raise PrimeStudyError("Generation key does not reproduce the frozen study plan.")

    # Validate every live execution control before calculating money. These are
    # also copied verbatim into the immutable plan and later into every child run.
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
    live_template_allowance = limits.get("liveProxyTemplateTokenAllowance")
    if (
        not isinstance(live_template_allowance, int)
        or isinstance(live_template_allowance, bool)
        or not 0 <= live_template_allowance <= 1_000_000
    ):
        raise PrimeStudyError("liveProxyTemplateTokenAllowance must be between 0 and 1000000.")
    if limits["liveProxyMaxRequestBytes"] > 16 * 1024 * 1024:
        raise PrimeStudyError("liveProxyMaxRequestBytes cannot exceed 16777216.")
    ceiling_source = limits.get("inputTokenCeilingSource")
    if (
        not isinstance(ceiling_source, str)
        or not ceiling_source.startswith("https://")
        or len(ceiling_source.encode("utf-8")) > 2_048
    ):
        raise PrimeStudyError("inputTokenCeilingSource must be a bounded HTTPS evidence URL.")
    if limits["maxTokensPerCall"] > limits["maxOutputTokens"]:
        raise PrimeStudyError("maxTokensPerCall cannot exceed maxOutputTokens.")
    for name in ("rolloutTimeoutSeconds", "wallTimeoutSeconds"):
        if _nonnegative_number(limits, name) <= 0:
            raise PrimeStudyError(f"{name} must be above zero.")
    temperature = _nonnegative_number(limits, "temperature")
    if temperature > 2:
        raise PrimeStudyError("temperature must be between zero and two.")
    for name in (
        "inputPricePerMillion",
        "outputPricePerMillion",
        "billingOverheadUSDPerCall",
    ):
        _nonnegative_number(pricing, name)
    pricing_source = pricing.get("source")
    if (
        not isinstance(pricing_source, str)
        or not pricing_source.startswith("https://")
        or len(pricing_source.encode("utf-8")) > 2_048
    ):
        raise PrimeStudyError("pricing source must be a bounded HTTPS evidence URL.")
    if pricing["billingOverheadUSDPerCall"] > 1:
        raise PrimeStudyError("billingOverheadUSDPerCall must be between zero and one.")

    candidates = {
        baseline.id: {
            "id": baseline.id,
            "manifestSha256": baseline_manifest_sha256,
            "manifestDigest": baseline.digest(),
            "marginSha256": baseline.margin_sha256,
            "manualSha256": baseline.manual_sha256,
            "settingsSha256": baseline.settings_sha256,
        },
        candidate.id: {
            "id": candidate.id,
            "manifestSha256": candidate_manifest_sha256,
            "manifestDigest": candidate.digest(),
            "marginSha256": candidate.margin_sha256,
            "manualSha256": candidate.manual_sha256,
            "settingsSha256": candidate.settings_sha256,
        },
    }
    jobs = []
    for job in execution["jobs"]:
        planned = expected_episodes[job["episodeID"]]
        if job["roles"] != planned["roles"]:
            raise PrimeStudyError("Execution job roles differ from the frozen study plan.")
        contract_job_cost = _job_cost(len(job["roles"]), limits, pricing)
        live_job_cap = round(min(
            contract_job_cost,
            live_proxy_cap_per_job_usd
            if live_proxy_cap_per_job_usd is not None
            else contract_job_cost,
        ), 6)
        estimated_job_cost = live_job_cap
        if estimated_job_cost > MAX_PRIME_JOB_CAP_USD:
            raise PrimeStudyError(
                f"Job {job['ordinal']} exceeds the ${MAX_PRIME_JOB_CAP_USD:.2f} child-run cap."
            )
        jobs.append({
            "ordinal": job["ordinal"],
            "id": job["id"],
            "episodeID": job["episodeID"],
            "scenario": job["scenario"],
            "repetition": job["repetition"],
            "fingerprint": job["fingerprint"],
            "candidateID": job["candidateID"],
            "candidatePosition": job["candidatePosition"],
            "roles": job["roles"],
            "estimatedMaximumCostUSD": estimated_job_cost,
            "contractMaximumCostUSD": contract_job_cost,
            "liveProxyCapUSD": live_job_cap,
        })
    estimated_maximum = round(sum(item["estimatedMaximumCostUSD"] for item in jobs), 6)
    contract_maximum = round(sum(item["contractMaximumCostUSD"] for item in jobs), 6)
    if estimated_maximum > hard_admission_cap_usd:
        raise PrimeStudyError(
            f"Estimated maximum ${estimated_maximum:.6f} exceeds the "
            f"${hard_admission_cap_usd:.6f} hard study cap."
        )
    plan = {
        "schema": PRIME_STUDY_PLAN_SCHEMA,
        "benchmarkVersion": study["benchmarkVersion"],
        "benchmarkImplementationSha256": implementation_sha256(package_root),
        "taskSet": study["taskSet"],
        "developmentCases": study["developmentCases"],
        "controlProfile": study["controlProfile"],
        "track": track,
        "model": model,
        "generationKeyID": generation_key_id,
        "studyPlanSha256": study_sha256,
        "executionPlanSha256": execution_sha256,
        "baseline": candidates[baseline.id],
        "candidate": candidates[candidate.id],
        "limits": dict(limits),
        "pricing": dict(pricing),
        "budget": {
            "currency": "USD",
            "estimatedMaximumCostUSD": estimated_maximum,
            "contractMaximumCostUSD": contract_maximum,
            "requestedLiveProxyCapPerJobUSD": (
                round(live_proxy_cap_per_job_usd, 6)
                if live_proxy_cap_per_job_usd is not None
                else None
            ),
            "hardAdmissionCapUSD": round(float(hard_admission_cap_usd), 6),
            "minimumWalletReserveUSD": round(float(minimum_wallet_reserve_usd), 6),
        },
        "failurePolicy": {
            "continueAfterIncompleteJob": False,
            "automaticPaidRetry": False,
            "completedJobReplay": "verify-and-skip",
            "orphanedAttempt": "stop-for-operator-review",
        },
        "jobCount": len(jobs),
        "roleProcessCount": sum(len(item["roles"]) for item in jobs),
        "jobs": jobs,
    }
    plan["id"] = submission_identifier(plan)
    receipt = validate_bytes(canonical_json(plan))
    if not receipt["valid"]:
        details = "; ".join(receipt.get("errors", ())[:3])
        raise RuntimeError(details or "Generated Prime study plan violated its public contract.")
    return plan


def validate_prime_job_outputs(
    plan: dict[str, Any],
    job: dict[str, Any],
    *,
    summary_path: Path,
    run_path: Path,
    summary_relative_path: str,
    run_relative_path: str,
) -> dict[str, Any]:
    """Validate a paid child result before it becomes resumable evidence."""
    summary, _, summary_sha256 = _snapshot(
        summary_path,
        "urn:marginbench:prime-run-summary:v1",
    )
    run, _, run_sha256 = _snapshot(run_path, "urn:marginbench:run:v1")
    candidate = (
        plan["baseline"]
        if job["candidateID"] == plan["baseline"]["id"]
        else plan["candidate"]
    )
    errors: list[str] = []
    if summary["status"] != "completed" or run["status"] != "completed":
        errors.append("child execution did not complete")
    if summary["model"] != plan["model"] or run["execution"]["model"] != plan["model"]:
        errors.append("child model differs from the paired plan")
    if summary["candidate"] != candidate["id"] or run["candidate"]["id"] != candidate["id"]:
        errors.append("child candidate differs from the scheduled job")
    if summary["marginSha256"] != candidate["marginSha256"]:
        errors.append("summary Margin digest differs from the frozen candidate")
    if run["candidate"] != {
        "id": candidate["id"],
        "marginSha256": candidate["marginSha256"],
        "manualSha256": candidate["manualSha256"],
        "settingsSha256": candidate["settingsSha256"],
    }:
        errors.append("run candidate bundle differs from the frozen candidate")
    if run["benchmark"].get("implementationSha256") != plan["benchmarkImplementationSha256"]:
        errors.append("run benchmark implementation differs from the paired plan")
    if run["benchmark"]["taskSet"] != plan["taskSet"]:
        errors.append("run task set differs from the paired plan")
    if (
        run["benchmark"]["version"] != plan["benchmarkVersion"]
        or run["benchmark"]["developmentCases"] != plan["developmentCases"]
    ):
        errors.append("run benchmark identity differs from the paired plan")
    if run["track"] != plan["track"]:
        errors.append("run track differs from the paired plan")
    if run["execution"].get("controlProfile") != plan["controlProfile"]:
        errors.append("run control profile differs from the paired plan")
    expected_execution_identity = {
        "adapter": "prime-verifiers-v1",
        "provider": "Prime Intellect",
        "harness": "null-with-one-margin-tool",
        "runtime": "local-subprocess-environment-with-prime-inference",
    }
    if any(run["execution"].get(name) != value for name, value in expected_execution_identity.items()):
        errors.append("run execution identity differs from the paired Prime adapter")
    expected_limits = {
        "maxConcurrentEpisodes": plan["limits"]["maxConcurrent"],
        "maxInputTokens": plan["limits"]["maxInputTokens"],
        "maxOutputTokens": plan["limits"]["maxOutputTokens"],
        "maxTotalTokens": plan["limits"]["maxTotalTokens"],
        "inputTokenCeilingPerCall": plan["limits"]["inputTokenCeilingPerCall"],
        "upstreamAttemptsPerTurn": plan["limits"]["upstreamAttemptsPerTurn"],
        "billingOverheadUSDPerCall": plan["pricing"]["billingOverheadUSDPerCall"],
        "maxTokensPerCall": plan["limits"]["maxTokensPerCall"],
        "maxTurns": plan["limits"]["maxTurns"],
        "rolloutTimeoutSeconds": plan["limits"]["rolloutTimeoutSeconds"],
        "temperature": plan["limits"]["temperature"],
        "liveProxyMaxRequestBytes": plan["limits"]["liveProxyMaxRequestBytes"],
        "liveProxyTemplateTokenAllowance": plan["limits"][
            "liveProxyTemplateTokenAllowance"
        ],
    }
    if run["execution"].get("limits") != expected_limits:
        errors.append("run limits differ from the paired plan")
    if run["execution"].get("agentProcessCount") != len(job["roles"]):
        errors.append("run process count differs from the scheduled roles")
    if set(run["execution"]["roles"]) != set(job["roles"]):
        errors.append("run roles differ from the scheduled job")
    if len(summary["episodes"]) != 1 or len(run["episodes"]) != 1:
        errors.append("a scheduled job must publish exactly one episode")
    else:
        summary_episode = summary["episodes"][0]
        run_episode = run["episodes"][0]
        identities = {
            "summary": (
                summary_episode["episodeID"],
                summary_episode.get("scenario"),
                summary_episode.get("repetition"),
                summary_episode.get("fingerprint"),
            ),
            "run": (
                run_episode["id"],
                run_episode["scenario"],
                run_episode["repetition"],
                run_episode["fingerprint"],
            ),
            "job": (
                job["episodeID"],
                job["scenario"],
                job["repetition"],
                job["fingerprint"],
            ),
        }
        if len(set(identities.values())) != 1:
            errors.append("child episode identity differs from the scheduled job")
        for summary_name, run_name in (
            ("score", "score"),
            ("safetyPassed", "safetyPassed"),
            ("sourcePreserved", "sourcePreserved"),
            ("commandCount", "commandCount"),
            ("invalidCommandCount", "invalidCommandCount"),
            ("durationMs", "durationMs"),
            ("marginSha256", "marginSha256"),
            ("checks", "checks"),
            ("dimensions", "dimensions"),
            ("usage", "usage"),
        ):
            if summary_episode.get(summary_name) != run_episode.get(run_name):
                errors.append(f"summary and run disagree on {summary_name}")
    if not math.isclose(
        summary["estimatedMaximumCostUSD"],
        job["estimatedMaximumCostUSD"],
        abs_tol=0.000001,
    ):
        errors.append("child admission bound differs from the scheduled job bound")
    if not math.isclose(
        run["cost"].get("admissionBound", -1),
        job["estimatedMaximumCostUSD"],
        abs_tol=0.000001,
    ):
        errors.append("run admission bound differs from the scheduled job bound")
    if summary["wallet"]["observedDebitUSD"] > job["estimatedMaximumCostUSD"] + 0.000001:
        errors.append("observed wallet debit exceeds the scheduled job bound")
    expected_basis = {
        "inputTokenCeilingPerCall": plan["limits"]["inputTokenCeilingPerCall"],
        "outputTokenCeilingPerCall": plan["limits"]["maxTokensPerCall"],
        "modelCallsPerAgentAtMost": plan["limits"]["maxTurns"],
        "upstreamAttemptsPerTurnAtMost": plan["limits"]["upstreamAttemptsPerTurn"],
        "inputPricePerMillion": plan["pricing"]["inputPricePerMillion"],
        "outputPricePerMillion": plan["pricing"]["outputPricePerMillion"],
        "billingOverheadUSDPerCall": plan["pricing"]["billingOverheadUSDPerCall"],
    }
    if run["cost"].get("boundBasis") != expected_basis:
        errors.append("run cost basis differs from the paired plan")
    expected_live_policy = {
        "allowedModel": plan["model"],
        "maxRequestBytes": plan["limits"]["liveProxyMaxRequestBytes"],
        "templateTokenAllowance": plan["limits"]["liveProxyTemplateTokenAllowance"],
        "inputTokenCeiling": plan["limits"]["inputTokenCeilingPerCall"],
        "maxOutputTokens": plan["limits"]["maxTokensPerCall"],
        "inputPricePerMillion": plan["pricing"]["inputPricePerMillion"],
        "outputPricePerMillion": plan["pricing"]["outputPricePerMillion"],
        "billingOverheadUSDPerCall": plan["pricing"]["billingOverheadUSDPerCall"],
        "maxTotalCostUSD": job["liveProxyCapUSD"],
    }
    if summary.get("contractMaximumCostUSD") != job["contractMaximumCostUSD"]:
        errors.append("summary contract bound differs from the paired plan")
    if summary.get("liveBudgetCapUSD") != job["liveProxyCapUSD"]:
        errors.append("summary live proxy cap differs from the paired plan")
    if run["cost"].get("contractBound") != job["contractMaximumCostUSD"]:
        errors.append("run contract bound differs from the paired plan")
    if run["cost"].get("liveBudgetCap") != job["liveProxyCapUSD"]:
        errors.append("run live proxy cap differs from the paired plan")
    if summary.get("liveBudget", {}).get("policy") != expected_live_policy:
        errors.append("summary live proxy policy differs from the paired plan")
    if run["cost"].get("liveBudget") != summary.get("liveBudget"):
        errors.append("summary and run disagree on live proxy accounting")
    if run["cost"]["observedWalletDebit"] != summary["wallet"]["observedDebitUSD"]:
        errors.append("summary and run disagree on observed wallet debit")
    if (
        summary["scenarios"] != [job["scenario"]]
        or summary["repetitions"] != 1
        or summary["exitCode"] != 0
        or not summary.get("traceConsistencyPassed", False)
    ):
        errors.append("summary execution identity differs from the scheduled job")
    if errors:
        raise PrimeStudyError("; ".join(errors[:8]))
    receipt = {
        "schema": PRIME_STUDY_JOB_RECEIPT_SCHEMA,
        "planID": plan["id"],
        "jobID": job["id"],
        "ordinal": job["ordinal"],
        "candidateID": job["candidateID"],
        "episodeID": job["episodeID"],
        "summary": {"path": summary_relative_path, "sha256": summary_sha256},
        "run": {"path": run_relative_path, "sha256": run_sha256},
        "observedWalletDebitUSD": summary["wallet"]["observedDebitUSD"],
        "traceReportedCostUSD": run["cost"]["traceReported"],
        "modelCalls": sum(item["usage"]["modelCalls"] for item in run["episodes"]),
        "safetyPassed": all(item["safetyPassed"] for item in run["episodes"]),
        "sourcePreserved": all(item["sourcePreserved"] for item in run["episodes"]),
        "privacy": {
            "rawTracesPublished": False,
            "credentialsPresent": False,
            "holdoutKeyPublished": False,
        },
    }
    validation = validate_bytes(canonical_json(receipt))
    if not validation["valid"]:
        details = "; ".join(validation.get("errors", ())[:3])
        raise RuntimeError(details or "Generated job receipt violated its public contract.")
    return receipt
