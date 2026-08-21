"""Model-free comparison of polling and named durable-state waiting."""

from __future__ import annotations

import hashlib
import os
import statistics
import tempfile
import threading
import time
import uuid
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .gateway import GatewayResponse, MarginGateway, ToolPolicy, binary_sha256
from .schema import Actor


PROBE_SCHEMA = "urn:marginbench:suggestion-convergence-probe:v1"
PROBE_VERSION = 1
DEFAULT_DELAYS_MS = (200, 500, 1_000)


@dataclass(frozen=True)
class SuggestionConvergenceLimits:
    repetitions_per_delay: int = 4
    delays_ms: tuple[int, ...] = DEFAULT_DELAYS_MS
    poll_interval_ms: int = 50
    timeout_seconds: int = 3

    def __post_init__(self) -> None:
        if not 2 <= self.repetitions_per_delay <= 100:
            raise ValueError("Convergence repetitions must be between 2 and 100.")
        if not self.delays_ms or len(self.delays_ms) > 8:
            raise ValueError("Convergence requires between one and eight delays.")
        if tuple(sorted(set(self.delays_ms))) != self.delays_ms:
            raise ValueError("Convergence delays must be unique and increasing.")
        if any(delay < 100 or delay > 2_000 for delay in self.delays_ms):
            raise ValueError("Convergence delays must be between 100 and 2000 ms.")
        if not 10 <= self.poll_interval_ms <= 500:
            raise ValueError("Convergence poll interval must be between 10 and 500 ms.")
        if not 1 <= self.timeout_seconds <= 10:
            raise ValueError("Convergence timeout must be between 1 and 10 seconds.")
        if max(self.delays_ms) + self.poll_interval_ms >= self.timeout_seconds * 1_000:
            raise ValueError("Convergence timeout must exceed the largest delay plus one poll.")


@dataclass(frozen=True)
class _PreparedArm:
    label: str
    workspace: Path
    observer: MarginGateway
    writer: MarginGateway
    first_id: str
    second_id: str
    source: str


@dataclass(frozen=True)
class _Measurement:
    delay_ms: int
    repetition: int
    duration_ms: float
    convergence_call_count: int
    completed: bool
    writer_succeeded: bool
    convergence_succeeded: bool
    document_valid: bool
    graph_integrity_passed: bool
    source_preserved: bool


