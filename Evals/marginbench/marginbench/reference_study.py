"""No-model paired-study execution and publication-bundle assembly."""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .candidates import CandidateManifest, paired_compare
from .controls import require_implemented_profile
from .entropy import PUBLIC_DEVELOPMENT_KEY
from .keys import read_holdout_key
from .provenance import implementation_sha256
from .runner import ReferenceDriver, run_episode
from .scenarios import generate_episode
from .schema import EpisodeResult, canonical_json, sha256_bytes
from .scheduling import build_execution_plan_from_study
from .submission import build_submission, verify_submission
from .validation import MAX_ARTIFACT_BYTES, validate_bytes


class ReferenceStudyError(ValueError):
    pass


def _file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as handle:
            for block in iter(lambda: handle.read(1_048_576), b""):
                digest.update(block)
    except OSError as error:
        raise ReferenceStudyError("Candidate Margin executable could not be read.") from error
    return digest.hexdigest()


def _snapshot(path: Path, schema: str) -> tuple[dict[str, Any], bytes, str]:
    target = path.expanduser().resolve()
    try:
        with target.open("rb") as handle:
            raw = handle.read(MAX_ARTIFACT_BYTES + 1)
    except OSError as error:
        raise ReferenceStudyError("A required study artifact could not be read.") from error
    receipt = validate_bytes(raw)
    if not receipt["valid"] or receipt["artifactSchema"] != schema:
        details = "; ".join(receipt.get("errors", ())[:3])
        raise ReferenceStudyError(details or "A required study artifact is invalid.")
    return json.loads(raw), raw, receipt["sha256"]


def _candidate(path: Path, binary: Path, expected_id: str) -> tuple[CandidateManifest, bytes]:
    value, raw, _ = _snapshot(path, "urn:marginbench:candidate:v1")
    manifest = CandidateManifest(**value)
    executable = binary.expanduser().resolve()
    if manifest.id != expected_id:
        raise ReferenceStudyError("Candidate manifest ID does not match the study plan.")
    if not executable.is_file() or not os.access(executable, os.X_OK):
        raise ReferenceStudyError("Candidate Margin executable is unavailable.")
    if _file_sha256(executable) != manifest.margin_sha256:
        raise ReferenceStudyError("Candidate manifest does not match its Margin executable.")
    return manifest, raw


def _key(path: Path | None, development_cases: bool) -> bytes:
    if path is None:
        if not development_cases:
            raise ReferenceStudyError("Private studies require --key-file.")
        return PUBLIC_DEVELOPMENT_KEY
    if development_cases:
        raise ReferenceStudyError("Public-development studies must not be run with a private key.")
    try:
        raw, _ = read_holdout_key(path)
    except ValueError as error:
        raise ReferenceStudyError(str(error)) from error
    return raw


def _run_manifest(
    manifest: CandidateManifest,
    results: list[EpisodeResult],
    study: dict[str, Any],
    *,
    started_at: str,
    package_root: Path,
) -> dict[str, Any]:
    roles = sorted({
        role
        for episode in study["episodes"]
        for role in episode["roles"]
    })
    episodes = [{
        "id": result.episode_id,
        "scenario": result.episode_id.split(":", 1)[0],
        "fingerprint": next(
            item["fingerprint"] for item in study["episodes"] if item["id"] == result.episode_id
        ),
        "repetition": next(
            item["repetition"] for item in study["episodes"] if item["id"] == result.episode_id
        ),
        "score": result.score,
        "safetyPassed": result.safety_passed,
        "sourcePreserved": result.source_preserved,
        "commandCount": result.command_count,
        "invalidCommandCount": result.invalid_command_count,
        "durationMs": result.duration_ms,
        "marginSha256": result.margin_sha256,
        "checks": result.checks,
        "dimensions": result.dimensions,
        "usage": {
            "modelCalls": 0,
            "promptTokens": 0,
            "completionTokens": 0,
            "cachedInputTokens": 0,
            "reasoningTokens": 0,
            "reportedCostUSD": 0,
        },
    } for result in sorted(results, key=lambda item: item.episode_id)]
    run_id = sha256_bytes(canonical_json({
        "candidate": manifest.digest(),
        "episodes": [item["id"] for item in episodes],
        "implementation": implementation_sha256(package_root),
        "study": study["taskSet"],
    }))[:32]
    return {
        "schema": "urn:marginbench:run:v1",
        "runID": f"reference-{run_id}",
        "status": "completed",
        "track": "interface",
        "benchmark": {
            "name": "MarginBench",
            "version": study["benchmarkVersion"],
            "taskSet": study["taskSet"],
            "developmentCases": study["developmentCases"],
            "implementationSha256": implementation_sha256(package_root),
        },
        "candidate": {
            "id": manifest.id,
            "marginSha256": manifest.margin_sha256,
            "manualSha256": manifest.manual_sha256,
            "settingsSha256": manifest.settings_sha256,
        },
        "execution": {
            "adapter": "provider-independent-reference-v1",
            "provider": "local",
            "model": "deterministic-reference-policy",
            "harness": "one-confined-margin-gateway",
            "runtime": "local-process",
            "controlProfile": study["controlProfile"],
            "roles": roles,
            "startedAt": started_at,
            "durationMs": sum(result.duration_ms for result in results),
            "limits": {"paidModelCalls": 0, "referencePolicy": "v1"},
            "retryPolicy": "No retry; any incomplete job aborts the atomic output build.",
            "priorInfrastructureAttempts": 0,
        },
        "episodes": episodes,
        "cost": {
            "currency": "USD",
            "traceReported": 0,
            "observedWalletDebit": 0,
            "unreconciled": 0,
        },
        "privacy": {
            "rawTracesPublished": False,
            "credentialsPresent": False,
            "promptsPublished": False,
            "holdoutKeyPublished": False,
        },
    }


