"""Matched topology plans and multi-metric collaboration-crossover reports."""

from __future__ import annotations

import hashlib
import json
import math
import random
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable

from .challenges import DEMAND_AXES, challenge_catalog, challenge_profile
from .controls import planned_topology, require_implemented_profile
from .schema import EpisodeResult, canonical_json, sha256_bytes
from .scenarios import SCENARIO_IDS, generate_episode
from .validation import MAX_ARTIFACT_BYTES, validate_bytes


CROSSOVER_PLAN_SCHEMA = "urn:marginbench:crossover-plan:v1"
CROSSOVER_REPORT_SCHEMA = "urn:marginbench:crossover-report:v1"
ROLE_SEPARATED_PROFILE = "role-separated-margin-only-v1"
CONTINUING_PROFILE = "single-agent-margin-v1"
MINIMUM_DIRECTIONAL_PAIRS = 20
QUALITY_TOLERANCE = 2.0
MEANINGFUL_SPEED_RATIO = 1.20
CROSSOVER_BENCHMARK_VERSION = "0.2.0-crossover"


@dataclass(frozen=True)
class CrossoverMeasurement:
    episode_id: str
    scenario: str
    repetition: int
    fingerprint: str
    candidate_id: str
    control_profile: str
    score: float
    duration_ms: float
    command_count: int
    invalid_command_count: int
    safety_passed: bool
    source_preserved: bool
    margin_sha256: str
    dimensions: dict[str, float]
    checks: dict[str, bool]
    model_calls: int = 0
    prompt_tokens: int = 0
    completion_tokens: int = 0
    cached_input_tokens: int = 0
    reasoning_tokens: int = 0
    reported_cost_usd: float = 0.0

    def __post_init__(self) -> None:
        if self.scenario not in SCENARIO_IDS:
            raise ValueError("Crossover measurement names an unknown scenario.")
        if self.control_profile not in {ROLE_SEPARATED_PROFILE, CONTINUING_PROFILE}:
            raise ValueError("Crossover measurement uses an unsupported topology profile.")
        _candidate_id(self.candidate_id)
        if (
            self.repetition < 0
            or self.episode_id != f"{self.scenario}:{self.repetition}:{self.fingerprint[:12]}"
            or len(self.fingerprint) != 64
            or any(character not in "0123456789abcdef" for character in self.fingerprint)
        ):
            raise ValueError("Crossover measurement has invalid case identity.")
        if (
            not isinstance(self.score, (int, float))
            or isinstance(self.score, bool)
            or not math.isfinite(self.score)
            or not 0 <= self.score <= 100
            or not isinstance(self.duration_ms, (int, float))
            or isinstance(self.duration_ms, bool)
            or not math.isfinite(self.duration_ms)
            or self.duration_ms < 0
        ):
            raise ValueError("Crossover measurement score or duration is invalid.")
        for value in (
            self.command_count,
            self.invalid_command_count,
            self.model_calls,
            self.prompt_tokens,
            self.completion_tokens,
            self.cached_input_tokens,
            self.reasoning_tokens,
        ):
            if not isinstance(value, int) or isinstance(value, bool) or value < 0:
                raise ValueError("Crossover counts must be nonnegative integers.")
        if self.invalid_command_count > self.command_count:
            raise ValueError("Invalid command count exceeds the command count.")
        if not isinstance(self.safety_passed, bool) or not isinstance(self.source_preserved, bool):
            raise ValueError("Crossover safety fields must be boolean.")
        if not math.isfinite(self.reported_cost_usd) or self.reported_cost_usd < 0:
            raise ValueError("Crossover reported cost must be finite and nonnegative.")
        if (
            len(self.margin_sha256) != 64
            or any(character not in "0123456789abcdef" for character in self.margin_sha256)
        ):
            raise ValueError("Crossover Margin digest must be a SHA-256 value.")
        if not self.dimensions or any(
            not isinstance(name, str)
            or not isinstance(value, (int, float))
            or isinstance(value, bool)
            or not math.isfinite(value)
            or not 0 <= value <= 100
            for name, value in self.dimensions.items()
        ):
            raise ValueError("Crossover dimensions must contain bounded numeric scores.")
        if not self.checks or any(
            not isinstance(name, str) or not isinstance(value, bool)
            for name, value in self.checks.items()
        ):
            raise ValueError("Crossover checks must contain boolean outcomes.")

    @classmethod
    def from_result(
        cls,
        result: EpisodeResult,
        *,
        scenario: str,
        repetition: int,
        fingerprint: str,
        control_profile: str,
    ) -> "CrossoverMeasurement":
        return cls(
            episode_id=result.episode_id,
            scenario=scenario,
            repetition=repetition,
            fingerprint=fingerprint,
            candidate_id=result.candidate_id,
            control_profile=control_profile,
            score=result.score,
            duration_ms=result.duration_ms,
            command_count=result.command_count,
            invalid_command_count=result.invalid_command_count,
            safety_passed=result.safety_passed,
            source_preserved=result.source_preserved,
            margin_sha256=result.margin_sha256,
            dimensions=dict(result.dimensions),
            checks=dict(result.checks),
        )


