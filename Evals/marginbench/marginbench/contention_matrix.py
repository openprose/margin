"""Operation-aware, model-free contention measurements for Margin collaboration."""

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


MATRIX_SCHEMA = "urn:marginbench:contention-matrix:v1"
MATRIX_VERSION = 1
VISIBLE_CONFLICTS = frozenset({
    "COLLABORATION_PRECONDITION_FAILED",
    "CONCURRENT_MODIFICATION",
    "REVISION_CONFLICT",
})
FAMILIES = (
    "typed-add",
    "suggestion-add",
    "suggestion-reject",
    "suggestion-accept",
    "handoff-add",
)


@dataclass(frozen=True)
class ContentionMatrixLimits:
    repetitions: int = 8
    group_sizes: tuple[int, ...] = (2, 4, 8, 16)
    recovery_rounds: int = 4
    timeout_seconds: float = 30.0

    def __post_init__(self) -> None:
        if not 1 <= self.repetitions <= 100:
            raise ValueError("Contention repetitions must be between 1 and 100.")
        if not self.group_sizes or len(self.group_sizes) > 8:
            raise ValueError("Contention requires between one and eight group sizes.")
        if tuple(sorted(set(self.group_sizes))) != self.group_sizes:
            raise ValueError("Contention group sizes must be unique and increasing.")
        if any(size < 2 or size > 32 for size in self.group_sizes):
            raise ValueError("Contention group sizes must be between 2 and 32.")
        if not 0 <= self.recovery_rounds <= 8:
            raise ValueError("Contention recovery rounds must be between 0 and 8.")
        if not 1 <= self.timeout_seconds <= 120:
            raise ValueError("Contention timeout must be between 1 and 120 seconds.")


@dataclass(frozen=True)
class _WriterPlan:
    index: int
    identifier: str
    gateway: MarginGateway
    arguments: list[str]
    anchor: str | None = None
    replacement: str | None = None


@dataclass(frozen=True)
class _MutationRun:
    final_successes: frozenset[int]
    initial_success_count: int
    visible_conflict_count: int
    other_failure_count: int
    error_counts: dict[str, int]
    mutation_call_count: int
    recovery_read_count: int
    retry_call_count: int


@dataclass(frozen=True)
class _EpisodeMeasurement:
    family: str
    group_size: int
    duration_ms: float
    initial_success_count: int
    final_success_count: int
    visible_conflict_count: int
    other_failure_count: int
    mutation_call_count: int
    recovery_read_count: int
    retry_call_count: int
    source_check_passed: bool
    document_valid: bool
    graph_integrity_passed: bool
    completion_passed: bool
    error_counts: dict[str, int]


def _document(maximum_writers: int) -> str:
    lines = ["# MarginBench contention matrix", ""]
    for index in range(maximum_writers):
        lines.extend([
            f"Anchor {index:02d} retains original value {index:02d}.",
            "",
        ])
    return "\n".join(lines)


def _identifier(family: str, repetition: int, writer: int, purpose: str) -> str:
    material = f"urn:marginbench:contention:{family}:{repetition}:{writer}:{purpose}"
    return str(uuid.uuid5(uuid.NAMESPACE_URL, material))


def _annotation_id(identifier: str) -> str:
    return f"urn:uuid:{identifier}"


def _actor(family: str, repetition: int, writer: int) -> Actor:
    return Actor(
        id=f"urn:marginbench:contention:{family}:{repetition}:{writer}",
        name=f"Contention writer {writer:02d}",
        type="software",
    )


def _gateway(
    binary: Path,
    workspace: Path,
    family: str,
    repetition: int,
    writer: int,
    policy: ToolPolicy,
) -> MarginGateway:
    return MarginGateway(
        binary,
        workspace,
        _actor(family, repetition, writer),
        f"writer-{writer:02d}",
        state_home=workspace.parent / ".state",
        policy=policy,
    )


def _result(response: GatewayResponse) -> dict[str, Any]:
    payload = response.json
    if not response.ok or not isinstance(payload, dict) or payload.get("ok") is not True:
        raise RuntimeError(
            "Margin contention verification failed with "
            f"{response.error_code or response.exit_code}."
        )
    result = payload.get("result")
    if not isinstance(result, dict):
        raise RuntimeError("Margin contention verification omitted its result object.")
    return result


