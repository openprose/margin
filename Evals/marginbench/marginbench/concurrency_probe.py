"""Model-free measurement of agent-visible contention during concurrent review."""

from __future__ import annotations

import hashlib
import os
import statistics
import tempfile
import threading
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .entropy import PUBLIC_DEVELOPMENT_KEY
from .gateway import ToolPolicy, binary_sha256
from .controls import DEFAULT_CONTROL_PROFILE
from .runner import ReferenceDriver, run_episode
from .scenarios import generate_episode
from .schema import EpisodeResult


PROBE_SCHEMA = "urn:marginbench:concurrency-probe:v1"
PROBE_VERSION = 1
_VISIBLE_CONFLICTS = {"COLLABORATION_PRECONDITION_FAILED", "REVISION_CONFLICT"}


@dataclass(frozen=True)
class ConcurrencyProbeLimits:
    repetitions: int = 100

    def __post_init__(self) -> None:
        if not 4 <= self.repetitions <= 1_000:
            raise ValueError("Concurrency probe repetitions must be between 4 and 1,000.")


def _p95(values: list[float]) -> float:
    ordered = sorted(values)
    return ordered[max(0, (95 * len(ordered) + 99) // 100 - 1)]


def _arm_summary(binary: Path, results: list[EpisodeResult]) -> dict[str, Any]:
    command_histogram = Counter(result.command_count for result in results)
    conflict_counts = [
        sum(event.error_code in _VISIBLE_CONFLICTS for event in result.events)
        for result in results
    ]
    scores = [result.score for result in results]
    durations = [result.duration_ms for result in results]
    return {
        "binarySha256": binary_sha256(binary),
        "episodeCount": len(results),
        "minimumScore": min(scores),
        "meanScore": round(statistics.fmean(scores), 6),
        "safetyPassed": all(result.safety_passed for result in results),
        "sourcePreserved": all(result.source_preserved for result in results),
        "invalidCommandCount": sum(result.invalid_command_count for result in results),
        "commandCount": sum(result.command_count for result in results),
        "commandCountHistogram": {
            str(count): frequency for count, frequency in sorted(command_histogram.items())
        },
        "visibleConflictCount": sum(conflict_counts),
        "visibleConflictEpisodeCount": sum(count > 0 for count in conflict_counts),
        "durationMs": {
            "median": round(statistics.median(durations), 6),
            "p95": round(_p95(durations), 6),
        },
    }


def _arm_correct(summary: dict[str, Any]) -> bool:
    return (
        summary["minimumScore"] == 100
        and summary["safetyPassed"]
        and summary["sourcePreserved"]
        and summary["invalidCommandCount"] == 0
    )


def _candidate_passed(summary: dict[str, Any]) -> bool:
    return (
        _arm_correct(summary)
        and summary["visibleConflictCount"] == 0
        and summary["commandCountHistogram"] == {"4": summary["episodeCount"]}
    )


def run_concurrency_probe(
    baseline_binary: Path,
    candidate_binary: Path,
    *,
    limits: ConcurrencyProbeLimits | None = None,
) -> dict[str, Any]:
    """Run paired two-writer episodes without models or scheduler-dependent assertions."""
    limits = limits or ConcurrencyProbeLimits()
    binaries = {
        "baseline": baseline_binary.expanduser().resolve(),
        "candidate": candidate_binary.expanduser().resolve(),
    }
    for label, binary in binaries.items():
        if not binary.is_file() or not os.access(binary, os.X_OK):
            raise ValueError(f"Concurrency {label} executable is unavailable: {binary}")

    results: dict[str, list[EpisodeResult]] = {"baseline": [], "candidate": []}
    fingerprints: list[str] = []
    policy = ToolPolicy()
    with tempfile.TemporaryDirectory(prefix="marginbench-concurrency-probe-") as temporary:
        root = Path(temporary)
        for repetition in range(limits.repetitions):
            episode = generate_episode("concurrent_review", PUBLIC_DEVELOPMENT_KEY, repetition)
            fingerprints.append(episode.fingerprint)
            barrier = threading.Barrier(2)

            def execute(label: str) -> EpisodeResult:
                barrier.wait()
                return run_episode(
                    episode,
                    binaries[label],
                    root / f"episode-{repetition:04d}" / label / "workspace",
                    ReferenceDriver(),
                    candidate_id=label,
                    policy=policy,
                )

            order = ("baseline", "candidate") if repetition % 2 == 0 else ("candidate", "baseline")
            with ThreadPoolExecutor(max_workers=2) as pool:
                futures = {label: pool.submit(execute, label) for label in order}
                for label in ("baseline", "candidate"):
                    results[label].append(futures[label].result())

    arms = {
        label: _arm_summary(binaries[label], results[label])
        for label in ("baseline", "candidate")
    }
    probe_passed = _arm_correct(arms["baseline"]) and _candidate_passed(arms["candidate"])
    case_set_sha256 = hashlib.sha256("\n".join(fingerprints).encode("ascii")).hexdigest()
    return {
        "schema": PROBE_SCHEMA,
        "version": PROBE_VERSION,
        "paidModelsInvoked": False,
        "passed": probe_passed,
        "fixture": {
            "caseSetSha256": case_set_sha256,
            "caseCount": len(fingerprints),
            "firstRepetition": 0,
        },
        "method": {
            "scenario": "concurrent_review",
            "controlProfile": DEFAULT_CONTROL_PROFILE,
            "repetitionsPerArm": limits.repetitions,
            "rolesPerEpisode": 2,
            "expectedAgentVisibleCallsPerEpisode": 4,
            "gatewayTimeoutSeconds": policy.timeout_seconds,
            "pairedSimultaneousStart": True,
            "counterbalancedSubmissionOrder": True,
            "baselineCollisionRequired": False,
        },
        "arms": arms,
        "comparison": {
            "candidateMinusBaselineVisibleConflicts": (
                arms["candidate"]["visibleConflictCount"]
                - arms["baseline"]["visibleConflictCount"]
            ),
            "candidateMinusBaselineCommandCount": (
                arms["candidate"]["commandCount"] - arms["baseline"]["commandCount"]
            ),
        },
    }