@dataclass(frozen=True)
class CrossoverEvidence:
    measurements: tuple[CrossoverMeasurement, ...]
    experiment_contract: dict[str, Any]


def _candidate_id(value: str) -> str:
    if not value or len(value.encode("utf-8")) > 256:
        raise ValueError("Candidate ID must contain between 1 and 256 UTF-8 bytes.")
    return value


def reference_experiment_contract(
    candidate: str,
    margin_sha256: str,
    roles: Iterable[str] = ("author", "reviewer"),
    *,
    task_set: str = "public-development-v1",
    development_cases: bool = True,
) -> dict[str, Any]:
    """Declare the fixed, model-free policy used only for harness mechanics."""
    _candidate_id(candidate)
    if (
        len(margin_sha256) != 64
        or any(character not in "0123456789abcdef" for character in margin_sha256)
    ):
        raise ValueError("Reference experiment contract needs a Margin SHA-256 value.")
    declared_roles = sorted(set(roles))
    if not declared_roles or any(not role for role in declared_roles):
        raise ValueError("Reference experiment contract needs at least one logical role.")
    expected_task_set = (
        "public-development-v1" if development_cases else "private-holdout-v1"
    )
    if task_set != expected_task_set:
        raise ValueError("Reference experiment contract case partition is inconsistent.")
    return {
        "schema": "urn:marginbench:experiment-contract:v1",
        "mode": "model-free-reference",
        "candidate": {
            "id": candidate,
            "marginSha256": margin_sha256,
        },
        "benchmark": {
            "name": "MarginBench",
            "version": CROSSOVER_BENCHMARK_VERSION,
            "taskSet": task_set,
            "developmentCases": development_cases,
        },
        "execution": {
            "provider": "none",
            "model": "deterministic-reference-policy",
            "adapter": "local-reference-runner",
            "harness": "one-real-margin-gateway-per-logical-role",
            "runtime": "local-process",
            "roles": declared_roles,
            "limits": {},
            "retryPolicy": "No model or provider retry exists.",
        },
        "costPolicy": {
            "currency": "USD",
            "hardAdmissionCap": 0.0,
            "liveBudgetCap": 0.0,
            "pricing": {},
        },
    }


