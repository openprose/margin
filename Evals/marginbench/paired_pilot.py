#!/usr/bin/env python3
"""Resumable, budget-gated paired Prime study controller.

Dry-run is the default. Paid execution requires one literal confirmation, a
complete immutable study plan, and enough wallet balance to preserve the
declared reserve after the full worst-case admission bound.
"""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any, Callable

sys.dont_write_bytecode = True
PACKAGE_ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(PACKAGE_ROOT))

from marginbench.candidates import paired_compare  # noqa: E402
from marginbench.diagnostics import DiagnosticError, diagnose_artifacts  # noqa: E402
from marginbench.keys import read_holdout_key  # noqa: E402
from marginbench.prime_study import (  # noqa: E402
    PrimeStudyError,
    build_prime_study_plan,
    file_sha256,
    validate_prime_job_outputs,
)
from marginbench.schema import EpisodeResult, canonical_json  # noqa: E402
from marginbench.submission import build_submission, verify_submission  # noqa: E402
from marginbench.validation import MAX_ARTIFACT_BYTES, validate_bytes  # noqa: E402
from prime_pilot import (  # noqa: E402
    CONFIRMATION as CHILD_CONFIRMATION,
    DEFAULT_PROVIDER_RESPONSE_TOKEN_ALLOWANCE,
)
from prime_pilot import claim_paid_start, wallet  # noqa: E402


CONFIRMATION = "RUN_PAID_MARGINBENCH_PAIRED_STUDY"


def wait_until_paid_start_allowed(
    path: Path,
    minimum_interval_seconds: float,
    *,
    clock: Callable[[], float] = time.time,
    sleeper: Callable[[float], None] = time.sleep,
) -> None:
    """Wait for the shared provider-start interval without claiming it."""
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


def _read_json(path: Path, schema: str) -> tuple[dict[str, Any], bytes]:
    if path.is_symlink():
        raise PrimeStudyError("Controller artifacts must not be symbolic links.")
    try:
        with path.open("rb") as handle:
            raw = handle.read(MAX_ARTIFACT_BYTES + 1)
    except OSError as error:
        raise PrimeStudyError("A controller artifact could not be read.") from error
    receipt = validate_bytes(raw)
    if not receipt["valid"] or receipt["artifactSchema"] != schema:
        details = "; ".join(receipt.get("errors", ())[:3])
        raise PrimeStudyError(details or "A controller artifact is invalid.")
    return json.loads(raw), raw