def _safe_error(response: GatewayResponse) -> str:
    value = response.error_code
    if isinstance(value, str) and value in VISIBLE_CONFLICTS:
        return value
    return "OTHER_ERROR"


def _simultaneous(plans: list[_WriterPlan]) -> list[GatewayResponse]:
    if not plans:
        return []
    barrier = threading.Barrier(len(plans))

    def execute(plan: _WriterPlan) -> GatewayResponse:
        barrier.wait()
        return plan.gateway.call(plan.arguments)

    with ThreadPoolExecutor(max_workers=len(plans)) as pool:
        futures = [pool.submit(execute, plan) for plan in plans]
        return [future.result() for future in futures]


def _recovery_read(plan: _WriterPlan, family: str) -> GatewayResponse:
    if family == "typed-add":
        arguments = ["comments", "list", "review.md", "--status", "all"]
    elif family == "suggestion-add":
        arguments = ["read", "review.md", "--json"]
    elif family == "suggestion-reject":
        arguments = ["suggest", "list", "review.md"]
    else:  # pragma: no cover - guarded by family metadata
        raise ValueError(f"Family {family} does not permit scripted recovery.")
    return plan.gateway.call(arguments)


def _run_mutations(
    plans: list[_WriterPlan],
    *,
    family: str,
    recovery_rounds: int,
) -> _MutationRun:
    responses = _simultaneous(plans)
    initial_successes = {
        plan.index for plan, response in zip(plans, responses, strict=True) if response.ok
    }
    final_successes = set(initial_successes)
    pending: list[_WriterPlan] = []
    visible_conflicts = 0
    other_failures = 0
    errors: Counter[str] = Counter()
    mutation_calls = len(plans)
    recovery_reads = 0
    retry_calls = 0

    for plan, response in zip(plans, responses, strict=True):
        if response.ok:
            continue
        code = _safe_error(response)
        errors[code] += 1
        if response.error_code in VISIBLE_CONFLICTS:
            visible_conflicts += 1
            pending.append(plan)
        else:
            other_failures += 1

    for _ in range(recovery_rounds):
        if not pending:
            break
        readable: list[_WriterPlan] = []
        for plan in pending:
            observed = _recovery_read(plan, family)
            recovery_reads += 1
            if observed.ok:
                readable.append(plan)
            else:
                other_failures += 1
                errors[_safe_error(observed)] += 1
        pending = []
        retry_responses = _simultaneous(readable)
        mutation_calls += len(readable)
        retry_calls += len(readable)
        for plan, response in zip(readable, retry_responses, strict=True):
            if response.ok:
                final_successes.add(plan.index)
                continue
            code = _safe_error(response)
            errors[code] += 1
            if response.error_code in VISIBLE_CONFLICTS:
                visible_conflicts += 1
                pending.append(plan)
            else:
                other_failures += 1

    return _MutationRun(
        final_successes=frozenset(final_successes),
        initial_success_count=len(initial_successes),
        visible_conflict_count=visible_conflicts,
        other_failure_count=other_failures,
        error_counts=dict(sorted(errors.items())),
        mutation_call_count=mutation_calls,
        recovery_read_count=recovery_reads,
        retry_call_count=retry_calls,
    )


def _read_body(gateway: MarginGateway) -> str:
    body = _result(gateway.call(["read", "review.md", "--json"])).get("body")
    if not isinstance(body, str):
        raise RuntimeError("Margin read omitted the logical Markdown body.")
    return body


def _validation(gateway: MarginGateway) -> dict[str, Any]:
    return _result(gateway.call(["comments", "validate", "review.md"]))


def _listed_comment_ids(gateway: MarginGateway) -> set[str]:
    result = _result(gateway.call([
        "comments", "list", "review.md", "--status", "all",
    ]))
    comments = result.get("comments")
    if not isinstance(comments, list):
        raise RuntimeError("Margin comments list omitted its comment array.")
    identifiers: set[str] = set()
    for item in comments:
        if not isinstance(item, dict):
            continue
        annotation = item.get("annotation")
        identifier = annotation.get("id") if isinstance(annotation, dict) else item.get("id")
        if isinstance(identifier, str):
            identifiers.add(identifier)
    return identifiers


