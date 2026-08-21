"""Representation-aware efficiency vectors; deliberately no scalar ranking."""

from __future__ import annotations

import hashlib
import json
from collections import defaultdict
from pathlib import Path
from typing import Any

from .schema import canonical_json
from .validation import MAX_ARTIFACT_BYTES, validate_bytes


EFFICIENCY_REPORT_SCHEMA = "urn:marginbench:efficiency-report:v1"
NEUTRAL_PREFLIGHT_SCHEMA = "urn:marginbench:neutral-served-preflight:v1"
NEUTRAL_RUN_SCHEMA = "urn:marginbench:neutral-run:v1"
RUN_SCHEMA = "urn:marginbench:run:v1"
MAX_SOURCE_COUNT = 64
MAX_TOTAL_SOURCE_BYTES = 64 * 1_024 * 1_024
EFFICIENCY_RULES = (
    "Correctness and safety gate resource interpretation.",
    "An episode id alone does not prove that experiment settings matched.",
    "Tool round trips are descriptive because operations carry unequal work.",
    "Scripted-reference and real-model cells are never ranked against each other.",
    "Missing measurements remain null and are never imputed as zero.",
    "No weighted efficiency score or winner is produced.",
)
CONTRACT_FIELDS = (
    "adapter",
    "admission-budget-policy",
    "agent-process-count",
    "benchmark-development-cases",
    "benchmark-implementation",
    "benchmark-version",
    "billing-overhead-usd-per-call",
    "episode-fingerprint",
    "episode-repetition",
    "episode-scenario",
    "input-token-ceiling-per-call",
    "live-proxy-max-request-bytes",
    "live-proxy-template-token-allowance",
    "live-proxy-timeout-seconds",
    "logical-actors",
    "max-concurrent-episodes",
    "max-input-tokens",
    "max-output-tokens",
    "max-tokens-per-call",
    "max-total-tokens",
    "max-turns",
    "minimum-request-interval-seconds",
    "minimum-start-interval-seconds",
    "model",
    "phase-policy",
    "prior-infrastructure-attempts",
    "provider",
    "provider-response-token-allowance",
    "retry-policy",
    "roles",
    "rollout-timeout-seconds",
    "runtime",
    "task-set",
    "temperature",
    "trace-seats",
    "upstream-attempts-per-turn",
    "wall-timeout-seconds",
)
_MISSING = object()


def _value(mapping: Any, key: str) -> Any:
    return mapping[key] if isinstance(mapping, dict) and key in mapping else _MISSING