def _atomic_write(path: Path, raw: bytes, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        os.fchmod(descriptor, mode)
        written = 0
        while written < len(raw):
            count = os.write(descriptor, raw[written:])
            if count <= 0:
                raise OSError("Atomic write did not make progress.")
            written += count
        os.fsync(descriptor)
        os.close(descriptor)
        descriptor = -1
        os.replace(temporary, path)
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


def _frozen_bytes(source: Path, destination: Path, expected_sha256: str) -> Path:
    if destination.exists():
        if destination.is_symlink() or not destination.is_file():
            raise PrimeStudyError("A frozen controller input has an unsafe file type.")
        if file_sha256(destination) != expected_sha256:
            raise PrimeStudyError("A frozen controller input no longer matches its plan.")
        return destination
    try:
        with source.open("rb") as handle:
            raw = handle.read(MAX_ARTIFACT_BYTES + 1)
    except OSError as error:
        raise PrimeStudyError("A planned controller input could not be read.") from error
    if len(raw) > MAX_ARTIFACT_BYTES or hashlib.sha256(raw).hexdigest() != expected_sha256:
        raise PrimeStudyError("A planned controller input changed before it was frozen.")
    _atomic_write(destination, raw)
    return destination


def _frozen_binary(source: Path, destination: Path, expected_sha256: str) -> Path:
    if destination.exists():
        if destination.is_symlink() or not destination.is_file():
            raise PrimeStudyError("A frozen Margin executable has an unsafe file type.")
        if file_sha256(destination) != expected_sha256 or not os.access(destination, os.X_OK):
            raise PrimeStudyError("A frozen Margin executable no longer matches its plan.")
        return destination
    destination.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{destination.name}.", dir=destination.parent)
    temporary = Path(temporary_name)
    digest = hashlib.sha256()
    try:
        with source.open("rb") as handle:
            while block := handle.read(1_048_576):
                digest.update(block)
                written = 0
                while written < len(block):
                    count = os.write(descriptor, block[written:])
                    if count <= 0:
                        raise OSError("Frozen executable write did not make progress.")
                    written += count
        if digest.hexdigest() != expected_sha256:
            raise PrimeStudyError("A Margin executable changed while it was being frozen.")
        os.fchmod(descriptor, 0o500)
        os.fsync(descriptor)
        os.close(descriptor)
        descriptor = -1
        os.replace(temporary, destination)
        if hasattr(os, "O_DIRECTORY"):
            directory = os.open(destination.parent, os.O_RDONLY | os.O_DIRECTORY)
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
    return destination


def _freeze_inputs(
    arguments: argparse.Namespace,
    plan: dict[str, Any],
    work: Path,
) -> dict[str, Path | None]:
    root = work / "frozen-inputs"
    root.mkdir(mode=0o700, exist_ok=True)
    root_identity = root.stat()
    if root_identity.st_uid != os.getuid() or root_identity.st_mode & 0o077:
        raise PrimeStudyError("Frozen-input directory must be private and owned by this user.")
    frozen: dict[str, Path | None] = {
        "baselineManifest": _frozen_bytes(
            arguments.baseline_manifest,
            root / "baseline-candidate.json",
            plan["baseline"]["manifestSha256"],
        ),
        "candidateManifest": _frozen_bytes(
            arguments.candidate_manifest,
            root / "candidate.json",
            plan["candidate"]["manifestSha256"],
        ),
        "studyPlan": _frozen_bytes(
            arguments.study_plan,
            root / "study-plan.json",
            plan["studyPlanSha256"],
        ),
        "executionPlan": _frozen_bytes(
            arguments.execution_plan,
            root / "execution-plan.json",
            plan["executionPlanSha256"],
        ),
        "baselineBinary": _frozen_binary(
            arguments.baseline_bin,
            root / "margin-baseline",
            plan["baseline"]["marginSha256"],
        ),
        "candidateBinary": _frozen_binary(
            arguments.candidate_bin,
            root / "margin-candidate",
            plan["candidate"]["marginSha256"],
        ),
        "holdoutKey": None,
    }
    if plan["developmentCases"]:
        if arguments.holdout_key_file is not None:
            raise PrimeStudyError("Public-development execution must not freeze a private key.")
    else:
        if arguments.holdout_key_file is None:
            raise PrimeStudyError("Private execution requires its planned holdout key.")
        value, key_id = read_holdout_key(arguments.holdout_key_file)
        if key_id != plan["generationKeyID"]:
            raise PrimeStudyError("Holdout key changed before paid execution.")
        destination = root / "holdout.key"
        if destination.exists():
            frozen_value, frozen_id = read_holdout_key(destination)
            if frozen_value != value or frozen_id != key_id:
                raise PrimeStudyError("Frozen holdout key no longer matches the paired plan.")
        else:
            _atomic_write(destination, value + b"\n")
        frozen["holdoutKey"] = destination
    return frozen


def _safe_relative(root: Path, relative: str) -> Path:
    candidate = root / relative
    resolved = candidate.resolve()
    try:
        resolved.relative_to(root.resolve())
    except ValueError as error:
        raise PrimeStudyError("Controller evidence path leaves its work directory.") from error
    if candidate.is_symlink():
        raise PrimeStudyError("Controller evidence must not be a symbolic link.")
    return resolved


def _job_paths(work: Path, job: dict[str, Any]) -> dict[str, Any]:
    stem = f"{job['ordinal']:04d}-{job['id'].split(':', 1)[1][:16]}"
    return {
        "stem": stem,
        "raw": work / "raw" / stem,
        "summary": work / "redacted" / "jobs" / f"{stem}.summary.json",
        "run": work / "redacted" / "jobs" / f"{stem}.run.json",
        "receipt": work / "redacted" / "jobs" / f"{stem}.receipt.json",
        "attempt": work / "redacted" / "jobs" / f"{stem}.attempt.json",
        "summaryRelative": f"redacted/jobs/{stem}.summary.json",
        "runRelative": f"redacted/jobs/{stem}.run.json",
    }


def _load_verified_receipt(
    work: Path,
    plan: dict[str, Any],
    job: dict[str, Any],
) -> dict[str, Any] | None:
    paths = _job_paths(work, job)
    if not paths["receipt"].exists():
        return None
    receipt, raw = _read_json(
        paths["receipt"],
        "urn:marginbench:prime-study-job-receipt:v1",
    )
    if (
        receipt["planID"] != plan["id"]
        or receipt["jobID"] != job["id"]
        or receipt["ordinal"] != job["ordinal"]
    ):
        raise PrimeStudyError("A saved job receipt belongs to a different paired plan.")
    summary = _safe_relative(work, receipt["summary"]["path"])
    run = _safe_relative(work, receipt["run"]["path"])
    expected = validate_prime_job_outputs(
        plan,
        job,
        summary_path=summary,
        run_path=run,
        summary_relative_path=receipt["summary"]["path"],
        run_relative_path=receipt["run"]["path"],
    )
    if expected != receipt or canonical_json(receipt) != raw:
        raise PrimeStudyError("A saved job receipt is not canonical or no longer matches its evidence.")
    return receipt


def _adopt_completed_attempt(
    work: Path,
    plan: dict[str, Any],
    job: dict[str, Any],
) -> dict[str, Any] | None:
    paths = _job_paths(work, job)
    present = (
        paths["summary"].exists(),
        paths["run"].exists(),
        paths["raw"].exists(),
        paths["attempt"].exists(),
    )
    if not any(present):
        return None
    if not all(present[:2]):
        raise PrimeStudyError(
            "An unreceipted paid attempt is incomplete. It will not be retried automatically; "
            "inspect the ignored raw directory and start a separately identified recovery run."
        )
    receipt = validate_prime_job_outputs(
        plan,
        job,
        summary_path=paths["summary"],
        run_path=paths["run"],
        summary_relative_path=paths["summaryRelative"],
        run_relative_path=paths["runRelative"],
    )
    _atomic_write(paths["receipt"], canonical_json(receipt))
    return receipt


def _child_command(
    arguments: argparse.Namespace,
    plan: dict[str, Any],
    job: dict[str, Any],
    paths: dict[str, Any],
    frozen: dict[str, Path | None],
) -> list[str]:
    candidate_manifest = (
        frozen["baselineManifest"]
        if job["candidateID"] == plan["baseline"]["id"]
        else frozen["candidateManifest"]
    )
    binary = (
        frozen["baselineBinary"]
        if job["candidateID"] == plan["baseline"]["id"]
        else frozen["candidateBinary"]
    )
    limits = plan["limits"]
    pricing = plan["pricing"]
    command = [
        sys.executable,
        str(PACKAGE_ROOT / "prime_pilot.py"),
        "--margin-bin", str(binary),
        "--model", plan["model"],
        "--scenario", job["scenario"],
        "--repetition-id", str(job["repetition"]),
        "--candidate", job["candidateID"],
        "--candidate-manifest", str(candidate_manifest),
        "--control-profile", plan["controlProfile"],
        "--track", plan["track"],
        "--temperature", str(limits["temperature"]),
        "--max-tokens-per-call", str(limits["maxTokensPerCall"]),
        "--provider-response-token-allowance",
        str(limits["providerResponseTokenAllowance"]),
        "--max-turns", str(limits["maxTurns"]),
        "--max-input-tokens", str(limits["maxInputTokens"]),
        "--max-output-tokens", str(limits["maxOutputTokens"]),
        "--max-total-tokens", str(limits["maxTotalTokens"]),
        "--input-token-ceiling-per-call", str(limits["inputTokenCeilingPerCall"]),
        "--upstream-attempts-per-turn", str(limits["upstreamAttemptsPerTurn"]),
        "--billing-overhead-usd-per-call", str(pricing["billingOverheadUSDPerCall"]),
        "--rollout-timeout-seconds", str(limits["rolloutTimeoutSeconds"]),
        "--wall-timeout-seconds", str(limits["wallTimeoutSeconds"]),
        "--max-concurrent", str(limits["maxConcurrent"]),
        "--minimum-start-interval-seconds", "0",
        "--minimum-request-interval-seconds", str(
            limits.get("minimumRequestIntervalSeconds", 0.0)
        ),
        "--live-proxy-timeout-seconds", str(
            limits.get("liveProxyTimeoutSeconds", 120.0)
        ),
        "--input-price-per-million", str(pricing["inputPricePerMillion"]),
        "--output-price-per-million", str(pricing["outputPricePerMillion"]),
        "--max-cost-usd", str(max(job["estimatedMaximumCostUSD"], 0.000001)),
        "--live-proxy-cost-cap-usd", str(job["liveProxyCapUSD"]),
        "--live-proxy-max-request-bytes", str(limits["liveProxyMaxRequestBytes"]),
        "--live-proxy-template-token-allowance",
        str(limits["liveProxyTemplateTokenAllowance"]),
        "--output-dir", str(paths["raw"]),
        "--summary-file", str(paths["summary"]),
        "--run-manifest-file", str(paths["run"]),
        "--execute",
        "--confirm-paid", CHILD_CONFIRMATION,
    ]
    if frozen["holdoutKey"] is not None:
        command += ["--holdout-key-file", str(frozen["holdoutKey"])]
    return command


def _episode_result(run: dict[str, Any]) -> EpisodeResult:
    episode = run["episodes"][0]
    return EpisodeResult(
        episode_id=episode["id"],
        candidate_id=run["candidate"]["id"],
        score=episode["score"],
        dimensions=episode["dimensions"],
        checks=episode["checks"],
        command_count=episode["commandCount"],
        invalid_command_count=episode["invalidCommandCount"],
        duration_ms=episode["durationMs"],
        safety_passed=episode["safetyPassed"],
        source_preserved=episode["sourcePreserved"],
        margin_sha256=episode["marginSha256"],
    )


def _copy_exact(source: Path, destination: Path) -> None:
    raw = source.read_bytes()
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(raw)


def _validated_receipt(value: dict[str, Any]) -> dict[str, Any]:
    validation = validate_bytes(canonical_json(value))
    if not validation["valid"]:
        details = "; ".join(validation.get("errors", ())[:3])
        raise PrimeStudyError(details or "Controller generated an invalid public receipt.")
    return value


def _final_receipt(output: Path, plan: dict[str, Any], receipts: list[dict[str, Any]]) -> dict[str, Any]:
    verification = verify_submission(output / "submission.json")
    if not verification["valid"]:
        raise PrimeStudyError("Completed publication bundle does not verify.")
    submission = json.loads((output / "submission.json").read_bytes())
    diagnostic, diagnostic_raw = _read_json(
        output / "diagnostic.json",
        "urn:marginbench:diagnostic-report:v1",
    )
    diagnostic_inputs = sorted(item["sha256"] for item in diagnostic["artifacts"])
    submission_runs = sorted(item["sha256"] for item in submission["runs"])
    if diagnostic_inputs != submission_runs:
        raise PrimeStudyError("Completed diagnostic report does not cover the published runs.")
    return _validated_receipt({
        "schema": "urn:marginbench:prime-study-completion:v1",
        "completed": True,
        "paidModelsInvoked": True,
        "planID": plan["id"],
        "jobCount": len(receipts),
        "observedWalletDebitUSD": round(
            sum(float(item["observedWalletDebitUSD"]) for item in receipts),
            6,
        ),
        "traceReportedCostUSD": round(
            sum(float(item["traceReportedCostUSD"]) for item in receipts),
            6,
        ),
        "modelCalls": sum(int(item["modelCalls"]) for item in receipts),
        "allSafe": all(item["safetyPassed"] for item in receipts),
        "allSourcePreserved": all(item["sourcePreserved"] for item in receipts),
        "submissionID": submission["id"],
        "diagnostic": {
            "path": "diagnostic.json",
            "sha256": hashlib.sha256(diagnostic_raw).hexdigest(),
            "topOpportunity": diagnostic["topOpportunity"],
        },
        "verified": True,
        "output": str(output),
    })


def _finalize(
    arguments: argparse.Namespace,
    plan: dict[str, Any],
    work: Path,
    receipts: list[dict[str, Any]],
    frozen: dict[str, Path | None],
) -> dict[str, Any]:
    output = arguments.publication_dir
    if output.exists():
        if output.is_symlink() or not output.is_dir():
            raise PrimeStudyError("Publication path must be a real directory.")
        existing_plan, raw = _read_json(
            output / "prime-study-plan.json",
            "urn:marginbench:prime-study-plan:v1",
        )
        if existing_plan != plan or raw != canonical_json(plan):
            raise PrimeStudyError("Existing publication directory belongs to a different plan.")
        return _final_receipt(output, plan, receipts)
    if not output.parent.is_dir():
        raise PrimeStudyError("Publication parent directory must already exist.")
    staging = Path(tempfile.mkdtemp(prefix=f".{output.name}.prime-study-", dir=output.parent))
    try:
        (staging / "runs").mkdir()
        _copy_exact(frozen["baselineManifest"], staging / "baseline-candidate.json")
        _copy_exact(frozen["candidateManifest"], staging / "candidate.json")
        _copy_exact(frozen["studyPlan"], staging / "study-plan.json")
        _copy_exact(frozen["executionPlan"], staging / "execution-plan.json")
        (staging / "prime-study-plan.json").write_bytes(canonical_json(plan))
        baseline_results: list[EpisodeResult] = []
        candidate_results: list[EpisodeResult] = []
        run_relatives: list[Path] = []
        for receipt in receipts:
            run_source = _safe_relative(work, receipt["run"]["path"])
            run, raw = _read_json(run_source, "urn:marginbench:run:v1")
            relative = Path("runs") / f"{receipt['ordinal']:04d}.json"
            (staging / relative).write_bytes(raw)
            run_relatives.append(relative)
            result = _episode_result(run)
            destination = (
                baseline_results
                if result.candidate_id == plan["baseline"]["id"]
                else candidate_results
            )
            destination.append(result)
        study, _ = _read_json(frozen["studyPlan"], "urn:marginbench:study-plan:v1")
        comparison = paired_compare(
            baseline_results,
            candidate_results,
            minimum_pairs=study["minimumPairsForPromotion"],
        )
        (staging / "comparison.json").write_bytes(canonical_json(comparison))
        submission = build_submission(
            staging,
            baseline_manifest=Path("baseline-candidate.json"),
            candidate_manifest=Path("candidate.json"),
            study_plan=Path("study-plan.json"),
            execution_plan=Path("execution-plan.json"),
            comparison=Path("comparison.json"),
            runs=run_relatives,
        )
        (staging / "submission.json").write_bytes(canonical_json(submission))
        verification = verify_submission(staging / "submission.json")
        if not verification["valid"]:
            raise PrimeStudyError("Generated paid-study submission failed verification.")
        (staging / "verification.json").write_bytes(canonical_json(verification))
        try:
            diagnostic = diagnose_artifacts(
                [staging / relative for relative in run_relatives],
                focus_candidate=plan["candidate"]["id"],
            )
        except DiagnosticError as error:
            raise PrimeStudyError("Generated paid-study diagnosis failed.") from error
        diagnostic_raw = canonical_json(diagnostic)
        if not validate_bytes(diagnostic_raw)["valid"]:
            raise PrimeStudyError("Generated paid-study diagnosis failed validation.")
        (staging / "diagnostic.json").write_bytes(diagnostic_raw)
        os.replace(staging, output)
    except Exception:
        shutil.rmtree(staging, ignore_errors=True)
        raise
    return _final_receipt(output, plan, receipts)


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
        raise PrimeStudyError("Work path must be a real directory.")
    if not work.exists():
        work.mkdir(mode=0o700, parents=False)
    work_identity = work.stat()
    if work_identity.st_uid != os.getuid() or work_identity.st_mode & 0o077:
        raise PrimeStudyError("Work directory must be private and owned by this user.")
    lock_flags = os.O_RDWR | os.O_CREAT
    if hasattr(os, "O_NOFOLLOW"):
        lock_flags |= os.O_NOFOLLOW
    lock_descriptor = os.open(work / ".controller.lock", lock_flags, 0o600)
    lock_identity = os.fstat(lock_descriptor)
    if not stat.S_ISREG(lock_identity.st_mode) or lock_identity.st_uid != os.getuid():
        os.close(lock_descriptor)
        raise PrimeStudyError("Controller lock has an unsafe identity.")
    try:
        fcntl.flock(lock_descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError as error:
        os.close(lock_descriptor)
        raise PrimeStudyError("Another controller already owns this paired study.") from error
    try:
        plan_path = work / "prime-study-plan.json"
        if plan_path.exists():
            saved, raw = _read_json(plan_path, "urn:marginbench:prime-study-plan:v1")
            if saved != plan or raw != canonical_json(plan):
                raise PrimeStudyError("Work directory belongs to a different paired plan.")
        else:
            _atomic_write(plan_path, canonical_json(plan))
        frozen = _freeze_inputs(arguments, plan, work)
        receipts: list[dict[str, Any]] = []
        missing_started = False
        for job in plan["jobs"]:
            receipt = _load_verified_receipt(work, plan, job)
            if receipt is None:
                receipt = _adopt_completed_attempt(work, plan, job)
            if receipt is not None:
                if missing_started:
                    raise PrimeStudyError("Completed job receipts are not a contiguous schedule prefix.")
                receipts.append(receipt)
                continue
            missing_started = True
            break
        if missing_started:
            for later in plan["jobs"][len(receipts) + 1:]:
                later_paths = _job_paths(work, later)
                if any(
                    path.exists()
                    for path in (
                        later_paths["raw"],
                        later_paths["summary"],
                        later_paths["run"],
                        later_paths["receipt"],
                        later_paths["attempt"],
                    )
                ):
                    raise PrimeStudyError(
                        "Saved job evidence is not a contiguous execution-plan prefix."
                    )
        if len(receipts) == len(plan["jobs"]):
            return _finalize(arguments, plan, work, receipts, frozen)

        prime_name = prime_resolver("prime")
        if not prime_name:
            raise PrimeStudyError("Prime CLI is not installed.")
        prime = Path(prime_name).resolve()
        current = wallet_reader(prime)
        remaining_bound = round(
            sum(
                float(item["estimatedMaximumCostUSD"])
                for item in plan["jobs"][len(receipts):]
            ),
            6,
        )
        reserve = float(plan["budget"]["minimumWalletReserveUSD"])
        if float(current["balanceUSD"]) + 0.000001 < remaining_bound + reserve:
            raise PrimeStudyError("Wallet cannot cover the remaining admission bound and reserve.")
        new_jobs = 0
        for job in plan["jobs"][len(receipts):]:
            current = wallet_reader(prime)
            remaining_bound = round(
                sum(
                    float(item["estimatedMaximumCostUSD"])
                    for item in plan["jobs"][job["ordinal"]:]
                ),
                6,
            )
            if float(current["balanceUSD"]) + 0.000001 < remaining_bound + reserve:
                raise PrimeStudyError("Wallet fell below the remaining admission bound and reserve.")
            paid_start_path = PACKAGE_ROOT / "runs" / ".last-paid-start"
            start_pacer(
                paid_start_path,
                float(plan["limits"].get("minimumStartIntervalSeconds", 300.0)),
            )
            start_claimer(
                paid_start_path,
                now=arguments.clock(),
                minimum_interval_seconds=plan["limits"].get(
                    "minimumStartIntervalSeconds",
                    300.0,
                ),
            )
            paths = _job_paths(work, job)
            command = _child_command(arguments, plan, job, paths, frozen)
            attempt = {
                "schema": "urn:marginbench:prime-study-attempt:v1",
                "planID": plan["id"],
                "jobID": job["id"],
                "ordinal": job["ordinal"],
                "candidateID": job["candidateID"],
                "repetition": job["repetition"],
                "automaticRetryAllowed": False,
            }
            _atomic_write(paths["attempt"], canonical_json(attempt))
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
                    f"Paid job {job['ordinal']} exceeded its wall timeout. Its attempt marker "
                    "prevents an automatic retry."
                ) from error
            try:
                receipt = _adopt_completed_attempt(work, plan, job)
            except PrimeStudyError as error:
                raise PrimeStudyError(
                    f"Paid job {job['ordinal']} did not produce adoptable evidence (exit "
                    f"{completed.returncode}). No retry was attempted: {error}"
                ) from error
            if receipt is None:
                raise PrimeStudyError(
                    f"Paid job {job['ordinal']} produced no evidence (exit {completed.returncode}). "
                    "No retry was attempted."
                )
            if completed.returncode != 0:
                raise PrimeStudyError(
                    f"Paid job {job['ordinal']} returned {completed.returncode} despite valid evidence; "
                    "operator review is required."
                )
            receipts.append(receipt)
            new_jobs += 1
            observed_total = round(
                sum(float(item["observedWalletDebitUSD"]) for item in receipts),
                6,
            )
            if observed_total > float(plan["budget"]["hardAdmissionCapUSD"]) + 0.000001:
                raise PrimeStudyError(
                    "Observed wallet debit exceeded the hard study cap; execution stopped."
                )
            progress = {
                "schema": "urn:marginbench:prime-study-progress:v1",
                "planID": plan["id"],
                "completedJobs": len(receipts),
                "jobCount": plan["jobCount"],
                "lastJobID": job["id"],
                "observedWalletDebitUSD": observed_total,
            }
            _validated_receipt(progress)
            print(canonical_json(progress).decode("utf-8"), file=sys.stderr, flush=True)
            if new_jobs >= arguments.max_new_jobs and len(receipts) < plan["jobCount"]:
                return _validated_receipt({
                    **progress,
                    "status": "paused",
                    "paidModelsInvoked": True,
                    "nextOrdinal": len(receipts),
                    "automaticRetryPerformed": False,
                })
        return _finalize(arguments, plan, work, receipts, frozen)
    finally:
        fcntl.flock(lock_descriptor, fcntl.LOCK_UN)
        os.close(lock_descriptor)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    parser.add_argument("--study-plan", type=Path, required=True)
    parser.add_argument("--execution-plan", type=Path, required=True)
    parser.add_argument("--baseline-manifest", type=Path, required=True)
    parser.add_argument("--baseline-bin", type=Path, required=True)
    parser.add_argument("--candidate-manifest", type=Path, required=True)
    parser.add_argument("--candidate-bin", type=Path, required=True)
    parser.add_argument("--holdout-key-file", type=Path)
    parser.add_argument("--model", required=True)
    parser.add_argument("--track", default="interface", choices=("interface",))
    parser.add_argument("--max-turns", type=int, default=12)
    parser.add_argument("--max-input-tokens", type=int, default=40_000)
    parser.add_argument("--max-output-tokens", type=int, default=6_000)
    parser.add_argument("--max-total-tokens", type=int, default=16_000)
    parser.add_argument("--input-token-ceiling-per-call", type=int, required=True)
    parser.add_argument(
        "--input-token-ceiling-source",
        required=True,
        help="HTTPS provider/model contract supporting the asserted per-call input ceiling",
    )
    parser.add_argument("--upstream-attempts-per-turn", type=int, default=3)
    parser.add_argument("--max-tokens-per-call", type=int, default=2_400)
    parser.add_argument(
        "--provider-response-token-allowance",
        type=int,
        default=DEFAULT_PROVIDER_RESPONSE_TOKEN_ALLOWANCE,
    )
    parser.add_argument("--max-concurrent", type=int, default=1)
    parser.add_argument("--rollout-timeout-seconds", type=float, default=120.0)
    parser.add_argument("--wall-timeout-seconds", type=float, default=300.0)
    parser.add_argument("--temperature", type=float, default=0.0)
    parser.add_argument("--input-price-per-million", type=float, required=True)
    parser.add_argument("--output-price-per-million", type=float, required=True)
    parser.add_argument(
        "--pricing-source",
        required=True,
        help="HTTPS provider price record supporting the asserted token prices",
    )
    parser.add_argument("--billing-overhead-usd-per-call", type=float, default=0.0002)
    parser.add_argument("--max-study-cost-usd", type=float, default=15.0)
    parser.add_argument(
        "--live-proxy-cap-per-job-usd",
        type=float,
        help=(
            "enforce this cumulative request-reservation cap independently for each paid job; "
            "defaults to the unproxied contract bound"
        ),
    )
    parser.add_argument("--live-proxy-max-request-bytes", type=int, default=1024 * 1024)
    parser.add_argument("--live-proxy-template-token-allowance", type=int, default=8192)
    parser.add_argument("--live-proxy-timeout-seconds", type=float, default=120.0)
    parser.add_argument("--minimum-wallet-reserve-usd", type=float, default=80.0)
    parser.add_argument("--minimum-start-interval-seconds", type=float, default=300.0)
    parser.add_argument("--minimum-request-interval-seconds", type=float, default=0.0)
    parser.add_argument(
        "--max-new-jobs",
        type=int,
        default=1000,
        help="stop cleanly after this many newly completed jobs; resume with the same plan",
    )
    parser.add_argument("--work-dir", type=Path)
    parser.add_argument("--publication-dir", type=Path)
    parser.add_argument("--plan-file", type=Path)
    parser.add_argument("--execute", action="store_true")
    parser.add_argument("--confirm-paid", default="")
    return parser


def main(argv: list[str] | None = None) -> int:
    arguments = _parser().parse_args(argv)
    if arguments.max_new_jobs < 1 or arguments.max_new_jobs > 1000:
        raise SystemExit("max-new-jobs must be between 1 and 1000")
    if not 0 <= arguments.minimum_start_interval_seconds <= 3600:
        raise SystemExit("minimum-start-interval-seconds must be between 0 and 3600")
    if not 0 < arguments.live_proxy_timeout_seconds <= 300:
        raise SystemExit("live-proxy-timeout-seconds must be above zero and at most 300")
    if not 0 <= arguments.minimum_request_interval_seconds <= 60:
        raise SystemExit("minimum-request-interval-seconds must be between 0 and 60")
    for name in (
        "study_plan",
        "execution_plan",
        "baseline_manifest",
        "baseline_bin",
        "candidate_manifest",
        "candidate_bin",
    ):
        setattr(arguments, name, getattr(arguments, name).expanduser().resolve())
    if arguments.holdout_key_file:
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
        "maxConcurrent": arguments.max_concurrent,
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
        plan = build_prime_study_plan(
            study_plan=arguments.study_plan,
            execution_plan=arguments.execution_plan,
            baseline_manifest=arguments.baseline_manifest,
            baseline_binary=arguments.baseline_bin,
            candidate_manifest=arguments.candidate_manifest,
            candidate_binary=arguments.candidate_bin,
            model=arguments.model,
            limits=limits,
            pricing=pricing,
            hard_admission_cap_usd=arguments.max_study_cost_usd,
            minimum_wallet_reserve_usd=arguments.minimum_wallet_reserve_usd,
            package_root=PACKAGE_ROOT,
            live_proxy_cap_per_job_usd=arguments.live_proxy_cap_per_job_usd,
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
        arguments.work_dir or PACKAGE_ROOT / "runs" / f"paired-{suffix}"
    ).expanduser().resolve()
    arguments.publication_dir = (
        arguments.publication_dir or arguments.work_dir / "publication"
    ).expanduser().resolve()
    import time

    arguments.clock = time.time
    try:
        receipt = execute_study(arguments, plan)
    except (PrimeStudyError, RuntimeError, OSError) as error:
        raise SystemExit(str(error)) from error
    print(canonical_json(receipt).decode("utf-8"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