def _listed_suggestions(gateway: MarginGateway) -> dict[str, dict[str, Any]]:
    suggestions = _result(gateway.call(["suggest", "list", "review.md"])).get(
        "suggestions"
    )
    if not isinstance(suggestions, list):
        raise RuntimeError("Margin suggestion list omitted its suggestion array.")
    return {
        item["id"]: item
        for item in suggestions
        if isinstance(item, dict) and isinstance(item.get("id"), str)
    }


def _listed_handoffs(gateway: MarginGateway) -> dict[str, dict[str, Any]]:
    handoffs = _result(gateway.call(["handoff", "list", "review.md"])).get("handoffs")
    if not isinstance(handoffs, list):
        raise RuntimeError("Margin handoff list omitted its handoff array.")
    return {
        item["id"]: item
        for item in handoffs
        if isinstance(item, dict) and isinstance(item.get("id"), str)
    }


def _suggestion_plans(
    binary: Path,
    workspace: Path,
    family: str,
    repetition: int,
    group_size: int,
    policy: ToolPolicy,
) -> list[_WriterPlan]:
    plans: list[_WriterPlan] = []
    for writer in range(group_size):
        identifier = _identifier(family, repetition, writer, "contribution")
        request_id = _identifier(family, repetition, writer, "request")
        anchor = f"Anchor {writer:02d} retains original value {writer:02d}."
        replacement = f"Anchor {writer:02d} records accepted value {writer:02d}."
        plans.append(_WriterPlan(
            index=writer,
            identifier=identifier,
            gateway=_gateway(binary, workspace, family, repetition, writer, policy),
            arguments=[
                "suggest", "add", "review.md", "--quote", anchor,
                "--expect", anchor, "--replacement", replacement,
                "-m", f"Suggestion {writer:02d} is independently reviewable.",
                "--id", identifier, "--request-id", request_id,
            ],
            anchor=anchor,
            replacement=replacement,
        ))
    return plans


def _prepare_suggestions(plans: list[_WriterPlan]) -> None:
    for plan in plans:
        response = plan.gateway.call(plan.arguments)
        if not response.ok:
            raise RuntimeError(
                "Contention suggestion setup failed with "
                f"{response.error_code or response.exit_code}."
            )


def _plans_for_family(
    binary: Path,
    workspace: Path,
    family: str,
    repetition: int,
    group_size: int,
    policy: ToolPolicy,
) -> list[_WriterPlan]:
    if family == "typed-add":
        return [
            _WriterPlan(
                index=writer,
                identifier=(identifier := _identifier(
                    family, repetition, writer, "contribution"
                )),
                gateway=_gateway(binary, workspace, family, repetition, writer, policy),
                arguments=[
                    "comments", "add", "review.md", "--document", "--kind", "issue",
                    "-m", f"Independent typed issue {writer:02d}.", "--id", identifier,
                ],
            )
            for writer in range(group_size)
        ]
    if family == "suggestion-add":
        return _suggestion_plans(
            binary, workspace, family, repetition, group_size, policy
        )
    if family in {"suggestion-reject", "suggestion-accept"}:
        setup_plans = _suggestion_plans(
            binary, workspace, family, repetition, group_size, policy
        )
        _prepare_suggestions(setup_plans)
        disposition = "reject" if family == "suggestion-reject" else "accept"
        return [
            _WriterPlan(
                index=plan.index,
                identifier=plan.identifier,
                gateway=plan.gateway,
                arguments=[
                    "suggest", disposition, "review.md", plan.identifier,
                    "--request-id", _identifier(
                        family, repetition, plan.index, "disposition-request"
                    ),
                ],
                anchor=plan.anchor,
                replacement=plan.replacement,
            )
            for plan in setup_plans
        ]
    if family == "handoff-add":
        return [
            _WriterPlan(
                index=writer,
                identifier=(identifier := _identifier(
                    family, repetition, writer, "contribution"
                )),
                gateway=_gateway(binary, workspace, family, repetition, writer, policy),
                arguments=[
                    "handoff", "add", "review.md", "-m",
                    f"Handoff {writer:02d} records independently verified state.",
                    "--to", f"urn:marginbench:next:{writer:02d}",
                    "--id", identifier,
                    "--request-id", _identifier(family, repetition, writer, "request"),
                ],
            )
            for writer in range(group_size)
        ]
    raise ValueError(f"Unsupported contention family: {family}")


