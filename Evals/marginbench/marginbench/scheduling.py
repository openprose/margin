"""Deterministic, provider-neutral execution schedules for paired studies."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from .schema import canonical_json, sha256_bytes
from .validation import MAX_ARTIFACT_BYTES, submission_identifier, validate_bytes


EXECUTION_PLAN_SCHEMA = "urn:marginbench:execution-plan:v1"


class ExecutionPlanError(ValueError):
    pass


def _study_snapshot(path: Path) -> tuple[dict[str, Any], str]:
    target = path.expanduser().resolve()
    try:
        with target.open("rb") as handle:
            raw = handle.read(MAX_ARTIFACT_BYTES + 1)
    except OSError as error:
        raise ExecutionPlanError("Study plan could not be read.") from error
    if len(raw) > MAX_ARTIFACT_BYTES:
        raise ExecutionPlanError("Study plan exceeds the validation size limit.")
    receipt = validate_bytes(raw)
    if not receipt["valid"] or receipt["artifactSchema"] != "urn:marginbench:study-plan:v1":
        details = "; ".join(receipt.get("errors", ())[:3])
        raise ExecutionPlanError(details or "Study plan is invalid or has the wrong schema.")
    return json.loads(raw), receipt["sha256"]


def _job_id(study_sha256: str, episode_id: str, candidate_id: str, position: int) -> str:
    material = {
        "candidateID": candidate_id,
        "episodeID": episode_id,
        "position": position,
        "studyPlanSha256": study_sha256,
    }
    return "sha256:" + sha256_bytes(canonical_json(material))


def build_execution_plan_from_study(
    study: dict[str, Any],
    study_sha256: str,
) -> dict[str, Any]:
    jobs: list[dict[str, Any]] = []
    for episode in study["episodes"]:
        for position, candidate_id in enumerate(episode["candidateOrder"]):
            jobs.append({
                "ordinal": len(jobs),
                "id": _job_id(study_sha256, episode["id"], candidate_id, position),
                "episodeID": episode["id"],
                "scenario": episode["scenario"],
                "repetition": episode["repetition"],
                "fingerprint": episode["fingerprint"],
                "candidateID": candidate_id,
                "candidatePosition": position,
                "roles": episode["roles"],
                "agentProcessCount": episode["agentProcessCount"],
                "traceSeats": episode["traceSeats"],
                "phasePolicy": episode["phasePolicy"],
            })
    plan = {
        "schema": EXECUTION_PLAN_SCHEMA,
        "benchmarkVersion": study["benchmarkVersion"],
        "taskSet": study["taskSet"],
        "developmentCases": study["developmentCases"],
        "controlProfile": study["controlProfile"],
        "studyPlanSha256": study_sha256,
        "baselineCandidate": study["baselineCandidate"],
        "candidate": study["candidate"],
        "episodeCount": study["episodeCount"],
        "jobCount": len(jobs),
        "roleProcessCount": sum(len(job["roles"]) for job in jobs),
        "agentProcessCount": sum(job["agentProcessCount"] for job in jobs),
        "failurePolicy": {
            "continueAfterIncompleteJob": False,
            "retryCreatesNewRun": True,
            "completedJobReplay": "verify-and-skip",
        },
        "jobs": jobs,
    }
    plan["id"] = submission_identifier(plan)
    receipt = validate_bytes(canonical_json(plan))
    if not receipt["valid"]:
        raise RuntimeError("Generated execution plan violated its own public contract.")
    return plan


def build_execution_plan(study_path: Path) -> dict[str, Any]:
    study, study_sha256 = _study_snapshot(study_path)
    return build_execution_plan_from_study(study, study_sha256)


def expected_job_id(
    study_sha256: str,
    episode_id: str,
    candidate_id: str,
    position: int,
) -> str:
    """Expose deterministic job identity to semantic validation and adapters."""
    return _job_id(study_sha256, episode_id, candidate_id, position)
