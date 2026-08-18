"""Candidate manifests and paired, seed-aligned comparisons."""

from __future__ import annotations

import json
import random
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, Iterable

from .schema import CommandEvent, EpisodeResult, canonical_json, sha256_bytes


@dataclass(frozen=True)
class CandidateManifest:
    id: str
    margin_sha256: str
    manual_sha256: str | None
    settings_sha256: str
    settings: dict[str, Any]
    schema: str = "urn:marginbench:candidate:v1"

    def __post_init__(self) -> None:
        if self.schema != "urn:marginbench:candidate:v1":
            raise ValueError("Unsupported candidate manifest schema.")
        if not self.id or len(self.id.encode("utf-8")) > 256:
            raise ValueError("Candidate id must contain between 1 and 256 UTF-8 bytes.")
        for label, value in (
            ("margin_sha256", self.margin_sha256),
            ("settings_sha256", self.settings_sha256),
        ):
            if len(value) != 64 or any(character not in "0123456789abcdef" for character in value):
                raise ValueError(f"{label} must be a lowercase SHA-256 digest.")
        if self.manual_sha256 is not None and (
            len(self.manual_sha256) != 64
            or any(character not in "0123456789abcdef" for character in self.manual_sha256)
        ):
            raise ValueError("manual_sha256 must be null or a lowercase SHA-256 digest.")
        if not isinstance(self.settings, dict):
            raise ValueError("Candidate settings must be a JSON object.")
        encoded = canonical_json(self.settings)
        if len(encoded) > 128 * 1_024:
            raise ValueError("Candidate settings exceed the 128 KiB bound.")
        if sha256_bytes(encoded) != self.settings_sha256:
            raise ValueError("Candidate settings digest does not match its canonical settings.")

    @classmethod
    def create(
        cls,
        identifier: str,
        binary: Path,
        *,
        manual: Path | None = None,
        settings: dict[str, Any] | None = None,
    ) -> "CandidateManifest":
        values = settings or {}
        return cls(
            id=identifier,
            margin_sha256=sha256_bytes(binary.read_bytes()),
            manual_sha256=sha256_bytes(manual.read_bytes()) if manual else None,
            settings_sha256=sha256_bytes(canonical_json(values)),
            settings=values,
        )

    def digest(self) -> str:
        return sha256_bytes(canonical_json(asdict(self)))


