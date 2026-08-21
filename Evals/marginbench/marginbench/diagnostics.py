"""Privacy-preserving diagnostics for turning benchmark evidence into experiments."""

from __future__ import annotations

import json
import sys
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any, Iterable

from .validation import MAX_ARTIFACT_BYTES, validate_bytes


DIAGNOSTIC_SCHEMA = "urn:marginbench:diagnostic-report:v1"
MAX_INPUT_ARTIFACTS = 128
MAX_EPISODES = 10_000
MAX_DISTINCT_VALUES = 128
MAX_EXAMPLES = 8
SUPPORTED_INPUTS = {
    "urn:marginbench:result:v1",
    "urn:marginbench:result-set:v1",
    "urn:marginbench:reference-run:v1",
    "urn:marginbench:prime-run-summary:v1",
    "urn:marginbench:run:v1",
    "urn:marginbench:trace-shape-report:v1",
}
INTEGRITY_CHECKS = {
    "source_expected",
    "valid_documents",
    "all_or_none",
    "workspace_expected_paths",
}
SAFETY_CHECKS = INTEGRITY_CHECKS | {"workspace_policy"}
HEAVY_RESULT_BUCKETS = frozenset({"4097-16384", "16385-65536", "65537+"})
MAX_SUPPLEMENTARY_TOOL_CALLS = 10_000_000
COMPLETION_CHECKS = frozenset({
    "all_expected_annotations",
    "annotation_identity",
    "annotation_body",
    "annotation_kind",
    "annotation_status",
    "annotation_thread",
    "annotation_properties",
    "minimum_annotations",
    "committed_all",
    "no_unexpected_annotations",
})
BUDGET_RELEVANT_CHECKS = COMPLETION_CHECKS | {
    "required_commands",
    "required_recovery_observed",
    "valid_command_use",
}


class DiagnosticError(ValueError):
    """A stable failure while reading public, redacted benchmark evidence."""


def _read(path: Path) -> bytes:
    if str(path) == "-":
        raw = sys.stdin.buffer.read(MAX_ARTIFACT_BYTES + 1)
    else:
        try:
            with path.expanduser().open("rb") as handle:
                raw = handle.read(MAX_ARTIFACT_BYTES + 1)
        except OSError as error:
            raise DiagnosticError("Diagnostic artifact could not be read.") from error
    if len(raw) > MAX_ARTIFACT_BYTES:
        raise DiagnosticError(f"Diagnostic artifact exceeds {MAX_ARTIFACT_BYTES} bytes.")
    return raw


def _scenario(identifier: str, explicit: object) -> str:
    if isinstance(explicit, str) and explicit:
        return explicit
    prefix = identifier.split(":", 1)[0]
    return prefix if prefix else "unknown"


def _normalized_snake(result: dict[str, Any]) -> dict[str, Any]:
    identifier = str(result["episode_id"])
    return {
        "id": identifier,
        "candidate": str(result["candidate_id"]),
        "topology": str(result.get("control_profile", "unspecified")),
        "scenario": _scenario(identifier, result.get("scenario")),
        "score": float(result["score"]),
        "safety": bool(result["safety_passed"]),
        "source": bool(result["source_preserved"]),
        "marginSha256": str(result["margin_sha256"]),
        "commands": int(result["command_count"]),
        "invalid": int(result["invalid_command_count"]),
        "checks": dict(result["checks"]),
        "dimensions": {str(key): float(value) for key, value in result["dimensions"].items()},
        "events": list(result.get("events", ())),
        "eventSummary": None,
        "stops": [],
    }


def _normalized_camel(
    episode: dict[str, Any],
    *,
    candidate: str,
    identifier_key: str,
    margin_sha256: str | None = None,
) -> dict[str, Any]:
    identifier = str(episode[identifier_key])
    role_runs = episode.get("roleRuns")
    stops = []
    if isinstance(role_runs, list):
        stops.extend(
            item.get("stopCondition")
            for item in role_runs
            if isinstance(item, dict) and isinstance(item.get("stopCondition"), str)
        )
    elif isinstance(episode.get("stopCondition"), str):
        stops.append(episode["stopCondition"])
    elif isinstance(episode.get("stopConditions"), list):
        for item in episode["stopConditions"]:
            if not isinstance(item, dict):
                continue
            name, count = item.get("name"), item.get("count")
            if isinstance(name, str) and isinstance(count, int) and 0 < count <= 128:
                stops.extend([name] * count)
    return {
        "id": identifier,
        "candidate": candidate,
        "topology": str(episode.get("controlProfile", "unspecified")),
        "scenario": _scenario(identifier, episode.get("scenario")),
        "score": float(episode["score"]),
        "safety": bool(episode["safetyPassed"]),
        "source": episode.get("sourcePreserved"),
        "marginSha256": str(episode.get("marginSha256") or margin_sha256 or ""),
        "commands": int(episode["commandCount"]),
        "invalid": int(episode["invalidCommandCount"]),
        "checks": dict(episode["checks"]),
        "dimensions": {
            str(key): float(value) for key, value in episode["dimensions"].items()
        },
        "events": [],
        "eventSummary": episode.get("eventSummary"),
        "stops": stops,
    }