def _comparison_contract(
    payload: dict[str, Any],
    episode: dict[str, Any],
) -> dict[str, Any]:
    """Return content-free evidence that comparable execution settings were equal."""
    benchmark = payload.get("benchmark", {})
    execution = payload.get("execution", {})
    limits = execution.get("limits", {}) if isinstance(execution, dict) else {}
    cost = payload.get("cost", {})
    budget_keys = (
        "admissionBound",
        "contractBound",
        "liveBudgetCap",
        "hardAdmissionCap",
        "boundBasis",
    )
    budget_policy = (
        {key: cost[key] for key in budget_keys}
        if isinstance(cost, dict) and all(key in cost for key in budget_keys)
        else _MISSING
    )
    logical_actors = _value(episode, "logicalActors")
    if logical_actors is not _MISSING:
        logical_actors = sorted(
            logical_actors,
            key=lambda actor: (
                actor.get("phase", -1), actor.get("seat", ""), actor.get("id", "")
            ),
        )
    raw = {
        "adapter": _value(execution, "adapter"),
        "admission-budget-policy": budget_policy,
        "agent-process-count": _value(episode, "agentProcessCount"),
        "benchmark-development-cases": _value(benchmark, "developmentCases"),
        "benchmark-implementation": _value(benchmark, "implementationSha256"),
        "benchmark-version": _value(benchmark, "version"),
        "billing-overhead-usd-per-call": _value(limits, "billingOverheadUSDPerCall"),
        "episode-fingerprint": _value(episode, "fingerprint"),
        "episode-repetition": _value(episode, "repetition"),
        "episode-scenario": _value(episode, "scenario"),
        "input-token-ceiling-per-call": _value(limits, "inputTokenCeilingPerCall"),
        "live-proxy-max-request-bytes": _value(limits, "liveProxyMaxRequestBytes"),
        "live-proxy-template-token-allowance": _value(
            limits, "liveProxyTemplateTokenAllowance"
        ),
        "live-proxy-timeout-seconds": _value(limits, "liveProxyTimeoutSeconds"),
        "logical-actors": logical_actors,
        "max-concurrent-episodes": _value(limits, "maxConcurrentEpisodes"),
        "max-input-tokens": _value(limits, "maxInputTokens"),
        "max-output-tokens": _value(limits, "maxOutputTokens"),
        "max-tokens-per-call": _value(limits, "maxTokensPerCall"),
        "max-total-tokens": _value(limits, "maxTotalTokens"),
        "max-turns": _value(limits, "maxTurns"),
        "minimum-request-interval-seconds": (
            limits.get("minimumRequestIntervalSeconds", 0.0)
            if isinstance(limits, dict)
            else _MISSING
        ),
        "minimum-start-interval-seconds": _value(
            limits, "minimumStartIntervalSeconds"
        ),
        "model": _value(execution, "model"),
        "phase-policy": _value(episode, "phasePolicy"),
        "prior-infrastructure-attempts": _value(
            execution, "priorInfrastructureAttempts"
        ),
        "provider": _value(execution, "provider"),
        "provider-reasoning-token-ceiling": _value(
            limits, "providerReasoningTokenCeiling"
        ),
        "provider-reasoning-token-ceiling-source": _value(
            limits, "providerReasoningTokenCeilingSource"
        ),
        "provider-response-token-allowance": _value(
            limits, "providerResponseTokenAllowance"
        ),
        "retry-policy": _value(execution, "retryPolicy"),
        "roles": (
            sorted(execution["roles"])
            if isinstance(execution, dict) and "roles" in execution
            else _MISSING
        ),
        "rollout-timeout-seconds": _value(limits, "rolloutTimeoutSeconds"),
        "runtime": _value(execution, "runtime"),
        "task-set": _value(benchmark, "taskSet"),
        "temperature": _value(limits, "temperature"),
        "trace-seats": (
            sorted(episode["traceSeats"])
            if isinstance(episode, dict) and "traceSeats" in episode
            else _MISSING
        ),
        "upstream-attempts-per-turn": _value(limits, "upstreamAttemptsPerTurn"),
        "wall-timeout-seconds": _value(limits, "wallTimeoutSeconds"),
    }
    missing = sorted(field for field in CONTRACT_FIELDS if raw[field] is _MISSING)
    field_digests = [
        {
            "field": field,
            "sha256": hashlib.sha256(canonical_json(raw[field])).hexdigest(),
        }
        for field in CONTRACT_FIELDS
        if raw[field] is not _MISSING
    ]
    complete = not missing
    return {
        "version": 1,
        "complete": complete,
        "fieldDigests": field_digests,
        "missingFields": missing,
        "sha256": (
            hashlib.sha256(canonical_json(field_digests)).hexdigest()
            if complete
            else None
        ),
    }


def _contract_evidence_is_valid(evidence: dict[str, Any]) -> bool:
    digests = evidence.get("fieldDigests", [])
    present = [item.get("field") for item in digests if isinstance(item, dict)]
    missing = evidence.get("missingFields", [])
    if present != sorted(present) or missing != sorted(missing):
        return False
    if len(present) != len(set(present)) or len(missing) != len(set(missing)):
        return False
    if set(present) | set(missing) != set(CONTRACT_FIELDS):
        return False
    if set(present) & set(missing):
        return False
    complete = not missing
    expected_sha = (
        hashlib.sha256(canonical_json(digests)).hexdigest() if complete else None
    )
    return (
        evidence.get("version") == 1
        and evidence.get("complete") == complete
        and evidence.get("sha256") == expected_sha
    )