def _verify_episode(
    family: str,
    plans: list[_WriterPlan],
    mutation: _MutationRun,
    original_body: str,
) -> tuple[bool, bool, bool, bool]:
    gateway = plans[0].gateway
    validation = _validation(gateway)
    document_valid = validation.get("valid") is True
    body = _read_body(gateway)
    expected_ids = {
        _annotation_id(plan.identifier) for plan in plans
    }
    successful_ids = {
        _annotation_id(plan.identifier)
        for plan in plans
        if plan.index in mutation.final_successes
    }

    if family == "typed-add":
        source_check = body == original_body
        graph_integrity = (
            _listed_comment_ids(gateway) == successful_ids
            and validation.get("annotationCount") == len(successful_ids)
        )
        completion = mutation.final_successes == frozenset(range(len(plans)))
    elif family == "suggestion-add":
        listed = _listed_suggestions(gateway)
        source_check = body == original_body
        graph_integrity = (
            set(listed) == successful_ids
            and all(item.get("status") == "proposed" for item in listed.values())
            and validation.get("annotationCount") == len(successful_ids)
        )
        completion = mutation.final_successes == frozenset(range(len(plans)))
    elif family == "suggestion-reject":
        listed = _listed_suggestions(gateway)
        source_check = body == original_body
        graph_integrity = (
            set(listed) == expected_ids
            and all(
                item.get("status")
                == ("rejected" if identifier in successful_ids else "proposed")
                for identifier, item in listed.items()
            )
            and validation.get("annotationCount") == len(plans)
        )
        completion = mutation.final_successes == frozenset(range(len(plans)))
    elif family == "suggestion-accept":
        listed = _listed_suggestions(gateway)
        accepted = {
            identifier
            for identifier, item in listed.items()
            if item.get("status") == "accepted"
        }
        possible_bodies = {
            original_body.replace(plan.anchor or "", plan.replacement or "", 1)
            for plan in plans
            if plan.index in mutation.final_successes
        }
        source_check = len(possible_bodies) == 1 and body in possible_bodies
        graph_integrity = (
            accepted == successful_ids
            and set(listed) == expected_ids
            and all(
                item.get("status")
                == ("accepted" if identifier in successful_ids else "proposed")
                for identifier, item in listed.items()
            )
            and validation.get("annotationCount") == len(plans)
        )
        completion = len(mutation.final_successes) == 1
    elif family == "handoff-add":
        listed = _listed_handoffs(gateway)
        source_check = body == original_body
        graph_integrity = (
            set(listed) == successful_ids
            and validation.get("annotationCount") == len(successful_ids)
        )
        completion = bool(mutation.final_successes)
    else:  # pragma: no cover - guarded by the fixed catalog
        raise ValueError(f"Unsupported contention family: {family}")
    return source_check, document_valid, graph_integrity, completion


def _run_episode(
    binary: Path,
    root: Path,
    *,
    family: str,
    repetition: int,
    group_size: int,
    limits: ContentionMatrixLimits,
) -> _EpisodeMeasurement:
    workspace = root / f"{family}-{group_size:02d}-{repetition:04d}"
    workspace.mkdir(parents=True)
    original_body = _document(max(limits.group_sizes))
    (workspace / "review.md").write_text(original_body, encoding="utf-8", newline="")
    policy = ToolPolicy(timeout_seconds=limits.timeout_seconds)
    plans = _plans_for_family(
        binary, workspace, family, repetition, group_size, policy
    )
    recovery_rounds = (
        limits.recovery_rounds
        if family in {"typed-add", "suggestion-add", "suggestion-reject"}
        else 0
    )
    started = time.perf_counter_ns()
    mutation = _run_mutations(
        plans,
        family=family,
        recovery_rounds=recovery_rounds,
    )
    source_check, document_valid, graph_integrity, completion = _verify_episode(
        family, plans, mutation, original_body
    )
    duration_ms = (time.perf_counter_ns() - started) / 1_000_000
    return _EpisodeMeasurement(
        family=family,
        group_size=group_size,
        duration_ms=duration_ms,
        initial_success_count=mutation.initial_success_count,
        final_success_count=len(mutation.final_successes),
        visible_conflict_count=mutation.visible_conflict_count,
        other_failure_count=mutation.other_failure_count,
        mutation_call_count=mutation.mutation_call_count,
        recovery_read_count=mutation.recovery_read_count,
        retry_call_count=mutation.retry_call_count,
        source_check_passed=source_check,
        document_valid=document_valid,
        graph_integrity_passed=graph_integrity,
        completion_passed=completion,
        error_counts=mutation.error_counts,
    )