def _episodes(payload: Any, schema: str) -> list[dict[str, Any]]:
    if schema == "urn:marginbench:prime-run-summary:v1" and payload.get("status") != "completed":
        raise DiagnosticError(
            "Infrastructure-error Prime runs are not product evidence. "
            "Inspect their content-free trace shape, then rerun the cell."
        )
    if schema == "urn:marginbench:run:v1" and payload.get("status") != "completed":
        raise DiagnosticError(
            "Infrastructure-error run manifests are not product evidence. "
            "Inspect their content-free trace shape, then rerun the cell."
        )
    if schema == "urn:marginbench:result:v1":
        return [_normalized_snake(payload)]
    if schema == "urn:marginbench:result-set:v1":
        values = payload if isinstance(payload, list) else payload["results"]
        return [_normalized_snake(value) for value in values]
    if schema == "urn:marginbench:reference-run:v1":
        return [_normalized_snake(value) for value in payload["results"]]
    if schema == "urn:marginbench:prime-run-summary:v1":
        return [
            _normalized_camel(
                value,
                candidate=str(payload["candidate"]),
                identifier_key="episodeID",
                margin_sha256=payload.get("marginSha256"),
            )
            for value in payload["episodes"]
        ]
    if schema == "urn:marginbench:run:v1":
        return [
            _normalized_camel(
                value,
                candidate=str(payload["candidate"]["id"]),
                identifier_key="id",
                margin_sha256=payload["candidate"].get("marginSha256"),
            )
            for value in payload["episodes"]
        ]
    raise DiagnosticError(f"Unsupported diagnostic input schema: {schema}")


def _mean(values: Iterable[float]) -> float:
    materialized = list(values)
    return round(sum(materialized) / len(materialized), 6) if materialized else 0.0


def _counter(counter: Counter[str], *, limit: int = MAX_DISTINCT_VALUES) -> list[dict[str, Any]]:
    return [
        {"name": name, "count": count}
        for name, count in sorted(counter.items(), key=lambda item: (-item[1], item[0]))[:limit]
    ]


def _affected(
    episodes: list[dict[str, Any]],
    predicate,
) -> tuple[list[dict[str, Any]], list[str]]:
    values = [episode for episode in episodes if predicate(episode)]
    scenarios = sorted({episode["scenario"] for episode in values})[:MAX_DISTINCT_VALUES]
    return values, scenarios


def _is_unsafe(episode: dict[str, Any]) -> bool:
    return (
        not episode["safety"]
        or episode["source"] is False
        or any(not episode["checks"].get(name, True) for name in SAFETY_CHECKS)
    )


def _source_failed(episode: dict[str, Any]) -> bool:
    return episode["source"] is False or not episode["checks"].get("source_expected", True)


def _unfinished_after_stop(episode: dict[str, Any]) -> bool:
    stopped_early = any(
        value not in {"agent_completed", "completed"} for value in episode["stops"]
    )
    if not stopped_early:
        return False
    if episode["dimensions"].get("outcome") != 100.0:
        return True
    return any(
        name in BUDGET_RELEVANT_CHECKS and not passed
        for name, passed in episode["checks"].items()
    )


def _finding(
    identifier: str,
    severity: str,
    title: str,
    episodes: list[dict[str, Any]],
    *,
    failed_checks: set[str] | None = None,
    surfaces: list[str],
    experiment: str,
) -> dict[str, Any]:
    affected_checks = Counter(
        name
        for episode in episodes
        for name, passed in episode["checks"].items()
        if not passed and (failed_checks is None or name in failed_checks)
    )
    stop_conditions = Counter(value for episode in episodes for value in episode["stops"])
    return {
        "id": identifier,
        "severity": severity,
        "title": title,
        "evidence": {
            "episodeCount": len(episodes),
            "scenarios": sorted({episode["scenario"] for episode in episodes})[:MAX_DISTINCT_VALUES],
            "exampleEpisodeIDs": sorted({episode["id"] for episode in episodes})[:MAX_EXAMPLES],
            "failedChecks": _counter(affected_checks),
            "invalidCommandCount": sum(episode["invalid"] for episode in episodes),
            "stopConditions": _counter(stop_conditions),
        },
        "candidateSurfaces": surfaces,
        "nextExperiment": experiment,
    }


