"""Provider-neutral paired study plans for reproducible candidate comparisons."""

from __future__ import annotations

import hashlib
from typing import Any

from .controls import DEFAULT_CONTROL_PROFILE, planned_topology
from .scenarios import AVAILABLE_SCENARIO_IDS, generate_episode


MINIMUM_PROMOTION_PAIRS = 20
STUDY_PLAN_SCHEMA = "urn:marginbench:study-plan:v1"


def _candidate_id(value: str) -> str:
    if not value or len(value.encode("utf-8")) > 256:
        raise ValueError("Candidate IDs must contain between 1 and 256 UTF-8 bytes.")
    return value


def build_study_plan(
    *,
    baseline: str,
    candidate: str,
    scenarios: list[str],
    repetitions: int,
    key: bytes,
    development_cases: bool,
    control_profile: str = DEFAULT_CONTROL_PROFILE,
) -> dict[str, Any]:
    """Freeze paired cases and counterbalance candidate order without exposing answers."""
    baseline = _candidate_id(baseline)
    candidate = _candidate_id(candidate)
    if baseline == candidate:
        raise ValueError("A paired study needs two distinct candidate IDs.")
    if not 1 <= repetitions <= 100:
        raise ValueError("Study repetitions must be between 1 and 100.")
    if not scenarios or len(scenarios) != len(set(scenarios)):
        raise ValueError("Study scenarios must be a nonempty unique list.")
    if any(scenario not in AVAILABLE_SCENARIO_IDS for scenario in scenarios):
        raise ValueError("Study plan contains an unknown scenario.")

    episodes = [
        generate_episode(scenario, key, repetition)
        for repetition in range(repetitions)
        for scenario in scenarios
    ]
    salt = f"{baseline}\0{candidate}".encode("utf-8")
    ordered = sorted(
        episodes,
        key=lambda episode: hashlib.sha256(salt + bytes.fromhex(episode.fingerprint)).digest(),
    )
    assignments: dict[str, list[str]] = {}
    for index, episode in enumerate(ordered):
        assignments[episode.public_id] = (
            [baseline, candidate] if index % 2 == 0 else [candidate, baseline]
        )
    public_episodes = []
    role_runs = 0
    agent_processes = 0
    for episode in sorted(episodes, key=lambda value: value.public_id):
        roles = [role.seat for role in episode.roles]
        topology = planned_topology(control_profile, roles)
        role_runs += len(roles)
        agent_processes += topology["agentProcessCount"]
        public_episodes.append({
            "id": episode.public_id,
            "scenario": episode.scenario_id,
            "repetition": episode.repetition,
            "fingerprint": episode.fingerprint,
            "roles": roles,
            **topology,
            "candidateOrder": assignments[episode.public_id],
        })
    episode_count = len(public_episodes)
    return {
        "schema": STUDY_PLAN_SCHEMA,
        "benchmarkVersion": "0.1.0",
        "taskSet": "public-development-v1" if development_cases else "private-holdout-v1",
        "developmentCases": development_cases,
        "controlProfile": control_profile,
        "baselineCandidate": baseline,
        "candidate": candidate,
        "scenarioIDs": scenarios,
        "repetitions": repetitions,
        "episodeCount": episode_count,
        "roleRunsPerCandidate": role_runs,
        "totalRoleRuns": role_runs * 2,
        "agentProcessesPerCandidate": agent_processes,
        "totalAgentProcesses": agent_processes * 2,
        "minimumPairsForPromotion": MINIMUM_PROMOTION_PAIRS,
        "sampleSizeSufficient": episode_count >= MINIMUM_PROMOTION_PAIRS,
        "episodes": public_episodes,
    }