def _contract_result(values: list[dict[str, Any]]) -> tuple[str, list[str], list[str]]:
    if len(values) < 2 or not all(value["modelExecuted"] for value in values):
        return "not-applicable", [], []
    missing = sorted({
        field
        for value in values
        for field in value["comparisonContract"]["missingFields"]
    })
    by_value = [
        {
            item["field"]: item["sha256"]
            for item in value["comparisonContract"]["fieldDigests"]
        }
        for value in values
    ]
    differences = sorted(
        field
        for field in CONTRACT_FIELDS
        if all(field in evidence for evidence in by_value)
        and len({evidence[field] for evidence in by_value}) > 1
    )
    if differences:
        return "mismatch", differences, missing
    if missing:
        return "insufficient-metadata", [], missing
    return "matched", [], []


def _read(path: Path) -> tuple[dict[str, Any], dict[str, Any]]:
    try:
        raw = path.expanduser().read_bytes()
    except OSError as error:
        raise ValueError("Efficiency source artifact is unavailable.") from error
    if len(raw) > MAX_ARTIFACT_BYTES:
        raise ValueError("Efficiency source artifact exceeds the validation bound.")
    receipt = validate_bytes(raw)
    if not receipt["valid"]:
        raise ValueError("Efficiency source artifact failed validation.")
    value = json.loads(raw)
    if not isinstance(value, dict):
        raise ValueError("Efficiency source artifact must be an object.")
    return value, {
        "schema": value["schema"],
        "sha256": hashlib.sha256(raw).hexdigest(),
        "byteCount": len(raw),
    }


def _neutral_observations(payload: dict[str, Any]) -> list[dict[str, Any]]:
    observations = []
    for assessment in payload["assessments"]:
        efficiency = assessment["efficiencyObservations"]
        observations.append({
            "episodeID": assessment["episodeID"],
            "scenario": assessment["scenario"],
            "repetition": assessment["repetition"],
            "candidateID": "plain-markdown-scripted-reference-v1",
            "controlProfile": payload["controlProfile"],
            "executionKind": "scripted-reference",
            "modelExecuted": False,
            "modelID": None,
            "logicalRoleCount": assessment["traceCount"],
            "agentProcessCount": assessment["traceCount"],
            "taskOutcomePassed": assessment["dimensions"]["outcome"] == 100,
            "safetyPassed": assessment["safetyPassed"],
            "sourcePreserved": assessment["sourcePreserved"],
            "wallTimeMs": assessment["wallTimeMs"],
            "toolRoundTrips": {
                "count": efficiency["toolCallCount"],
                "failedCount": efficiency["failedToolCallCount"],
                "invalidCount": 0,
                "requestBytes": efficiency["requestByteCount"],
                "responseBytes": efficiency["responseByteCount"],
                "cumulativeToolTimeMs": round(
                    efficiency["toolDurationMicroseconds"] / 1_000,
                    3,
                ),
                "measurementBasis": "served-workspace-tool-boundary",
            },
            "modelUsage": {
                "calls": 0,
                "promptTokens": 0,
                "cachedInputTokens": 0,
                "completionTokens": 0,
                "reasoningTokens": 0,
                "reportedCostUSD": None,
            },
            "missingMeasurements": ["reported-cost"],
            "comparisonContract": _comparison_contract(payload, assessment),
        })
    return observations


def _run_observations(payload: dict[str, Any]) -> list[dict[str, Any]]:
    candidate = payload["candidate"]["id"]
    model = payload["execution"]["model"]
    observations = []
    for episode in payload["episodes"]:
        usage = episode["usage"]
        observations.append({
            "episodeID": episode["id"],
            "scenario": episode["scenario"],
            "repetition": episode["repetition"],
            "candidateID": candidate,
            "controlProfile": episode["controlProfile"],
            "executionKind": "real-model",
            "modelExecuted": True,
            "modelID": model,
            "logicalRoleCount": len(episode["logicalActors"]),
            "agentProcessCount": episode["agentProcessCount"],
            "taskOutcomePassed": episode["dimensions"]["outcome"] == 100,
            "safetyPassed": episode["safetyPassed"],
            "sourcePreserved": episode["sourcePreserved"],
            "wallTimeMs": episode["durationMs"],
            "toolRoundTrips": {
                "count": episode["commandCount"],
                "failedCount": None,
                "invalidCount": episode["invalidCommandCount"],
                "requestBytes": None,
                "responseBytes": None,
                "cumulativeToolTimeMs": None,
                "measurementBasis": "redacted-margin-command-summary",
            },
            "modelUsage": {
                "calls": usage["modelCalls"],
                "promptTokens": usage["promptTokens"],
                "cachedInputTokens": usage["cachedInputTokens"],
                "completionTokens": usage["completionTokens"],
                "reasoningTokens": usage["reasoningTokens"],
                "reportedCostUSD": usage["reportedCostUSD"],
            },
            "missingMeasurements": sorted([
                "failed-tool-round-trips",
                "tool-request-bytes",
                "tool-response-bytes",
                "cumulative-tool-time",
            ]),
            "comparisonContract": _comparison_contract(payload, episode),
        })
    return observations