def _command_response_buckets(
    reports: list[dict[str, Any]],
    command: str,
    *,
    required_flag: str | None = None,
) -> Counter[str]:
    buckets: Counter[str] = Counter()
    signature_details_available = False
    if required_flag is not None:
        for report in reports:
            for item in report.get("commandSignatures", ()):
                if item.get("command") != command or "resultSizeBuckets" not in item:
                    continue
                signature_details_available = True
                if required_flag not in item.get("flags", ()):
                    continue
                for bucket in item.get("resultSizeBuckets", ()):
                    buckets[str(bucket["name"])] += int(bucket["count"])
        if signature_details_available:
            if sum(buckets.values()) > MAX_SUPPLEMENTARY_TOOL_CALLS:
                raise DiagnosticError(
                    "Supplementary trace evidence exceeds the diagnostic call limit."
                )
            return buckets
    for report in reports:
        for item in report.get("commandResultSizeBuckets", ()):
            if item.get("command") != command:
                continue
            for bucket in item.get("buckets", ()):
                buckets[str(bucket["name"])] += int(bucket["count"])
    if sum(buckets.values()) > MAX_SUPPLEMENTARY_TOOL_CALLS:
        raise DiagnosticError(
            "Supplementary trace evidence exceeds the diagnostic call limit."
        )
    return buckets


def _context_response_evidence(
    reports: list[dict[str, Any]],
) -> dict[str, Any] | None:
    buckets = _command_response_buckets(reports, "context", required_flag="--brief")
    result_count = sum(buckets.values())
    heavy_count = sum(
        count for name, count in buckets.items() if name in HEAVY_RESULT_BUCKETS
    )
    if heavy_count < 2 or heavy_count * 4 < result_count:
        return None
    return {
        "command": "context",
        "resultCount": result_count,
        "largerThan4096Count": heavy_count,
        "buckets": _counter(buckets),
    }


def _capability_response_evidence(
    reports: list[dict[str, Any]],
) -> dict[str, Any] | None:
    buckets = _command_response_buckets(
        reports, "capabilities", required_flag="--brief"
    )
    result_count = sum(buckets.values())
    heavy_count = sum(
        count for name, count in buckets.items() if name in HEAVY_RESULT_BUCKETS
    )
    very_heavy_count = sum(
        buckets.get(name, 0) for name in ("16385-65536", "65537+")
    )
    # One 16 KiB+ discovery response consumes a meaningful part of an agent
    # turn. For 4-16 KiB responses, require a repeated pattern affecting at
    # least half of capability lookups.
    if very_heavy_count < 1 and (heavy_count < 2 or heavy_count * 2 < result_count):
        return None
    return {
        "command": "capabilities",
        "resultCount": result_count,
        "largerThan4096Count": heavy_count,
        "buckets": _counter(buckets),
    }


def _write_latency_evidence(
    reports: list[dict[str, Any]],
) -> dict[str, Any] | None:
    trace_count = 0
    with_write = 0
    without_write = 0
    write_attempt_count = 0
    buckets: Counter[str] = Counter()
    for report in reports:
        latency = report.get("writeLatency")
        if not isinstance(latency, dict):
            continue
        trace_count += int(latency["traceCount"])
        with_write += int(latency["tracesWithWriteAttempt"])
        without_write += int(latency["tracesWithoutWriteAttempt"])
        write_attempt_count += int(latency["writeAttemptCount"])
        for row in latency["preWriteToolCallBuckets"]:
            buckets[str(row["name"])] += int(row["count"])
    if trace_count > MAX_SUPPLEMENTARY_TOOL_CALLS:
        raise DiagnosticError(
            "Supplementary trace evidence exceeds the diagnostic trace limit."
        )
    delayed = buckets.get("5-6", 0) + buckets.get("7+", 0)
    if with_write == 0 or delayed == 0 or delayed * 2 < with_write:
        return None
    return {
        "traceCount": trace_count,
        "tracesWithWriteAttempt": with_write,
        "tracesWithoutWriteAttempt": without_write,
        "writeAttemptCount": write_attempt_count,
        "fiveOrMorePreWriteCount": delayed,
        "preWriteToolCallBuckets": _counter(buckets),
    }