def build_crossover_plan(
    *,
    candidate: str,
    scenarios: list[str],
    repetitions: int,
    key: bytes,
    development_cases: bool,
) -> dict[str, Any]:
    """Freeze identical cases and counterbalanced topology order without running models."""
    candidate = _candidate_id(candidate)
    if not 1 <= repetitions <= 100:
        raise ValueError("Crossover repetitions must be between 1 and 100.")
    if not scenarios or len(scenarios) != len(set(scenarios)):
        raise ValueError("Crossover scenarios must be a nonempty unique list.")
    if any(value not in SCENARIO_IDS for value in scenarios):
        raise ValueError("Crossover plan contains an unknown scenario.")
    for profile in (ROLE_SEPARATED_PROFILE, CONTINUING_PROFILE):
        require_implemented_profile(profile)
    episodes = [
        generate_episode(scenario, key, repetition)
        for repetition in range(repetitions)
        for scenario in scenarios
    ]
    catalog = challenge_catalog()
    catalog_sha = sha256_bytes(canonical_json(catalog))
    order_salt = f"{candidate}\0{catalog_sha}".encode("utf-8")
    order_by_episode = {}
    for scenario_index, scenario in enumerate(scenarios):
        family_cases = sorted(
            (episode for episode in episodes if episode.scenario_id == scenario),
            key=lambda value: hashlib.sha256(
                order_salt + bytes.fromhex(value.fingerprint)
            ).digest(),
        )
        for index, episode in enumerate(family_cases):
            forward = (index + scenario_index) % 2 == 0
            order_by_episode[episode.public_id] = (
                [ROLE_SEPARATED_PROFILE, CONTINUING_PROFILE]
                if forward
                else [CONTINUING_PROFILE, ROLE_SEPARATED_PROFILE]
            )
    logical_role_runs = 0
    process_counts = {ROLE_SEPARATED_PROFILE: 0, CONTINUING_PROFILE: 0}
    public_episodes = []
    execution_episodes = sorted(
        episodes,
        key=lambda value: hashlib.sha256(
            order_salt + b"\0execution-order\0" + bytes.fromhex(value.fingerprint)
        ).digest(),
    )
    for episode in execution_episodes:
        roles = [role.seat for role in episode.roles]
        logical_role_runs += len(roles)
        for profile in process_counts:
            process_counts[profile] += planned_topology(profile, roles)["agentProcessCount"]
        challenge = challenge_profile(episode.scenario_id)
        public_episodes.append({
            "id": episode.public_id,
            "scenario": episode.scenario_id,
            "repetition": episode.repetition,
            "fingerprint": episode.fingerprint,
            "roles": roles,
            "family": challenge.family,
            "hypothesis": challenge.hypothesis,
            "demand": dict(challenge.demand),
            "profileOrder": order_by_episode[episode.public_id],
        })
    return {
        "schema": CROSSOVER_PLAN_SCHEMA,
        "benchmarkVersion": CROSSOVER_BENCHMARK_VERSION,
        "taskSet": "public-development-v1" if development_cases else "private-holdout-v1",
        "developmentCases": development_cases,
        "candidateID": candidate,
        "challengeCatalogSha256": catalog_sha,
        "profiles": [ROLE_SEPARATED_PROFILE, CONTINUING_PROFILE],
        "scenarioIDs": list(scenarios),
        "repetitions": repetitions,
        "episodeCount": len(public_episodes),
        "logicalRoleRunsPerProfile": logical_role_runs,
        "agentProcessesPerProfile": process_counts,
        "minimumPairsForDirectionalClaim": MINIMUM_DIRECTIONAL_PAIRS,
        "sampleSizeSufficient": len(public_episodes) >= MINIMUM_DIRECTIONAL_PAIRS,
        "episodes": public_episodes,
        "rules": {
            "qualityTolerancePoints": QUALITY_TOLERANCE,
            "meaningfulSpeedRatio": MEANINGFUL_SPEED_RATIO,
            "budgetUnit": "logical-role",
            "singleAggregateScore": False,
        },
    }