def _neutral_run_observations(payload: dict[str, Any]) -> list[dict[str, Any]]:
    candidate = payload["candidate"]["id"]
    model = payload["execution"]["model"]
    return [
        {
            "episodeID": episode["id"],
            "scenario": episode["scenario"],
            "repetition": episode["repetition"],
            "candidateID": candidate,
            "controlProfile": episode["controlProfile"],
            "executionKind": "real-model",
            "modelExecuted": True,
            "modelID": model,
            "logicalRoleCount": len(episode["logicalActors"]),
            "agentProcessCount": episode["agentProcessCount"],
            "taskOutcomePassed": episode["dimensions"]["outcome"] == 100,
            "safetyPassed": episode["safetyPassed"],
            "sourcePreserved": episode["sourcePreserved"],
            "wallTimeMs": episode["durationMs"],
            "toolRoundTrips": dict(episode["toolRoundTrips"]),
            "modelUsage": {
                "calls": episode["usage"]["modelCalls"],
                "promptTokens": episode["usage"]["promptTokens"],
                "cachedInputTokens": episode["usage"]["cachedInputTokens"],
                "completionTokens": episode["usage"]["completionTokens"],
                "reasoningTokens": episode["usage"]["reasoningTokens"],
                "reportedCostUSD": episode["usage"]["reportedCostUSD"],
            },
            "missingMeasurements": [],
            "comparisonContract": _comparison_contract(payload, episode),
        }
        for episode in payload["episodes"]
    ]


def _sum_or_none(values: list[int | float | None]) -> int | float | None:
    return None if any(value is None for value in values) else sum(value for value in values if value is not None)


def _groups(observations: list[dict[str, Any]]) -> list[dict[str, Any]]:
    grouped: dict[tuple[str, str, str, str | None], list[dict[str, Any]]] = defaultdict(list)
    for observation in observations:
        grouped[(
            observation["candidateID"],
            observation["controlProfile"],
            observation["executionKind"],
            observation["modelID"],
        )].append(observation)
    results = []
    for key, values in sorted(grouped.items(), key=lambda item: tuple(str(part or "") for part in item[0])):
        candidate, profile, execution, model = key
        tool = [value["toolRoundTrips"] for value in values]
        usage = [value["modelUsage"] for value in values]
        results.append({
            "candidateID": candidate,
            "controlProfile": profile,
            "executionKind": execution,
            "modelID": model,
            "episodeCount": len(values),
            "taskOutcomePassCount": sum(value["taskOutcomePassed"] for value in values),
            "safetyPassCount": sum(value["safetyPassed"] for value in values),
            "sourcePreservedCount": sum(value["sourcePreserved"] for value in values),
            "meanWallTimeMs": round(sum(value["wallTimeMs"] for value in values) / len(values), 3),
            "totalToolRoundTrips": sum(value["count"] for value in tool),
            "totalFailedToolRoundTrips": _sum_or_none(
                [value["failedCount"] for value in tool]
            ),
            "totalInvalidToolRoundTrips": sum(value["invalidCount"] for value in tool),
            "totalRequestBytes": _sum_or_none([value["requestBytes"] for value in tool]),
            "totalResponseBytes": _sum_or_none([value["responseBytes"] for value in tool]),
            "totalCumulativeToolTimeMs": _sum_or_none(
                [value["cumulativeToolTimeMs"] for value in tool]
            ),
            "totalModelCalls": sum(value["calls"] for value in usage),
            "totalPromptTokens": sum(value["promptTokens"] for value in usage),
            "totalCachedInputTokens": sum(value["cachedInputTokens"] for value in usage),
            "totalCompletionTokens": sum(value["completionTokens"] for value in usage),
            "totalReasoningTokens": sum(value["reasoningTokens"] for value in usage),
            "totalReportedCostUSD": _sum_or_none([value["reportedCostUSD"] for value in usage]),
        })
    return results