def run_reference_study(
    output: Path,
    *,
    study_plan: Path,
    execution_plan: Path,
    baseline_manifest: Path,
    baseline_binary: Path,
    candidate_manifest: Path,
    candidate_binary: Path,
    key_file: Path | None = None,
    package_root: Path,
) -> dict[str, Any]:
    output = output.expanduser().resolve()
    if output.exists() or not output.parent.is_dir():
        raise ReferenceStudyError("Output must be a new path inside an existing directory.")
    study, study_raw, study_sha256 = _snapshot(study_plan, "urn:marginbench:study-plan:v1")
    try:
        require_implemented_profile(study["controlProfile"])
    except ValueError as error:
        raise ReferenceStudyError(str(error)) from error
    execution, execution_raw, _ = _snapshot(
        execution_plan,
        "urn:marginbench:execution-plan:v1",
    )
    if execution != build_execution_plan_from_study(study, study_sha256):
        raise ReferenceStudyError("Execution plan is not the exact expansion of the study plan.")
    baseline, baseline_raw = _candidate(
        baseline_manifest,
        baseline_binary,
        study["baselineCandidate"],
    )
    candidate, candidate_raw = _candidate(
        candidate_manifest,
        candidate_binary,
        study["candidate"],
    )
    key = _key(key_file, study["developmentCases"])
    candidates = {
        baseline.id: (baseline, baseline_binary.expanduser().resolve()),
        candidate.id: (candidate, candidate_binary.expanduser().resolve()),
    }
    results: dict[str, list[EpisodeResult]] = {baseline.id: [], candidate.id: []}
    started_at = datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")
    for job in execution["jobs"]:
        episode = generate_episode(job["scenario"], key, job["repetition"])
        if episode.public_id != job["episodeID"] or episode.fingerprint != job["fingerprint"]:
            raise ReferenceStudyError("Holdout key does not reproduce the planned episode.")
        manifest, binary = candidates[job["candidateID"]]
        with tempfile.TemporaryDirectory(prefix="marginbench-reference-study-job-") as temporary:
            result = run_episode(
                episode,
                binary,
                Path(temporary) / "workspace",
                ReferenceDriver(),
                candidate_id=manifest.id,
                control_profile=study["controlProfile"],
            )
        results[manifest.id].append(result)

    baseline_run = _run_manifest(
        baseline,
        results[baseline.id],
        study,
        started_at=started_at,
        package_root=package_root,
    )
    candidate_run = _run_manifest(
        candidate,
        results[candidate.id],
        study,
        started_at=started_at,
        package_root=package_root,
    )
    comparison = paired_compare(
        results[baseline.id],
        results[candidate.id],
        minimum_pairs=study["minimumPairsForPromotion"],
    )

    staging = Path(tempfile.mkdtemp(prefix=f".{output.name}.marginbench-", dir=output.parent))
    try:
        (staging / "runs").mkdir()
        files = {
            "baseline-candidate.json": baseline_raw,
            "candidate.json": candidate_raw,
            "study-plan.json": study_raw,
            "execution-plan.json": execution_raw,
            "comparison.json": canonical_json(comparison),
            "runs/baseline.json": canonical_json(baseline_run),
            "runs/candidate.json": canonical_json(candidate_run),
        }
        for relative, raw in files.items():
            (staging / relative).write_bytes(raw)
        submission = build_submission(
            staging,
            baseline_manifest=Path("baseline-candidate.json"),
            candidate_manifest=Path("candidate.json"),
            study_plan=Path("study-plan.json"),
            execution_plan=Path("execution-plan.json"),
            comparison=Path("comparison.json"),
            runs=[Path("runs/baseline.json"), Path("runs/candidate.json")],
        )
        (staging / "submission.json").write_bytes(canonical_json(submission))
        verification = verify_submission(staging / "submission.json")
        if not verification["valid"]:
            raise RuntimeError("Generated reference-study submission failed verification.")
        (staging / "verification.json").write_bytes(canonical_json(verification))
        os.replace(staging, output)
    except Exception:
        shutil.rmtree(staging, ignore_errors=True)
        raise
    return {
        "schema": "urn:marginbench:reference-study-receipt:v1",
        "paidModelsInvoked": False,
        "output": str(output),
        "episodeCount": study["episodeCount"],
        "jobCount": execution["jobCount"],
        "baselineMinimumScore": min(result.score for result in results[baseline.id]),
        "candidateMinimumScore": min(result.score for result in results[candidate.id]),
        "submissionID": submission["id"],
        "verified": True,
    }