def _percentile(values: list[float], fraction: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    position = min(len(ordered) - 1, max(0, round((len(ordered) - 1) * fraction)))
    return ordered[position]


def _bootstrap_interval(values: list[float], *, samples: int = 2_000) -> list[float]:
    if not values:
        return [0.0, 0.0]
    rng = random.Random(0)
    means = []
    for _ in range(samples):
        draw = [values[rng.randrange(len(values))] for _ in values]
        means.append(sum(draw) / len(draw))
    return [round(_percentile(means, 0.025), 6), round(_percentile(means, 0.975), 6)]


def _geometric_mean(values: list[float]) -> float:
    return math.exp(sum(math.log(max(value, 1e-12)) for value in values) / len(values))


def _bootstrap_speed_interval(values: list[float], *, samples: int = 2_000) -> list[float]:
    if not values:
        return [1.0, 1.0]
    rng = random.Random(1)
    means = []
    for _ in range(samples):
        draw = [values[rng.randrange(len(values))] for _ in values]
        means.append(_geometric_mean(draw))
    return [round(_percentile(means, 0.025), 6), round(_percentile(means, 0.975), 6)]


def _descriptive_leader(score_delta: float, speed_ratio: float, safe: bool) -> str:
    if not safe:
        return "unsafe"
    if score_delta > QUALITY_TOLERANCE:
        return "role-separated"
    if score_delta < -QUALITY_TOLERANCE:
        return "continuing"
    if speed_ratio >= MEANINGFUL_SPEED_RATIO:
        return "role-separated"
    if speed_ratio <= 1 / MEANINGFUL_SPEED_RATIO:
        return "continuing"
    return "inconclusive"


def _directional_conclusion(
    *,
    descriptive: str,
    safe: bool,
    count: int,
    mean_score: float,
    mean_speed: float,
    score_interval: list[float],
    speed_interval: list[float],
) -> str:
    if not safe:
        return "unsafe"
    if count < MINIMUM_DIRECTIONAL_PAIRS:
        return "insufficient-data"
    if descriptive == "role-separated":
        if mean_score > QUALITY_TOLERANCE:
            return (
                "role-separated"
                if score_interval[0] > QUALITY_TOLERANCE
                else "inconclusive"
            )
        quality_tied = (
            score_interval[0] >= -QUALITY_TOLERANCE
            and score_interval[1] <= QUALITY_TOLERANCE
        )
        return (
            "role-separated"
            if quality_tied
            and mean_speed >= MEANINGFUL_SPEED_RATIO
            and speed_interval[0] >= MEANINGFUL_SPEED_RATIO
            else "inconclusive"
        )
    if descriptive == "continuing":
        if mean_score < -QUALITY_TOLERANCE:
            return (
                "continuing"
                if score_interval[1] < -QUALITY_TOLERANCE
                else "inconclusive"
            )
        quality_tied = (
            score_interval[0] >= -QUALITY_TOLERANCE
            and score_interval[1] <= QUALITY_TOLERANCE
        )
        maximum = 1 / MEANINGFUL_SPEED_RATIO
        return (
            "continuing"
            if quality_tied and mean_speed <= maximum and speed_interval[1] <= maximum
            else "inconclusive"
        )
    return "inconclusive"


def _measurement(value: CrossoverMeasurement) -> dict[str, Any]:
    return {
        "candidateID": value.candidate_id,
        "score": value.score,
        "durationMs": value.duration_ms,
        "commandCount": value.command_count,
        "invalidCommandCount": value.invalid_command_count,
        "safetyPassed": value.safety_passed,
        "sourcePreserved": value.source_preserved,
        "dimensions": dict(sorted(value.dimensions.items())),
        "checks": dict(sorted(value.checks.items())),
        "usage": {
            "modelCalls": value.model_calls,
            "promptTokens": value.prompt_tokens,
            "completionTokens": value.completion_tokens,
            "cachedInputTokens": value.cached_input_tokens,
            "reasoningTokens": value.reasoning_tokens,
            "reportedCostUSD": value.reported_cost_usd,
        },
    }


def _aggregate(label: str, observations: list[dict[str, Any]]) -> dict[str, Any]:
    score_deltas = [float(value["delta"]["score"]) for value in observations]
    duration_deltas = [float(value["delta"]["durationMs"]) for value in observations]
    speed_ratios = [float(value["delta"]["speedRatio"]) for value in observations]
    safe = all(value["pairSafe"] for value in observations)
    mean_score = sum(score_deltas) / len(score_deltas) if score_deltas else 0.0
    mean_speed = _geometric_mean(speed_ratios) if speed_ratios else 1.0
    count = len(observations)
    descriptive = _descriptive_leader(mean_score, mean_speed, safe)
    score_interval = _bootstrap_interval(score_deltas)
    speed_interval = _bootstrap_speed_interval(speed_ratios)
    role_check_names = sorted({
        check
        for value in observations
        for check in value["roleSeparated"]["checks"]
    })
    continuing_check_names = sorted({
        check
        for value in observations
        for check in value["continuing"]["checks"]
    })
    return {
        "label": label,
        "pairCount": count,
        "sampleSizeSufficient": count >= MINIMUM_DIRECTIONAL_PAIRS,
        "pairSafe": safe,
        "meanScoreDelta": round(mean_score, 6),
        "scoreDelta95CI": score_interval,
        "meanDurationMsDelta": round(
            sum(duration_deltas) / count if count else 0.0,
            6,
        ),
        "meanSpeedRatio": round(mean_speed, 6),
        "speedRatio95CI": speed_interval,
        "meanCommandCountDelta": round(
            sum(value["delta"]["commandCount"] for value in observations) / count
            if count else 0.0,
            6,
        ),
        "meanInvalidCommandCountDelta": round(
            sum(value["delta"]["invalidCommandCount"] for value in observations) / count
            if count else 0.0,
            6,
        ),
        "meanModelCallsDelta": round(
            sum(value["delta"]["modelCalls"] for value in observations) / count
            if count else 0.0,
            6,
        ),
        "meanPromptTokensDelta": round(
            sum(value["delta"]["promptTokens"] for value in observations) / count
            if count else 0.0,
            6,
        ),
        "meanCompletionTokensDelta": round(
            sum(value["delta"]["completionTokens"] for value in observations) / count
            if count else 0.0,
            6,
        ),
        "meanCachedInputTokensDelta": round(
            sum(value["delta"]["cachedInputTokens"] for value in observations) / count
            if count else 0.0,
            6,
        ),
        "meanReasoningTokensDelta": round(
            sum(value["delta"]["reasoningTokens"] for value in observations) / count
            if count else 0.0,
            6,
        ),
        "meanReportedCostUSDDelta": round(
            sum(value["delta"]["reportedCostUSD"] for value in observations) / count
            if count else 0.0,
            6,
        ),
        "meanDimensionDeltas": {
            dimension: round(
                sum(value["dimensionDeltas"][dimension] for value in observations) / count,
                6,
            )
            for dimension in sorted(observations[0]["dimensionDeltas"])
        },
        "roleSeparatedFailedCheckCounts": {
            check: sum(
                value["roleSeparated"]["checks"].get(check) is False
                for value in observations
            )
            for check in role_check_names
        },
        "continuingFailedCheckCounts": {
            check: sum(
                value["continuing"]["checks"].get(check) is False
                for value in observations
            )
            for check in continuing_check_names
        },
        "leaderCounts": {
            leader: sum(value["descriptiveLeader"] == leader for value in observations)
            for leader in ("role-separated", "continuing", "inconclusive", "unsafe")
        },
        "descriptiveLeader": descriptive,
        "directionalConclusion": _directional_conclusion(
            descriptive=descriptive,
            safe=safe,
            count=count,
            mean_score=mean_score,
            mean_speed=mean_speed,
            score_interval=score_interval,
            speed_interval=speed_interval,
        ),
    }


def analyze_crossover(
    role_separated: Iterable[CrossoverMeasurement],
    continuing: Iterable[CrossoverMeasurement],
    *,
    analysis_mode: str,
    plan: dict[str, Any],
    experiment_contract: dict[str, Any],
) -> dict[str, Any]:
    """Compare identical valid cases while retaining each outcome and cost dimension."""
    if analysis_mode not in {"model-free-reference", "measured-model"}:
        raise ValueError("Unknown crossover analysis mode.")
    if plan.get("schema") != CROSSOVER_PLAN_SCHEMA:
        raise ValueError("Crossover analysis requires a declared crossover plan.")
    if (
        plan.get("benchmarkVersion") != CROSSOVER_BENCHMARK_VERSION
        or plan.get("minimumPairsForDirectionalClaim") != MINIMUM_DIRECTIONAL_PAIRS
        or plan.get("rules") != {
            "qualityTolerancePoints": QUALITY_TOLERANCE,
            "meaningfulSpeedRatio": MEANINGFUL_SPEED_RATIO,
            "budgetUnit": "logical-role",
            "singleAggregateScore": False,
        }
    ):
        raise ValueError("Crossover plan uses a different analysis policy.")
    if experiment_contract.get("schema") != "urn:marginbench:experiment-contract:v1":
        raise ValueError("Crossover analysis requires a declared experiment contract.")
    expected_contract_mode = (
        "model-free-reference" if analysis_mode == "model-free-reference" else "measured-model"
    )
    if experiment_contract.get("mode") != expected_contract_mode:
        raise ValueError("Crossover experiment contract mode does not match its analysis.")
    left_values = list(role_separated)
    right_values = list(continuing)
    if not left_values or not right_values:
        raise ValueError("Crossover analysis requires both topology result sets.")
    left = {value.episode_id: value for value in left_values}
    right = {value.episode_id: value for value in right_values}
    if len(left) != len(left_values) or len(right) != len(right_values):
        raise ValueError("Crossover analysis rejects duplicate episode IDs.")
    if set(left) != set(right):
        raise ValueError("Crossover analysis requires identical episode IDs.")
    if {value.control_profile for value in left_values} != {ROLE_SEPARATED_PROFILE}:
        raise ValueError("The first crossover input must be role-separated.")
    if {value.control_profile for value in right_values} != {CONTINUING_PROFILE}:
        raise ValueError("The second crossover input must be continuing-agent.")
    builds = {value.margin_sha256 for value in left_values + right_values}
    if len(builds) != 1:
        raise ValueError("Crossover inputs must use the same Margin build.")
    candidates = {value.candidate_id for value in left_values + right_values}
    if len(candidates) != 1:
        raise ValueError("Crossover inputs must use the same candidate configuration.")
    if candidates != {plan.get("candidateID")}:
        raise ValueError("Crossover measurements do not match the planned candidate.")
    contract_candidate = experiment_contract.get("candidate")
    if not isinstance(contract_candidate, dict) or contract_candidate.get("id") not in candidates:
        raise ValueError("Crossover experiment contract names a different candidate.")
    if contract_candidate.get("marginSha256") not in builds:
        raise ValueError("Crossover experiment contract names a different Margin build.")
    contract_benchmark = experiment_contract.get("benchmark")
    if not isinstance(contract_benchmark, dict):
        raise ValueError("Crossover experiment contract has no benchmark declaration.")
    if (
        contract_benchmark.get("name") != "MarginBench"
        or contract_benchmark.get("taskSet") != plan.get("taskSet")
        or contract_benchmark.get("developmentCases") != plan.get("developmentCases")
    ):
        raise ValueError("Crossover experiment contract uses a different case partition.")
    if plan.get("profiles") != [ROLE_SEPARATED_PROFILE, CONTINUING_PROFILE]:
        raise ValueError("Crossover plan does not declare the required topology pair.")
    planned = {
        value["id"]: value
        for value in plan.get("episodes", [])
        if isinstance(value, dict) and isinstance(value.get("id"), str)
    }
    if len(planned) != len(plan.get("episodes", [])) or set(planned) != set(left):
        raise ValueError("Crossover measurements do not exactly cover the planned cases.")
    observations = []
    for identifier in sorted(left):
        separated = left[identifier]
        continued = right[identifier]
        if (
            separated.scenario != continued.scenario
            or separated.repetition != continued.repetition
            or separated.fingerprint != continued.fingerprint
        ):
            raise ValueError("Crossover pair identity or fingerprint differs.")
        planned_case = planned[identifier]
        if (
            planned_case.get("scenario") != separated.scenario
            or planned_case.get("repetition") != separated.repetition
            or planned_case.get("fingerprint") != separated.fingerprint
        ):
            raise ValueError("Crossover measurement differs from its planned case.")
        if separated.dimensions.keys() != continued.dimensions.keys():
            raise ValueError("Crossover pair score dimensions differ.")
        if separated.checks.keys() != continued.checks.keys():
            raise ValueError("Crossover pair outcome checks differ.")
        challenge = challenge_profile(separated.scenario)
        speed_ratio = (continued.duration_ms + 1e-9) / (separated.duration_ms + 1e-9)
        score_delta = separated.score - continued.score
        pair_safe = (
            separated.safety_passed
            and separated.source_preserved
            and continued.safety_passed
            and continued.source_preserved
        )
        observation = {
            "episodeID": identifier,
            "scenario": separated.scenario,
            "repetition": separated.repetition,
            "fingerprint": separated.fingerprint,
            "family": challenge.family,
            "hypothesis": challenge.hypothesis,
            "demand": dict(challenge.demand),
            "pairSafe": pair_safe,
            "roleSeparated": _measurement(separated),
            "continuing": _measurement(continued),
            "delta": {
                "score": round(score_delta, 6),
                "durationMs": round(separated.duration_ms - continued.duration_ms, 6),
                "speedRatio": round(speed_ratio, 6),
                "commandCount": separated.command_count - continued.command_count,
                "invalidCommandCount": (
                    separated.invalid_command_count - continued.invalid_command_count
                ),
                "modelCalls": separated.model_calls - continued.model_calls,
                "promptTokens": separated.prompt_tokens - continued.prompt_tokens,
                "completionTokens": separated.completion_tokens - continued.completion_tokens,
                "cachedInputTokens": (
                    separated.cached_input_tokens - continued.cached_input_tokens
                ),
                "reasoningTokens": separated.reasoning_tokens - continued.reasoning_tokens,
                "reportedCostUSD": round(
                    separated.reported_cost_usd - continued.reported_cost_usd,
                    6,
                ),
            },
            "dimensionDeltas": {
                dimension: round(
                    separated.dimensions[dimension] - continued.dimensions[dimension],
                    6,
                )
                for dimension in sorted(separated.dimensions)
            },
            "descriptiveLeader": _descriptive_leader(score_delta, speed_ratio, pair_safe),
        }
        observations.append(observation)
    families = []
    for family in sorted({value["family"] for value in observations}):
        families.append(_aggregate(
            family,
            [value for value in observations if value["family"] == family],
        ))
    axes = []
    for axis in DEMAND_AXES:
        for level in sorted({value["demand"][axis] for value in observations}):
            aggregate = _aggregate(
                f"{axis}:{level}",
                [value for value in observations if value["demand"][axis] == level],
            )
            aggregate.update({"axis": axis, "level": level})
            axes.append(aggregate)
    catalog = challenge_catalog()
    catalog_sha = sha256_bytes(canonical_json(catalog))
    if plan.get("challengeCatalogSha256") != catalog_sha:
        raise ValueError("Crossover plan uses a different challenge catalog.")
    normalized_contract = json.loads(canonical_json(experiment_contract))
    return {
        "schema": CROSSOVER_REPORT_SCHEMA,
        "benchmarkVersion": CROSSOVER_BENCHMARK_VERSION,
        "analysisMode": analysis_mode,
        "challengeCatalogSha256": catalog_sha,
        "plan": json.loads(canonical_json(plan)),
        "experimentContract": normalized_contract,
        "experimentContractSha256": sha256_bytes(canonical_json(normalized_contract)),
        "profiles": {
            "roleSeparated": ROLE_SEPARATED_PROFILE,
            "continuing": CONTINUING_PROFILE,
        },
        "marginSha256": next(iter(builds)),
        "episodeCount": len(observations),
        "minimumPairsForDirectionalClaim": MINIMUM_DIRECTIONAL_PAIRS,
        "sampleSizeSufficient": len(observations) >= MINIMUM_DIRECTIONAL_PAIRS,
        "allPairsSafe": all(value["pairSafe"] for value in observations),
        "thresholds": {
            "qualityTolerancePoints": QUALITY_TOLERANCE,
            "meaningfulSpeedRatio": MEANINGFUL_SPEED_RATIO,
        },
        "overall": _aggregate("all", observations),
        "families": families,
        "axes": axes,
        "observations": observations,
        "rules": [
            "Positive deltas are role-separated minus continuing-agent.",
            "Speed ratio is continuing duration divided by role-separated duration.",
            "A descriptive leader is not a directional conclusion without enough safe pairs.",
            "Quality, safety, time, usage, cost, and coordination remain separate measures.",
            "Model-free reference timing measures harness mechanics, not model capability.",
        ],
    }


def _validated_json(path: Path) -> tuple[dict[str, Any], dict[str, Any]]:
    try:
        with path.expanduser().open("rb") as handle:
            raw = handle.read(MAX_ARTIFACT_BYTES + 1)
    except OSError as error:
        raise ValueError("Crossover report input could not be read.") from error
    receipt = validate_bytes(raw)
    if not receipt["valid"]:
        raise ValueError("Crossover input is not a valid bounded artifact.")
    return json.loads(raw), receipt


def load_crossover_plan(path: Path) -> dict[str, Any]:
    """Read and validate one frozen plan snapshot without a validation race."""
    value, receipt = _validated_json(path)
    if receipt["artifactSchema"] != CROSSOVER_PLAN_SCHEMA:
        raise ValueError("Crossover report requires a valid crossover plan.")
    return value


def _load_json(path: Path) -> dict[str, Any]:
    value, receipt = _validated_json(path)
    if receipt["artifactSchema"] != "urn:marginbench:run:v1":
        raise ValueError("Crossover report input is not a valid redacted run artifact.")
    if value["status"] not in {"completed"}:
        raise ValueError("Crossover report rejects infrastructure-invalid runs.")
    return value


def _run_experiment_contract(value: dict[str, Any]) -> dict[str, Any]:
    execution = value["execution"]
    if execution.get("priorInfrastructureAttempts") != 0:
        raise ValueError(
            "Crossover evidence cannot include recovered infrastructure attempts under v1 policy."
        )
    benchmark = value["benchmark"]
    if not isinstance(benchmark.get("implementationSha256"), str):
        raise ValueError("Crossover evidence requires a benchmark implementation digest.")
    cost = value["cost"]
    basis = dict(cost["boundBasis"])
    basis.pop("modelCallsPerAgentAtMost", None)
    live_budget = cost.get("liveBudget") or {}
    return {
        "schema": "urn:marginbench:experiment-contract:v1",
        "mode": "measured-model",
        "candidate": dict(value["candidate"]),
        "benchmark": dict(benchmark),
        "track": value["track"],
        "execution": {
            key: execution[key]
            for key in (
                "provider",
                "model",
                "adapter",
                "harness",
                "runtime",
                "roles",
                "limits",
                "retryPolicy",
            )
        },
        "costPolicy": {
            "currency": cost["currency"],
            "hardAdmissionCap": cost["hardAdmissionCap"],
            "liveBudgetCap": cost.get("liveBudgetCap"),
            "pricing": basis,
            "liveBudgetPolicy": live_budget.get("policy"),
        },
    }


def load_crossover_evidence(path: Path) -> CrossoverEvidence:
    """Load one completed run and its normalized, topology-neutral conditions."""
    value = _load_json(path)
    candidate = value["candidate"]["id"]
    manifest_profile = value["execution"]["controlProfile"]
    measurements = []
    for episode in value["episodes"]:
        identifier = episode.get("id", episode.get("episodeID"))
        scenario = episode.get("scenario") or str(identifier).split(":", 1)[0]
        profile = episode.get("controlProfile") or manifest_profile
        usage = episode.get("usage") or {}
        measurements.append(CrossoverMeasurement(
            episode_id=identifier,
            scenario=scenario,
            repetition=int(episode["repetition"]),
            fingerprint=episode["fingerprint"],
            candidate_id=candidate,
            control_profile=profile,
            score=float(episode["score"]),
            duration_ms=float(episode["durationMs"]),
            command_count=int(episode["commandCount"]),
            invalid_command_count=int(episode["invalidCommandCount"]),
            safety_passed=bool(episode["safetyPassed"]),
            source_preserved=bool(episode["sourcePreserved"]),
            margin_sha256=episode["marginSha256"],
            dimensions={str(key): float(item) for key, item in episode["dimensions"].items()},
            checks={str(key): bool(item) for key, item in episode["checks"].items()},
            model_calls=int(usage.get("modelCalls", 0)),
            prompt_tokens=int(usage.get("promptTokens", 0)),
            completion_tokens=int(usage.get("completionTokens", 0)),
            cached_input_tokens=int(usage.get("cachedInputTokens", 0)),
            reasoning_tokens=int(usage.get("reasoningTokens", 0)),
            reported_cost_usd=float(usage.get("reportedCostUSD", 0)),
        ))
    return CrossoverEvidence(
        measurements=tuple(measurements),
        experiment_contract=_run_experiment_contract(value),
    )


def load_crossover_evidence_set(paths: Iterable[Path]) -> CrossoverEvidence:
    """Combine separately validated cells that share one experiment contract."""
    values = [load_crossover_evidence(path) for path in paths]
    if not values:
        raise ValueError("Crossover evidence needs at least one completed run artifact.")

    # Logical roles are scenario-defined: for example, a human-to-agent relay has
    # only a reviewer model seat while a specialist handoff has author and reviewer
    # seats.  They are therefore not a global execution setting.  Compare every
    # genuinely fixed condition while merging the declared role vocabulary for the
    # combined report.
    def fixed_contract(contract: dict[str, Any]) -> bytes:
        normalized = json.loads(canonical_json(contract))
        normalized["execution"].pop("roles", None)
        return canonical_json(normalized)

    contract = fixed_contract(values[0].experiment_contract)
    if any(fixed_contract(value.experiment_contract) != contract for value in values[1:]):
        raise ValueError(
            "Crossover runs differ in candidate, model, limits, runtime, retry, or cost policy."
        )
    merged_contract = json.loads(canonical_json(values[0].experiment_contract))
    merged_contract["execution"]["roles"] = sorted({
        role
        for value in values
        for role in value.experiment_contract["execution"].get("roles", [])
    })
    measurements = tuple(
        measurement
        for value in values
        for measurement in value.measurements
    )
    identifiers = [value.episode_id for value in measurements]
    if len(identifiers) != len(set(identifiers)):
        raise ValueError("Crossover evidence rejects duplicate episode IDs across runs.")
    return CrossoverEvidence(
        measurements=measurements,
        experiment_contract=merged_contract,
    )


def load_crossover_measurements(path: Path) -> list[CrossoverMeasurement]:
    """Compatibility projection for callers that need only measured episodes."""
    return list(load_crossover_evidence(path).measurements)