def _p95(values: list[float]) -> float:
    ordered = sorted(values)
    return ordered[max(0, (95 * len(ordered) + 99) // 100 - 1)]


def _histogram(values: list[int]) -> dict[str, int]:
    return {
        str(value): count
        for value, count in sorted(Counter(values).items())
    }


def _case_summary(
    family: str,
    group_size: int,
    measurements: list[_EpisodeMeasurement],
) -> dict[str, Any]:
    errors: Counter[str] = Counter()
    for measurement in measurements:
        errors.update(measurement.error_counts)
    durations = [measurement.duration_ms for measurement in measurements]
    return {
        "family": family,
        "groupSize": group_size,
        "repetitionCount": len(measurements),
        "writerIntentCount": group_size * len(measurements),
        "initialSuccessCount": sum(item.initial_success_count for item in measurements),
        "finalSuccessCount": sum(item.final_success_count for item in measurements),
        "visibleConflictCount": sum(item.visible_conflict_count for item in measurements),
        "visibleConflictEpisodeCount": sum(
            item.visible_conflict_count > 0 for item in measurements
        ),
        "otherFailureCount": sum(item.other_failure_count for item in measurements),
        "mutationCallCount": sum(item.mutation_call_count for item in measurements),
        "recoveryReadCount": sum(item.recovery_read_count for item in measurements),
        "retryCallCount": sum(item.retry_call_count for item in measurements),
        "agentVisibleCallCount": sum(
            item.mutation_call_count + item.recovery_read_count
            for item in measurements
        ),
        "initialSuccessHistogram": _histogram([
            item.initial_success_count for item in measurements
        ]),
        "finalSuccessHistogram": _histogram([
            item.final_success_count for item in measurements
        ]),
        "errorCounts": dict(sorted(errors.items())),
        "durationMs": {
            "median": round(statistics.median(durations), 3),
            "p95": round(_p95(durations), 3),
        },
        "checks": {
            "documentsValid": all(item.document_valid for item in measurements),
            "sourcePolicyPassed": all(
                item.source_check_passed for item in measurements
            ),
            "graphIntegrityPassed": all(
                item.graph_integrity_passed for item in measurements
            ),
            "completionPassed": all(
                item.completion_passed for item in measurements
            ),
            "noUnexpectedFailures": all(
                item.other_failure_count == 0 for item in measurements
            ),
        },
    }


def _arm_summary(
    binary: Path,
    measurements: list[_EpisodeMeasurement],
    limits: ContentionMatrixLimits,
) -> dict[str, Any]:
    cases = [
        _case_summary(
            family,
            group_size,
            [
                item
                for item in measurements
                if item.family == family and item.group_size == group_size
            ],
        )
        for family in FAMILIES
        for group_size in limits.group_sizes
    ]
    safety_passed = all(
        all(
            case["checks"][name]
            for name in (
                "documentsValid",
                "sourcePolicyPassed",
                "graphIntegrityPassed",
                "noUnexpectedFailures",
            )
        )
        for case in cases
    )
    completion_passed = all(
        case["checks"]["completionPassed"] for case in cases
    )
    return {
        "binarySha256": binary_sha256(binary),
        "episodeCount": len(measurements),
        "safetyPassed": safety_passed,
        "completionPassed": completion_passed,
        "passed": safety_passed and completion_passed,
        "cases": cases,
    }


def _comparison(
    baseline: dict[str, Any],
    candidate: dict[str, Any],
) -> list[dict[str, Any]]:
    baseline_cases = {
        (item["family"], item["groupSize"]): item for item in baseline["cases"]
    }
    rows = []
    for candidate_case in candidate["cases"]:
        key = (candidate_case["family"], candidate_case["groupSize"])
        baseline_case = baseline_cases[key]
        rows.append({
            "family": key[0],
            "groupSize": key[1],
            "candidateMinusBaselineFinalSuccesses": (
                candidate_case["finalSuccessCount"]
                - baseline_case["finalSuccessCount"]
            ),
            "candidateMinusBaselineVisibleConflicts": (
                candidate_case["visibleConflictCount"]
                - baseline_case["visibleConflictCount"]
            ),
            "candidateMinusBaselineMutationCalls": (
                candidate_case["mutationCallCount"]
                - baseline_case["mutationCallCount"]
            ),
            "candidateMinusBaselineRecoveryReads": (
                candidate_case["recoveryReadCount"]
                - baseline_case["recoveryReadCount"]
            ),
            "candidateMinusBaselineAgentVisibleCalls": (
                candidate_case["agentVisibleCallCount"]
                - baseline_case["agentVisibleCallCount"]
            ),
            "candidateMinusBaselineMedianDurationMs": round(
                candidate_case["durationMs"]["median"]
                - baseline_case["durationMs"]["median"],
                3,
            ),
            "candidateMinusBaselineP95DurationMs": round(
                candidate_case["durationMs"]["p95"]
                - baseline_case["durationMs"]["p95"],
                3,
            ),
        })
    return rows


def run_contention_matrix(
    baseline_binary: Path,
    candidate_binary: Path,
    *,
    limits: ContentionMatrixLimits | None = None,
) -> dict[str, Any]:
    """Compare operation-specific contention using real CLI processes and no model."""
    limits = limits or ContentionMatrixLimits()
    binaries = {
        "baseline": baseline_binary.expanduser().resolve(),
        "candidate": candidate_binary.expanduser().resolve(),
    }
    for label, binary in binaries.items():
        if not binary.is_file() or not os.access(binary, os.X_OK):
            raise ValueError(f"Contention {label} executable is unavailable: {binary}")

    measurements: dict[str, list[_EpisodeMeasurement]] = {
        "baseline": [],
        "candidate": [],
    }
    case_material: list[str] = []
    with tempfile.TemporaryDirectory(prefix="marginbench-contention-matrix-") as temporary:
        root = Path(temporary)
        for family in FAMILIES:
            for group_size in limits.group_sizes:
                for repetition in range(limits.repetitions):
                    case_material.append(f"{family}:{group_size}:{repetition}")
                    order = (
                        ("baseline", "candidate")
                        if repetition % 2 == 0
                        else ("candidate", "baseline")
                    )
                    for label in order:
                        measurements[label].append(_run_episode(
                            binaries[label],
                            root / label,
                            family=family,
                            repetition=repetition,
                            group_size=group_size,
                            limits=limits,
                        ))

    arms = {
        label: _arm_summary(binaries[label], measurements[label], limits)
        for label in ("baseline", "candidate")
    }
    return {
        "schema": MATRIX_SCHEMA,
        "version": MATRIX_VERSION,
        "paidModelsInvoked": False,
        "passed": arms["baseline"]["safetyPassed"] and arms["candidate"]["passed"],
        "fixture": {
            "caseSetSha256": hashlib.sha256(
                "\n".join(case_material).encode("ascii")
            ).hexdigest(),
            "caseCountPerArm": len(case_material),
        },
        "method": {
            "families": [
                {
                    "name": "typed-add",
                    "semanticClass": "commutative-annotation-addition",
                    "scriptedRecovery": "list-and-retry-while-source-is-unchanged",
                },
                {
                    "name": "suggestion-add",
                    "semanticClass": "commutative-anchored-proposal",
                    "scriptedRecovery": "reread-source-and-retry-exact-proposal",
                },
                {
                    "name": "suggestion-reject",
                    "semanticClass": "commutative-independent-decision",
                    "scriptedRecovery": "reinspect-suggestion-and-retry-exact-decision",
                },
                {
                    "name": "suggestion-accept",
                    "semanticClass": "source-mutating-decision",
                    "scriptedRecovery": "none-fail-closed-on-authored-base-drift",
                },
                {
                    "name": "handoff-add",
                    "semanticClass": "provenance-sensitive-state-transfer",
                    "scriptedRecovery": "none-reread-and-reauthor-required",
                },
            ],
            "groupSizes": list(limits.group_sizes),
            "repetitionsPerCase": limits.repetitions,
            "maximumRecoveryRounds": limits.recovery_rounds,
            "writerStartsSynchronized": True,
            "armOrderCounterbalanced": True,
            "baselineCompletionRequired": False,
            "timeoutSeconds": limits.timeout_seconds,
            "rawArgumentsRetained": False,
            "pathsBodiesAndIdentifiersRetained": False,
        },
        "arms": arms,
        "comparison": _comparison(arms["baseline"], arms["candidate"]),
    }