def _suggestion_mechanism_evidence(
    reports: list[dict[str, Any]],
) -> dict[str, int] | None:
    fields = (
        "applicableTraceCount",
        "batchTeachingViewedBeforeWriteTraceCount",
        "batchAdoptionTraceCount",
        "batchAdoptionAfterTeachingTraceCount",
        "individualAddTraceCount",
        "individualAddAfterTeachingTraceCount",
        "waitReceiptObservedTraceCount",
        "waitReceiptTrustedTraceCount",
        "postWaitReverificationTraceCount",
        "preWriteStateReadTraceCount",
        "extraPostWriteStateReadTraceCount",
    )
    totals: Counter[str] = Counter()
    for report in reports:
        mechanisms = report.get("suggestionMechanisms")
        if not isinstance(mechanisms, dict):
            continue
        for field in fields:
            totals[field] += int(mechanisms.get(field, 0))
    if totals["applicableTraceCount"] == 0:
        return None
    if totals["applicableTraceCount"] > MAX_SUPPLEMENTARY_TOOL_CALLS:
        raise DiagnosticError(
            "Supplementary suggestion evidence exceeds the diagnostic trace limit."
        )
    return {field: totals[field] for field in fields}


def _findings(
    episodes: list[dict[str, Any]],
    *,
    context_response_evidence: dict[str, Any] | None = None,
    capability_response_evidence: dict[str, Any] | None = None,
    write_latency_evidence: dict[str, Any] | None = None,
    suggestion_mechanism_evidence: dict[str, int] | None = None,
) -> list[dict[str, Any]]:
    findings: list[dict[str, Any]] = []
    integrity, _ = _affected(
        episodes,
        lambda item: item["source"] is False
        or any(not item["checks"].get(name, True) for name in INTEGRITY_CHECKS),
    )
    if integrity:
        findings.append(_finding(
            "safety-or-integrity",
            "critical",
            "A candidate damaged or escaped the shared document state",
            integrity,
            failed_checks=INTEGRITY_CHECKS,
            surfaces=["transaction behavior", "workspace confinement", "recovery feedback"],
            experiment=(
                "Stop paid expansion. Reproduce these cases locally, change one safety surface, "
                "and require every affected case to preserve valid all-or-none documents."
            ),
        ))

    policy_attempts, _ = _affected(
        episodes,
        lambda item: not item["checks"].get("workspace_policy", True),
    )
    if policy_attempts:
        findings.append(_finding(
            "workspace-policy-attempt",
            "critical",
            "Agents attempted a disallowed operation; the workspace boundary held",
            policy_attempts,
            failed_checks={"workspace_policy"},
            surfaces=["tool boundary guidance", "blocked-command recovery", "progressive disclosure"],
            experiment=(
                "Keep the enforcement boundary unchanged, clarify the exact safe replacement at "
                "the blocked call, and rerun the identical cases with the same model and limits."
            ),
        ))

    duplicates, _ = _affected(
        episodes,
        lambda item: not item["checks"].get("duplicate_free", True),
    )
    if duplicates:
        findings.append(_finding(
            "durable-record-integrity",
            "high",
            "The shared record contains duplicate durable work",
            duplicates,
            failed_checks={"duplicate_free"},
            surfaces=["idempotent mutation", "retry receipts", "request identity"],
            experiment=(
                "Reproduce the retry path locally and change only idempotency or receipt guidance; "
                "require one durable contribution after repeated identical attempts."
            ),
        ))

    completion, _ = _affected(
        episodes,
        lambda item: any(not item["checks"].get(name, True) for name in COMPLETION_CHECKS),
    )
    if completion:
        findings.append(_finding(
            "durable-completion",
            "high",
            "Agents did not leave the complete durable result",
            completion,
            failed_checks=set(COMPLETION_CHECKS),
            surfaces=["mutation receipts", "next actions", "workflow help"],
            experiment=(
                "Clarify the smallest missing completion step in CLI receipts or task-specific "
                "help, then rerun the same matched cases with model and limits unchanged."
            ),
        ))

    recovery, _ = _affected(
        episodes,
        lambda item: not item["checks"].get("required_recovery_observed", True),
    )
    if recovery:
        findings.append(_finding(
            "recovery-discoverability",
            "high",
            "Agents missed the required stale-state recovery path",
            recovery,
            failed_checks={"required_recovery_observed"},
            surfaces=["error response", "recovery command", "stage review"],
            experiment=(
                "Make the safe recovery command explicit at the point of failure and compare it "
                "on the same stale-state cases."
            ),
        ))

    workflow, _ = _affected(
        episodes,
        lambda item: not item["checks"].get("required_commands", True),
    )
    if workflow:
        findings.append(_finding(
            "workflow-discoverability",
            "high",
            "Agents missed the intended collaboration workflow",
            workflow,
            failed_checks={"required_commands"},
            surfaces=["workflow help", "command grouping", "receipt next actions"],
            experiment=(
                "Expose the intended workflow through one concise discovery path, then rerun the "
                "same cases without changing the role brief or model."
            ),
        ))

    command_use, _ = _affected(
        episodes,
        lambda item: item["invalid"] > 0 or not item["checks"].get("valid_command_use", True),
    )
    if command_use:
        findings.append(_finding(
            "command-discoverability",
            "high",
            "Agents used invalid command forms",
            command_use,
            failed_checks={"valid_command_use"},
            surfaces=["task-specific help", "usage errors", "argument grammar"],
            experiment=(
                "Change only command discovery or error guidance, then measure invalid-command "
                "count and total commands on the identical matched episodes."
            ),
        ))

    attribution, _ = _affected(
        episodes,
        lambda item: not item["checks"].get("attribution", True),
    )
    if attribution:
        findings.append(_finding(
            "collaborator-attribution",
            "high",
            "Durable work was attributed to the wrong collaborator",
            attribution,
            failed_checks={"attribution"},
            surfaces=["actor binding", "identity defaults", "receipt identity"],
            experiment=(
                "Keep prompts fixed and tighten actor binding or identity feedback until every "
                "matched contribution retains the assigned collaborator."
            ),
        ))

    inefficient, _ = _affected(
        episodes,
        lambda item: item["dimensions"].get("efficiency", 100.0) < 100.0,
    )
    redundant_discovery, _ = _affected(
        episodes,
        lambda item: not item["checks"].get("avoided_redundant_initial_reads", True),
    )
    if redundant_discovery:
        findings.append(_finding(
            "redundant-discovery",
            "medium",
            "Agents opened overlapping directory views before acting",
            redundant_discovery,
            failed_checks={"avoided_redundant_initial_reads"},
            surfaces=["bounded context", "inbox guidance", "first-action defaults"],
            experiment=(
                "Keep task limits fixed and make one initial view sufficient; require each role "
                "to choose context or inbox, then compare response-size buckets and model input."
            ),
        ))
    incomplete_batch_adoption, _ = _affected(
        episodes,
        lambda item: item["checks"].get(
            "diagnostic_atomic_batch_used_by_all_roles"
        ) is False,
    )
    if incomplete_batch_adoption:
        finding = _finding(
            "incomplete-batch-adoption",
            "medium",
            "Some collaborators did not use the available atomic batch path",
            incomplete_batch_adoption,
            failed_checks={"diagnostic_atomic_batch_used_by_all_roles"},
            surfaces=["suggestion fast path", "command-local help", "progressive disclosure"],
            experiment=(
                "Keep the task and batch command fixed, put one complete bounded batch recipe in "
                "the first focused suggestion surface, and compare per-role adoption, help calls, "
                "completion, and total interactions against the frozen candidate."
            ),
        )
        if suggestion_mechanism_evidence is not None:
            finding["evidence"]["suggestionMechanismEvidence"] = (
                suggestion_mechanism_evidence
            )
        findings.append(finding)
    wait_reverification, _ = _affected(
        episodes,
        lambda item: item["checks"].get(
            "diagnostic_no_reverification_after_successful_wait"
        ) is False,
    )
    if wait_reverification:
        findings.append(_finding(
            "wait-reverification",
            "medium",
            "A collaborator rechecked durable state after a successful named wait",
            wait_reverification,
            failed_checks={"diagnostic_no_reverification_after_successful_wait"},
            surfaces=["wait receipt", "next actions", "focused suggestion help"],
            experiment=(
                "Keep the task and wait predicate fixed, make a successful receipt explicitly "
                "terminal for the named ids, and compare later list/wait calls, completion, "
                "latency, and model input without weakening the separate source-read requirement."
            ),
        ))
    extra_postwrite_state_reads = (
        suggestion_mechanism_evidence is not None
        and suggestion_mechanism_evidence["extraPostWriteStateReadTraceCount"] > 0
        and suggestion_mechanism_evidence["postWaitReverificationTraceCount"] == 0
    )
    if extra_postwrite_state_reads:
        finding = _finding(
            "extra-postwrite-state-reads",
            "medium",
            "A collaborator performed extra state reads after required verification",
            episodes,
            failed_checks={"diagnostic_no_extra_postwrite_state_reads"},
            surfaces=["mutation receipt", "wait receipt", "focused suggestion help"],
            experiment=(
                "First replicate this pattern on matched private cases. If it persists, keep the "
                "required convergence check and literal source read fixed while making their "
                "successful receipts clearly terminal; compare extra state reads, correctness, "
                "latency, and model input against the frozen candidate."
            ),
        )
        finding["evidence"]["suggestionMechanismEvidence"] = (
            suggestion_mechanism_evidence
        )
        findings.append(finding)
    repeated_postwrite_verification, _ = _affected(
        episodes,
        lambda item: item["checks"].get(
            "diagnostic_one_postwrite_verification_per_role"
        ) is False,
    )
    if repeated_postwrite_verification and not extra_postwrite_state_reads:
        findings.append(_finding(
            "repeated-postwrite-verification",
            "medium",
            "A collaborator repeated final verification after its own write completed",
            repeated_postwrite_verification,
            failed_checks={"diagnostic_one_postwrite_verification_per_role"},
            surfaces=["known-peer convergence", "mutation receipts", "bounded watch"],
            experiment=(
                "Keep writes and final checks fixed. Where no named wait exists, compare one "
                "bounded wait with list polling; where a wait already succeeded, make its receipt "
                "conclusive and compare later state checks, latency, and completion."
            ),
        ))
    if write_latency_evidence is not None:
        finding = _finding(
            "long-path-to-first-write",
            "medium",
            "Agents spend too many interactions orienting before their first write",
            episodes,
            failed_checks=set(),
            surfaces=["context next actions", "workflow guidance", "mutation receipts"],
            experiment=(
                "Keep tasks and model fixed, return a safe concrete next-action template in the "
                "first bounded context view, and compare pre-write buckets, completion, commands, "
                "and invalid-command count against the frozen candidate."
            ),
        )
        finding["evidence"]["writeLatencyEvidence"] = write_latency_evidence
        findings.append(finding)
    if capability_response_evidence is not None:
        finding = _finding(
            "oversized-capability-responses",
            "medium",
            "Task discovery responses are larger than progressive orientation needs",
            episodes,
            failed_checks=set(),
            surfaces=["workflow capability projection", "command-local help", "progressive disclosure"],
            experiment=(
                "Keep tasks and model fixed, expose a smaller task capability index that points "
                "to exact command-local help, and compare response-size buckets, model input, "
                "commands, and correctness against the detailed workflow projection."
            ),
        )
        finding["evidence"]["responseSizeEvidence"] = capability_response_evidence
        findings.append(finding)
    if context_response_evidence is not None:
        finding = _finding(
            "heavy-context-responses",
            "medium",
            "Context responses are repeatedly larger than a compact orientation view",
            episodes,
            failed_checks=set(),
            surfaces=["bounded context", "compact projection", "progressive disclosure"],
            experiment=(
                "Keep tasks and model fixed, expose a compact context projection through the "
                "candidate's own help, and compare response-size buckets, model input, commands, "
                "and correctness against the full projection."
            ),
        )
        finding["evidence"]["responseSizeEvidence"] = context_response_evidence
        findings.append(finding)
    if inefficient:
        findings.append(_finding(
            "interaction-efficiency",
            "medium",
            "Agents needed more Margin interactions than the efficient path",
            inefficient,
            failed_checks=set(),
            surfaces=["bounded context", "workflow shortcuts", "receipt next actions"],
            experiment=(
                "Keep correctness fixed and test one shorter read-or-mutate path; compare command "
                "count, invalid commands, tokens, and duration on the same episodes."
            ),
        ))

    unfinished_stops, _ = _affected(
        episodes,
        _unfinished_after_stop,
    )
    if unfinished_stops:
        findings.append(_finding(
            "agent-budget-exhaustion",
            "medium",
            "An agent stopped before declaring its role complete",
            unfinished_stops,
            failed_checks=set(),
            surfaces=["progressive disclosure", "response compactness", "role completion signal"],
            experiment=(
                "Reduce discovery and response overhead before raising limits; rerun with the same "
                "turn and token ceilings to test whether the interface itself improved."
            ),
        ))

    if not findings:
        findings.append(_finding(
            "no-ranked-defect",
            "info",
            "No correctness or efficiency defect appears in these artifacts",
            episodes,
            failed_checks=set(),
            surfaces=["private case coverage", "scenario breadth"],
            experiment=(
                "Freeze this candidate and test it on matched private repetitions or a new "
                "collaboration pressure without changing the model or limits."
            ),
        ))
    return findings[:10]