def _matched_episodes(
    episode_groups: dict[str, list[dict[str, Any]]],
) -> list[dict[str, Any]]:
    results = []
    for episode_id, values in sorted(episode_groups.items()):
        contract_status, differences, missing = _contract_result(values)
        results.append({
            "episodeID": episode_id,
            "observationCount": len(values),
            "allOutcomePassed": all(value["taskOutcomePassed"] for value in values),
            "allSafetyPassed": all(value["safetyPassed"] for value in values),
            "comparisonStatus": (
                "resource-vector-only"
                if len(values) > 1 and all(value["modelExecuted"] for value in values)
                else "mixed-execution-kind"
                if len(values) > 1
                else "unpaired"
            ),
            "contractStatus": contract_status,
            "contractDifferences": differences,
            "contractMissingFields": missing,
            "winner": None,
        })
    return results


def build_efficiency_report(paths: list[Path] | tuple[Path, ...]) -> dict[str, Any]:
    if not 1 <= len(paths) <= MAX_SOURCE_COUNT:
        raise ValueError(
            f"Efficiency report requires between one and {MAX_SOURCE_COUNT} artifacts."
        )
    observations: list[dict[str, Any]] = []
    source_schemas: list[str] = []
    sources: list[dict[str, Any]] = []
    source_digests: set[str] = set()
    total_source_bytes = 0
    for path in paths:
        payload, source = _read(path)
        total_source_bytes += source["byteCount"]
        if total_source_bytes > MAX_TOTAL_SOURCE_BYTES:
            raise ValueError("Efficiency sources exceed the aggregate input bound.")
        if source["sha256"] in source_digests:
            raise ValueError("Efficiency sources must be unique artifacts.")
        source_digests.add(source["sha256"])
        schema = payload.get("schema")
        if schema == NEUTRAL_PREFLIGHT_SCHEMA:
            projected = _neutral_observations(payload)
        elif schema == NEUTRAL_RUN_SCHEMA:
            projected = _neutral_run_observations(payload)
        elif schema == RUN_SCHEMA:
            projected = _run_observations(payload)
        else:
            raise ValueError("Efficiency report supports served-neutral receipts and redacted runs.")
        observations.extend(projected)
        source_schemas.append(schema)
        sources.append(source)
    identity_keys = [
        (
            value["episodeID"],
            value["candidateID"],
            value["controlProfile"],
            value["executionKind"],
            value["modelID"],
        )
        for value in observations
    ]
    if len(identity_keys) != len(set(identity_keys)):
        raise ValueError("Efficiency sources contain duplicate observations.")
    observations.sort(key=lambda value: (
        value["episodeID"],
        value["controlProfile"],
        value["candidateID"],
    ))
    sources.sort(key=lambda value: (value["schema"], value["sha256"]))
    episode_groups: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for observation in observations:
        episode_groups[observation["episodeID"]].append(observation)
    matched = _matched_episodes(episode_groups)
    report = {
        "schema": EFFICIENCY_REPORT_SCHEMA,
        "sourceSchemas": sorted(set(source_schemas)),
        "sources": sources,
        "observationCount": len(observations),
        "episodeCount": len(episode_groups),
        "scalarRankingPermitted": False,
        "rules": list(EFFICIENCY_RULES),
        "observations": observations,
        "groups": _groups(observations),
        "matchedEpisodes": matched,
    }
    rendered = canonical_json(report)
    if len(rendered) > MAX_ARTIFACT_BYTES:
        raise ValueError("Efficiency report exceeds the publication bound.")
    return report