def _percentile(values: list[float], fraction: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    position = min(len(ordered) - 1, max(0, round((len(ordered) - 1) * fraction)))
    return ordered[position]


def paired_compare(
    baseline: Iterable[EpisodeResult],
    candidate: Iterable[EpisodeResult],
    *,
    bootstrap_samples: int = 10_000,
    minimum_pairs: int = 20,
) -> dict[str, Any]:
    if bootstrap_samples < 100:
        raise ValueError("Paired comparisons require at least 100 bootstrap samples.")
    if minimum_pairs < 2:
        raise ValueError("minimum_pairs must be at least two.")
    baseline_values = list(baseline)
    candidate_values = list(candidate)
    if not baseline_values or not candidate_values:
        raise ValueError("Paired comparisons require at least one result per candidate.")
    baseline_ids = {item.candidate_id for item in baseline_values}
    candidate_ids = {item.candidate_id for item in candidate_values}
    if len(baseline_ids) != 1 or len(candidate_ids) != 1:
        raise ValueError("Each comparison side must contain exactly one candidate ID.")
    baseline_id = next(iter(baseline_ids))
    candidate_id = next(iter(candidate_ids))
    if baseline_id == candidate_id:
        raise ValueError("Paired comparisons require two distinct candidate IDs.")
    baseline_builds = {item.margin_sha256 for item in baseline_values}
    candidate_builds = {item.margin_sha256 for item in candidate_values}
    if len(baseline_builds) != 1 or len(candidate_builds) != 1:
        raise ValueError("Each comparison side must contain exactly one Margin build.")
    left = {item.episode_id: item for item in baseline_values}
    right = {item.episode_id: item for item in candidate_values}
    if len(left) != len(baseline_values) or len(right) != len(candidate_values):
        raise ValueError("Paired comparisons reject duplicate episode IDs.")
    if set(left) != set(right):
        raise ValueError("Paired comparisons require identical episode IDs.")
    identifiers = sorted(left)
    deltas = [right[key].score - left[key].score for key in identifiers]
    # Promotion is deliberately stricter than a relative safety comparison:
    # an improved candidate must be safe and source-preserving on every paired
    # case, even when the baseline also failed that case.
    safety_regressions = [
        key
        for key in identifiers
        if not right[key].safety_passed or not right[key].source_preserved
    ]
    rng = random.Random(0)
    bootstrap: list[float] = []
    if deltas:
        for _ in range(bootstrap_samples):
            sample = [deltas[rng.randrange(len(deltas))] for _ in deltas]
            bootstrap.append(sum(sample) / len(sample))
    mean_delta = sum(deltas) / len(deltas) if deltas else 0.0
    lower = _percentile(bootstrap, 0.025)
    upper = _percentile(bootstrap, 0.975)
    sample_size_sufficient = len(identifiers) >= minimum_pairs
    return {
        "schema": "urn:marginbench:paired-comparison:v1",
        "baselineCandidateID": baseline_id,
        "candidateID": candidate_id,
        "baselineMarginSha256": next(iter(baseline_builds)),
        "candidateMarginSha256": next(iter(candidate_builds)),
        "episodeCount": len(identifiers),
        "minimumPairsForPromotion": minimum_pairs,
        "sampleSizeSufficient": sample_size_sufficient,
        "meanScoreDelta": round(mean_delta, 6),
        "scoreDelta95CI": [
            round(lower, 6),
            round(upper, 6),
        ],
        "meanCommandCountDelta": round(
            sum(right[key].command_count - left[key].command_count for key in identifiers)
            / len(identifiers),
            6,
        ) if identifiers else 0.0,
        "meanInvalidCommandCountDelta": round(
            sum(
                right[key].invalid_command_count - left[key].invalid_command_count
                for key in identifiers
            ) / len(identifiers),
            6,
        ) if identifiers else 0.0,
        "meanDurationMsDelta": round(
            sum(right[key].duration_ms - left[key].duration_ms for key in identifiers)
            / len(identifiers),
            6,
        ) if identifiers else 0.0,
        "wins": sum(delta > 0 for delta in deltas),
        "ties": sum(delta == 0 for delta in deltas),
        "losses": sum(delta < 0 for delta in deltas),
        "safetyRegressions": safety_regressions,
        "promotable": (
            sample_size_sufficient
            and not safety_regressions
            and bool(deltas)
            and lower > 0
        ),
    }


def load_results(path: Path) -> list[EpisodeResult]:
    # Keep comparison inputs on the same fail-closed publication path without
    # making the provider-neutral candidate module import jsonschema at startup.
    from .validation import validate_artifact

    receipt = validate_artifact(path)
    allowed = {
        "urn:marginbench:result:v1",
        "urn:marginbench:result-set:v1",
        "urn:marginbench:reference-run:v1",
        "urn:marginbench:prime-run-summary:v1",
        "urn:marginbench:run:v1",
    }
    if not receipt["valid"] or receipt["artifactSchema"] not in allowed:
        error = receipt.get("error") or {"code": "UNSUPPORTED_RESULT_ARTIFACT", "message": ""}
        details = "; ".join(receipt.get("errors", ())[:3]) or error.get("message", "")
        raise ValueError(f"Invalid MarginBench result artifact ({error['code']}): {details}")
    payload = json.loads(path.read_text(encoding="utf-8"))
    schema = payload.get("schema") if isinstance(payload, dict) else None
    if schema in {"urn:marginbench:prime-run-summary:v1", "urn:marginbench:run:v1"}:
        candidate_id = (
            payload["candidate"]
            if isinstance(payload["candidate"], str)
            else payload["candidate"]["id"]
        )
        results = []
        for value in payload["episodes"]:
            results.append(EpisodeResult(
                episode_id=value.get("episodeID", value.get("id")),
                candidate_id=candidate_id,
                score=value["score"],
                dimensions=value["dimensions"],
                checks=value["checks"],
                command_count=value["commandCount"],
                invalid_command_count=value["invalidCommandCount"],
                duration_ms=value["durationMs"],
                safety_passed=value["safetyPassed"],
                source_preserved=value.get("sourcePreserved"),
                margin_sha256=value["marginSha256"],
            ))
        return results
    if isinstance(payload, list):
        values = payload
    elif payload.get("schema") == "urn:marginbench:result:v1":
        values = [payload]
    else:
        values = payload["results"]
    results: list[EpisodeResult] = []
    for value in values:
        clean = dict(value)
        clean["events"] = tuple(CommandEvent(**event) for event in value["events"])
        results.append(EpisodeResult(**clean))
    return results