def _group_summary(values: list[dict[str, Any]], name_key: str, name: str) -> dict[str, Any]:
    dimensions: defaultdict[str, list[float]] = defaultdict(list)
    failed = Counter()
    for episode in values:
        for dimension, score in episode["dimensions"].items():
            dimensions[dimension].append(score)
        failed.update(check for check, passed in episode["checks"].items() if not passed)
    return {
        name_key: name,
        "episodeCount": len(values),
        "meanScore": _mean(episode["score"] for episode in values),
        "minimumScore": min(episode["score"] for episode in values),
        "maximumScore": max(episode["score"] for episode in values),
        "commandCount": sum(episode["commands"] for episode in values),
        "meanCommandCount": _mean(float(episode["commands"]) for episode in values),
        "invalidCommandCount": sum(episode["invalid"] for episode in values),
        "safetyFailureCount": sum(_is_unsafe(episode) for episode in values),
        "sourceFailureCount": sum(_source_failed(episode) for episode in values),
        "dimensionMeans": {
            key: _mean(scores) for key, scores in sorted(dimensions.items())
        },
        "failedChecks": _counter(failed),
    }


def diagnose_artifacts(
    paths: Iterable[Path],
    *,
    focus_candidate: str | None = None,
) -> dict[str, Any]:
    inputs = list(paths)
    if not inputs or len(inputs) > MAX_INPUT_ARTIFACTS:
        raise DiagnosticError(
            f"Diagnostics require between 1 and {MAX_INPUT_ARTIFACTS} artifacts."
        )
    if sum(str(path) == "-" for path in inputs) > 1:
        raise DiagnosticError("Standard input may be used for at most one diagnostic artifact.")

    artifacts: list[dict[str, Any]] = []
    episodes: list[dict[str, Any]] = []
    trace_reports: list[dict[str, Any]] = []
    trace_source_hashes: set[str] = set()
    for path in inputs:
        raw = _read(path)
        receipt = validate_bytes(raw)
        schema = receipt.get("artifactSchema")
        if not receipt["valid"]:
            error = receipt.get("error") or {"code": "ARTIFACT_INVALID"}
            raise DiagnosticError(f"Invalid diagnostic input ({error['code']}).")
        if schema not in SUPPORTED_INPUTS:
            raise DiagnosticError(f"Unsupported diagnostic input schema: {schema}")
        payload = json.loads(raw)
        artifacts.append({
            "schema": schema,
            "sha256": receipt["sha256"],
            "byteCount": receipt["byteCount"],
        })
        if schema == "urn:marginbench:trace-shape-report:v1":
            current_sources = {str(item["sha256"]) for item in payload["sources"]}
            if trace_source_hashes.intersection(current_sources):
                raise DiagnosticError(
                    "Trace shape inputs overlap the same private trace source."
                )
            trace_source_hashes.update(current_sources)
            trace_reports.append(payload)
        else:
            episodes.extend(_episodes(payload, schema))
        if len(episodes) > MAX_EPISODES:
            raise DiagnosticError(f"Diagnostics exceed the {MAX_EPISODES}-episode limit.")
    if not episodes:
        raise DiagnosticError("Diagnostic inputs contain no episodes.")
    identities = [
        (item["candidate"], item["id"], item["topology"])
        for item in episodes
    ]
    if len(identities) != len(set(identities)):
        raise DiagnosticError(
            "Diagnostic inputs repeat a candidate/episode pair within one topology."
        )

    failed_checks = Counter(
        check
        for episode in episodes
        for check, passed in episode["checks"].items()
        if not passed
    )
    if len(failed_checks) > MAX_DISTINCT_VALUES:
        raise DiagnosticError(
            f"Diagnostics support at most {MAX_DISTINCT_VALUES} distinct failed checks."
        )
    error_codes = Counter()
    failing_commands = Counter()
    blocked = 0
    stops = Counter()
    for episode in episodes:
        stops.update(episode["stops"])
        event_summary = episode.get("eventSummary")
        if isinstance(event_summary, dict):
            for item in event_summary.get("errors", ()):
                error_codes[str(item["name"])] += int(item["count"])
            for item in event_summary.get("commands", ()):
                failure_count = int(item["failureCount"])
                if failure_count:
                    failing_commands[str(item["name"])] += failure_count
            blocked += int(event_summary.get("blockedCount", 0))
        else:
            for event in episode["events"]:
                if event.get("error_code"):
                    error_codes[str(event["error_code"])] += 1
                if int(event.get("exit_code", 0)) != 0:
                    failing_commands[str(event.get("command", "unknown"))] += 1
                blocked += bool(event.get("blocked", False))

    candidates: defaultdict[str, list[dict[str, Any]]] = defaultdict(list)
    scenarios: defaultdict[str, list[dict[str, Any]]] = defaultdict(list)
    dimensions: defaultdict[str, list[float]] = defaultdict(list)
    for episode in episodes:
        candidates[episode["candidate"]].append(episode)
        scenarios[episode["scenario"]].append(episode)
        for dimension, score in episode["dimensions"].items():
            dimensions[dimension].append(score)
    if len(candidates) > MAX_DISTINCT_VALUES or len(scenarios) > MAX_DISTINCT_VALUES:
        raise DiagnosticError(
            f"Diagnostics support at most {MAX_DISTINCT_VALUES} candidates and scenarios."
        )
    if len(dimensions) > 32:
        raise DiagnosticError("Diagnostics support at most 32 score dimensions.")

    if focus_candidate is None:
        if len(candidates) != 1:
            raise DiagnosticError(
                "Diagnostics with multiple candidates require an explicit focus candidate."
            )
        focus_candidate = next(iter(candidates))
    if focus_candidate not in candidates:
        raise DiagnosticError("The focus candidate is absent from the diagnostic inputs.")
    focus_episodes = candidates[focus_candidate]
    focus_trace_reports = trace_reports
    if trace_reports:
        candidate_digests = {
            candidate_id: {item["marginSha256"] for item in candidate_episodes}
            for candidate_id, candidate_episodes in candidates.items()
        }
        focus_trace_reports = []
        for report in trace_reports:
            report_candidate_ids = report.get("candidateIDs")
            report_digests = set(report.get("candidateMarginSha256s", ()))
            if report_candidate_ids is not None:
                matches = list(report_candidate_ids)
                if len(matches) != 1 or matches[0] not in candidates:
                    raise DiagnosticError(
                        "Supplementary trace evidence must name exactly one input candidate."
                    )
                if report_digests and report_digests != candidate_digests[matches[0]]:
                    raise DiagnosticError(
                        "Supplementary trace evidence disagrees with its candidate digest."
                    )
            else:
                if not report_digests:
                    if len(candidates) == 1:
                        matches = [next(iter(candidates))]
                    else:
                        raise DiagnosticError(
                            "Multi-candidate diagnostics require trace evidence linked by "
                            "candidate ID or digest."
                        )
                else:
                    matches = [
                        candidate_id
                        for candidate_id, digests in candidate_digests.items()
                        if report_digests == digests
                    ]
            if len(matches) != 1:
                raise DiagnosticError(
                    "Supplementary trace evidence must belong to exactly one input candidate."
                )
            if matches[0] == focus_candidate:
                focus_trace_reports.append(report)
    findings = _findings(
        focus_episodes,
        context_response_evidence=_context_response_evidence(focus_trace_reports),
        capability_response_evidence=_capability_response_evidence(focus_trace_reports),
        write_latency_evidence=_write_latency_evidence(focus_trace_reports),
        suggestion_mechanism_evidence=_suggestion_mechanism_evidence(
            focus_trace_reports
        ),
    )
    safety_failures = sum(_is_unsafe(episode) for episode in episodes)
    source_failures = sum(_source_failed(episode) for episode in episodes)
    focus_summary = _group_summary(focus_episodes, "candidateID", focus_candidate)
    next_gate = (
        "local-safety"
        if focus_summary["safetyFailureCount"] or focus_summary["sourceFailureCount"]
        else "matched-private-pairs"
    )
    return {
        "schema": DIAGNOSTIC_SCHEMA,
        "artifactCount": len(artifacts),
        "artifacts": artifacts,
        "episodeCount": len(episodes),
        "candidateCount": len(candidates),
        "scenarioCount": len(scenarios),
        "focusCandidateID": focus_candidate,
        "focus": focus_summary,
        "scoreSummary": {
            "mean": _mean(episode["score"] for episode in episodes),
            "minimum": min(episode["score"] for episode in episodes),
            "maximum": max(episode["score"] for episode in episodes),
        },
        "safetyFailureCount": safety_failures,
        "sourceFailureCount": source_failures,
        "commandCount": sum(episode["commands"] for episode in episodes),
        "invalidCommandCount": sum(episode["invalid"] for episode in episodes),
        "blockedCommandCount": blocked,
        "dimensionMeans": {key: _mean(values) for key, values in sorted(dimensions.items())},
        "failedChecks": _counter(failed_checks),
        "errorCodes": _counter(error_codes),
        "failingCommandPaths": _counter(failing_commands),
        "stopConditions": _counter(stops),
        "candidates": [
            _group_summary(values, "candidateID", name)
            for name, values in sorted(candidates.items())[:MAX_DISTINCT_VALUES]
        ],
        "scenarios": [
            _group_summary(values, "scenario", name)
            for name, values in sorted(scenarios.items())[:MAX_DISTINCT_VALUES]
        ],
        "findings": findings,
        "topOpportunity": findings[0]["id"],
        "recommendedNextExperiment": {
            "gate": next_gate,
            "hypothesis": findings[0]["nextExperiment"],
            "changeOneSurfaceAtATime": True,
            "holdConstant": [
                "model",
                "generated episodes",
                "role layout",
                "turn and token limits",
            ],
            "minimumMatchedEpisodes": 0 if next_gate == "local-safety" else 20,
        },
        "privacy": {
            "documentContentRetained": False,
            "promptsRetained": False,
            "rawTracesRequired": False,
            "artifactPathsRetained": False,
            "exactResultSizesRetained": False,
        },
    }