def _p95(values: list[float]) -> float:
    ordered = sorted(values)
    return ordered[max(0, (95 * len(ordered) + 99) // 100 - 1)]


def _identifier(delay_ms: int, repetition: int, position: str) -> str:
    material = f"urn:marginbench:suggestion-convergence:{delay_ms}:{repetition}:{position}"
    return str(uuid.uuid5(uuid.NAMESPACE_URL, material))


def _annotation_id(identifier: str) -> str:
    return f"urn:uuid:{identifier}"


def _actor(delay_ms: int, repetition: int, role: str) -> Actor:
    return Actor(
        id=f"urn:marginbench:convergence:{delay_ms}:{repetition}:{role}",
        name=f"Convergence {role}",
        type="software",
    )


def _result(response: GatewayResponse) -> dict[str, Any]:
    payload = response.json
    if not response.ok or not isinstance(payload, dict) or payload.get("ok") is not True:
        raise RuntimeError(
            "Margin convergence setup or verification failed with "
            f"{response.error_code or response.exit_code}."
        )
    result = payload.get("result")
    if not isinstance(result, dict):
        raise RuntimeError("Margin convergence response omitted its result object.")
    return result


def _suggestion_arguments(identifier: str, anchor: str, position: str) -> list[str]:
    return [
        "suggest", "add", "review.md",
        "--quote", anchor,
        "--expect", anchor,
        "--replacement", f"{anchor} Proposed {position} revision.",
        "-m", f"Delayed-peer suggestion {position}.",
        "--id", identifier,
    ]


def _listed_ids(gateway: MarginGateway) -> set[str]:
    suggestions = _result(gateway.call(["suggest", "list", "review.md"])).get(
        "suggestions"
    )
    if not isinstance(suggestions, list):
        raise RuntimeError("Margin suggestion list omitted its suggestion array.")
    return {
        item["id"]
        for item in suggestions
        if isinstance(item, dict) and isinstance(item.get("id"), str)
    }


def _prepare_arm(
    label: str,
    binary: Path,
    root: Path,
    *,
    delay_ms: int,
    repetition: int,
    policy: ToolPolicy,
) -> _PreparedArm:
    workspace = root / f"delay-{delay_ms:04d}" / f"repetition-{repetition:03d}" / label
    workspace.mkdir(parents=True)
    source = (
        "# Named suggestion convergence\n\n"
        "First anchor remains literal.\n\n"
        "Second anchor remains literal.\n"
    )
    (workspace / "review.md").write_text(source, encoding="utf-8")
    first_id = _identifier(delay_ms, repetition, "first")
    second_id = _identifier(delay_ms, repetition, "second")
    observer = MarginGateway(
        binary,
        workspace,
        _actor(delay_ms, repetition, "observer"),
        "observer",
        state_home=workspace.parent / f".{label}-observer-state",
        policy=policy,
    )
    writer = MarginGateway(
        binary,
        workspace,
        _actor(delay_ms, repetition, "writer"),
        "writer",
        state_home=workspace.parent / f".{label}-writer-state",
        policy=policy,
    )
    seeded = writer.call(_suggestion_arguments(
        first_id,
        "First anchor remains literal.",
        "first",
    ))
    if not seeded.ok:
        raise RuntimeError(
            "Margin convergence seed failed with "
            f"{seeded.error_code or seeded.exit_code}."
        )
    return _PreparedArm(
        label=label,
        workspace=workspace,
        observer=observer,
        writer=writer,
        first_id=first_id,
        second_id=second_id,
        source=source,
    )


def _measure_arm(
    prepared: _PreparedArm,
    *,
    delay_ms: int,
    repetition: int,
    limits: SuggestionConvergenceLimits,
    barrier: threading.Barrier,
) -> _Measurement:
    barrier.wait()
    writer_response: list[GatewayResponse] = []

    def delayed_write() -> None:
        time.sleep(delay_ms / 1_000)
        writer_response.append(prepared.writer.call(_suggestion_arguments(
            prepared.second_id,
            "Second anchor remains literal.",
            "second",
        )))

    started = time.perf_counter()
    writer_thread = threading.Thread(target=delayed_write, daemon=True)
    writer_thread.start()
    expected = {
        _annotation_id(prepared.first_id),
        _annotation_id(prepared.second_id),
    }
    calls = 0
    convergence_succeeded = False
    deadline = started + limits.timeout_seconds
    if prepared.label == "candidate":
        response = prepared.observer.call([
            "suggest", "wait", "review.md",
            prepared.first_id, prepared.second_id,
            "--timeout", str(limits.timeout_seconds),
        ])
        calls = 1
        if response.ok:
            result = _result(response)
            convergence_succeeded = (
                result.get("complete") is True
                and result.get("matchedCount") == 2
                and result.get("missingIDs") == []
            )
    else:
        while time.perf_counter() < deadline:
            calls += 1
            response = prepared.observer.call(["suggest", "list", "review.md"])
            if not response.ok:
                break
            suggestions = _result(response).get("suggestions")
            if not isinstance(suggestions, list):
                break
            observed = {
                item["id"]
                for item in suggestions
                if isinstance(item, dict) and isinstance(item.get("id"), str)
            }
            if observed == expected:
                convergence_succeeded = True
                break
            time.sleep(limits.poll_interval_ms / 1_000)

    writer_thread.join(timeout=max(1.0, limits.timeout_seconds))
    duration_ms = (time.perf_counter() - started) * 1_000
    writer_succeeded = (
        not writer_thread.is_alive()
        and len(writer_response) == 1
        and writer_response[0].ok
    )
    validation = _result(prepared.observer.call([
        "comments", "validate", "review.md",
    ]))
    body = _result(prepared.observer.call(["read", "review.md", "--json"])).get("body")
    listed = _listed_ids(prepared.observer)
    document_valid = validation.get("valid") is True
    graph_integrity = (
        listed == expected
        and validation.get("annotationCount") == 2
    )
    source_preserved = body == prepared.source
    return _Measurement(
        delay_ms=delay_ms,
        repetition=repetition,
        duration_ms=duration_ms,
        convergence_call_count=calls,
        completed=(
            writer_succeeded
            and convergence_succeeded
            and document_valid
            and graph_integrity
            and source_preserved
        ),
        writer_succeeded=writer_succeeded,
        convergence_succeeded=convergence_succeeded,
        document_valid=document_valid,
        graph_integrity_passed=graph_integrity,
        source_preserved=source_preserved,
    )


def _numeric_summary(values: list[float]) -> dict[str, float]:
    return {
        "min": round(min(values), 6),
        "median": round(statistics.median(values), 6),
        "p95": round(_p95(values), 6),
        "max": round(max(values), 6),
    }


def _call_summary(values: list[int]) -> dict[str, Any]:
    histogram = Counter(values)
    return {
        "total": sum(values),
        **_numeric_summary([float(value) for value in values]),
        "histogram": {
            str(count): frequency for count, frequency in sorted(histogram.items())
        },
    }


def _arm_summary(
    binary: Path,
    measurements: list[_Measurement],
    delays_ms: tuple[int, ...],
) -> dict[str, Any]:
    return {
        "binarySha256": binary_sha256(binary),
        "sampleCount": len(measurements),
        "completedCount": sum(item.completed for item in measurements),
        "writerFailureCount": sum(not item.writer_succeeded for item in measurements),
        "convergenceFailureCount": sum(
            not item.convergence_succeeded for item in measurements
        ),
        "documentValid": all(item.document_valid for item in measurements),
        "graphIntegrityPassed": all(
            item.graph_integrity_passed for item in measurements
        ),
        "sourcePreserved": all(item.source_preserved for item in measurements),
        "convergenceCalls": _call_summary([
            item.convergence_call_count for item in measurements
        ]),
        "durationMs": _numeric_summary([item.duration_ms for item in measurements]),
        "byDelay": [
            {
                "delayMs": delay,
                "sampleCount": len(selected),
                "convergenceCalls": _call_summary([
                    item.convergence_call_count for item in selected
                ]),
                "durationMs": _numeric_summary([item.duration_ms for item in selected]),
            }
            for delay in delays_ms
            if (selected := [item for item in measurements if item.delay_ms == delay])
        ],
    }


def _arm_correct(summary: dict[str, Any]) -> bool:
    return (
        summary["completedCount"] == summary["sampleCount"]
        and summary["writerFailureCount"] == 0
        and summary["convergenceFailureCount"] == 0
        and summary["documentValid"]
        and summary["graphIntegrityPassed"]
        and summary["sourcePreserved"]
    )


def _delay_comparisons(
    arms: dict[str, dict[str, Any]],
    delays_ms: tuple[int, ...],
) -> list[dict[str, float | int]]:
    baseline_by_delay = {
        item["delayMs"]: item for item in arms["baseline"]["byDelay"]
    }
    candidate_by_delay = {
        item["delayMs"]: item for item in arms["candidate"]["byDelay"]
    }
    comparisons: list[dict[str, float | int]] = []
    for delay in delays_ms:
        baseline = baseline_by_delay[delay]
        candidate = candidate_by_delay[delay]
        comparisons.append({
            "delayMs": delay,
            "candidateMinusBaselineMedianCalls": round(
                candidate["convergenceCalls"]["median"]
                - baseline["convergenceCalls"]["median"],
                6,
            ),
            "candidateMinusBaselineMedianDurationMs": round(
                candidate["durationMs"]["median"]
                - baseline["durationMs"]["median"],
                6,
            ),
        })
    return comparisons


def run_suggestion_convergence_probe(
    baseline_binary: Path,
    candidate_binary: Path,
    *,
    limits: SuggestionConvergenceLimits | None = None,
) -> dict[str, Any]:
    """Compare visible polling calls with one file-local named wait."""
    limits = limits or SuggestionConvergenceLimits()
    binaries = {
        "baseline": baseline_binary.expanduser().resolve(),
        "candidate": candidate_binary.expanduser().resolve(),
    }
    for label, binary in binaries.items():
        if not binary.is_file() or not os.access(binary, os.X_OK):
            raise ValueError(f"Convergence {label} executable is unavailable: {binary}")

    policy = ToolPolicy(timeout_seconds=float(limits.timeout_seconds + 2))
    measurements: dict[str, list[_Measurement]] = {"baseline": [], "candidate": []}
    case_material: list[str] = []
    with tempfile.TemporaryDirectory(prefix="marginbench-suggestion-convergence-") as temporary:
        root = Path(temporary)
        for delay_ms in limits.delays_ms:
            for repetition in range(limits.repetitions_per_delay):
                case_material.append(f"{delay_ms}:{repetition}")
                prepared = {
                    label: _prepare_arm(
                        label,
                        binaries[label],
                        root,
                        delay_ms=delay_ms,
                        repetition=repetition,
                        policy=policy,
                    )
                    for label in (
                        ("baseline", "candidate")
                        if repetition % 2 == 0
                        else ("candidate", "baseline")
                    )
                }
                barrier = threading.Barrier(2)
                order = (
                    ("baseline", "candidate")
                    if repetition % 2 == 0
                    else ("candidate", "baseline")
                )
                with ThreadPoolExecutor(max_workers=2) as pool:
                    futures = {
                        label: pool.submit(
                            _measure_arm,
                            prepared[label],
                            delay_ms=delay_ms,
                            repetition=repetition,
                            limits=limits,
                            barrier=barrier,
                        )
                        for label in order
                    }
                    for label in ("baseline", "candidate"):
                        measurements[label].append(futures[label].result())

    arms = {
        label: _arm_summary(binaries[label], measurements[label], limits.delays_ms)
        for label in ("baseline", "candidate")
    }
    sample_count = limits.repetitions_per_delay * len(limits.delays_ms)
    baseline_calls = arms["baseline"]["convergenceCalls"]["total"]
    candidate_calls = arms["candidate"]["convergenceCalls"]["total"]
    passed = (
        _arm_correct(arms["baseline"])
        and _arm_correct(arms["candidate"])
        and arms["candidate"]["convergenceCalls"]["histogram"] == {"1": sample_count}
        and all(
            item["convergenceCalls"]["min"] >= 2
            for item in arms["baseline"]["byDelay"]
        )
        and baseline_calls > candidate_calls
    )
    return {
        "schema": PROBE_SCHEMA,
        "version": PROBE_VERSION,
        "paidModelsInvoked": False,
        "passed": passed,
        "fixture": {
            "caseSetSha256": hashlib.sha256(
                "\n".join(case_material).encode("ascii")
            ).hexdigest(),
            "sampleCountPerArm": sample_count,
            "firstRepetition": 0,
        },
        "method": {
            "repetitionsPerDelay": limits.repetitions_per_delay,
            "delaysMs": list(limits.delays_ms),
            "pollIntervalMs": limits.poll_interval_ms,
            "waitTimeoutSeconds": limits.timeout_seconds,
            "knownSuggestionIDCount": 2,
            "pairedConcurrentStart": True,
            "counterbalancedSubmissionOrder": True,
            "verificationCallsExcluded": True,
        },
        "arms": arms,
        "comparison": {
            "candidateMinusBaselineConvergenceCalls": candidate_calls - baseline_calls,
            "candidateToBaselineConvergenceCallRatio": round(
                candidate_calls / baseline_calls, 6
            ),
            "byDelay": _delay_comparisons(arms, limits.delays_ms),
        },
    }
