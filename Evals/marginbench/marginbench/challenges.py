"""Static collaboration-demand profiles for MarginBench challenge families."""

from __future__ import annotations

from dataclasses import asdict, dataclass
from typing import Any


CHALLENGE_CATALOG_SCHEMA = "urn:marginbench:challenge-catalog:v1"
DEMAND_AXES = (
    "parallelism",
    "informationDistribution",
    "specialization",
    "reviewIndependence",
    "workspaceVolatility",
    "continuity",
    "coupling",
)


@dataclass(frozen=True)
class ChallengeProfile:
    scenario: str
    title: str
    family: str
    hypothesis: str
    primary_measures: tuple[str, ...]
    demand: dict[str, int]
    rationale: str

    def __post_init__(self) -> None:
        if not self.scenario or not self.title or not self.family or not self.rationale:
            raise ValueError("Challenge profile text fields cannot be empty.")
        if self.hypothesis not in {
            "continuing-favored",
            "role-separated-favored",
            "conditional",
        }:
            raise ValueError("Unknown collaboration hypothesis.")
        if not self.primary_measures or len(self.primary_measures) != len(set(self.primary_measures)):
            raise ValueError("Challenge primary measures must be nonempty and unique.")
        if set(self.demand) != set(DEMAND_AXES):
            raise ValueError("Challenge demand must define every collaboration axis exactly once.")
        if any(
            not isinstance(value, int)
            or isinstance(value, bool)
            or not 0 <= value <= 4
            for value in self.demand.values()
        ):
            raise ValueError("Challenge demand values must be integers from zero through four.")

    def to_public_dict(self) -> dict[str, Any]:
        value = asdict(self)
        value["primaryMeasures"] = list(value.pop("primary_measures"))
        return value


_PROFILES = (
    ChallengeProfile(
        "human_agent_relay",
        "Human-to-agent relay",
        "human-boundary",
        "conditional",
        ("outcome", "continuity", "commandErrors"),
        {
            "parallelism": 0,
            "informationDistribution": 1,
            "specialization": 1,
            "reviewIndependence": 2,
            "workspaceVolatility": 0,
            "continuity": 2,
            "coupling": 1,
        },
        "A human boundary makes durable context useful, but a second model context is not required.",
    ),
    ChallengeProfile(
        "agent_agent_handoff",
        "Serial agent handoff",
        "negative-control",
        "continuing-favored",
        ("outcome", "duration", "tokens", "commandErrors"),
        {
            "parallelism": 0,
            "informationDistribution": 1,
            "specialization": 0,
            "reviewIndependence": 0,
            "workspaceVolatility": 0,
            "continuity": 3,
            "coupling": 1,
        },
        "The work is serial and homogeneous, so a handoff mostly adds coordination cost.",
    ),
    ChallengeProfile(
        "concurrent_review",
        "Concurrent shared-document review",
        "parallel-shared-state",
        "conditional",
        ("outcome", "duration", "recovery", "commandErrors"),
        {
            "parallelism": 4,
            "informationDistribution": 2,
            "specialization": 1,
            "reviewIndependence": 3,
            "workspaceVolatility": 4,
            "continuity": 1,
            "coupling": 4,
        },
        "Parallel review can save time, while shared-state conflicts can erase that advantage.",
    ),
    ChallengeProfile(
        "suggestion_decision",
        "Independent suggestion decision",
        "review-and-decision",
        "role-separated-favored",
        ("outcome", "integrity", "reviewIndependence", "recovery"),
        {
            "parallelism": 0,
            "informationDistribution": 2,
            "specialization": 3,
            "reviewIndependence": 4,
            "workspaceVolatility": 3,
            "continuity": 2,
            "coupling": 4,
        },
        "A fresh decision-maker must evaluate authored proposals after source state changes.",
    ),
    ChallengeProfile(
        "staged_multifile",
        "Staged multi-file update",
        "atomic-workspace-change",
        "conditional",
        ("outcome", "integrity", "recovery", "duration"),
        {
            "parallelism": 3,
            "informationDistribution": 2,
            "specialization": 2,
            "reviewIndependence": 2,
            "workspaceVolatility": 4,
            "continuity": 3,
            "coupling": 4,
        },
        "Atomic staging coordinates coupled files, but the workflow itself carries material overhead.",
    ),
    ChallengeProfile(
        "directory_handoff",
        "Directory-wide handoff",
        "distributed-workspace",
        "role-separated-favored",
        ("outcome", "continuity", "informationRecovery", "tokens"),
        {
            "parallelism": 1,
            "informationDistribution": 4,
            "specialization": 2,
            "reviewIndependence": 2,
            "workspaceVolatility": 1,
            "continuity": 4,
            "coupling": 3,
        },
        "The second role must discover durable work spread across a directory without a transcript.",
    ),
    ChallengeProfile(
        "parallel_shards",
        "Independent parallel shards",
        "clean-parallelism",
        "role-separated-favored",
        ("outcome", "duration", "tokens", "coordinationOverhead"),
        {
            "parallelism": 4,
            "informationDistribution": 2,
            "specialization": 1,
            "reviewIndependence": 2,
            "workspaceVolatility": 0,
            "continuity": 1,
            "coupling": 0,
        },
        "Independent files expose parallel speedup without a shared-write confound.",
    ),
    ChallengeProfile(
        "specialist_audit",
        "Performance proposal with security audit",
        "specialist-independent-review",
        "role-separated-favored",
        ("outcome", "reviewIndependence", "defectDetection", "tokens"),
        {
            "parallelism": 0,
            "informationDistribution": 3,
            "specialization": 4,
            "reviewIndependence": 4,
            "workspaceVolatility": 1,
            "continuity": 2,
            "coupling": 3,
        },
        "A performance choice must be challenged using a different, role-private security rule.",
    ),
    ChallengeProfile(
        "distributed_synthesis",
        "Distributed evidence synthesis",
        "necessary-information-transfer",
        "role-separated-favored",
        ("outcome", "continuity", "informationRecovery", "commandErrors"),
        {
            "parallelism": 1,
            "informationDistribution": 4,
            "specialization": 2,
            "reviewIndependence": 1,
            "workspaceVolatility": 0,
            "continuity": 4,
            "coupling": 2,
        },
        "Neither separated role initially has all facts, so the durable handoff is necessary work.",
    ),
)


def challenge_profile(scenario: str) -> ChallengeProfile:
    profile = next((value for value in _PROFILES if value.scenario == scenario), None)
    if profile is None:
        raise ValueError(f"Unknown MarginBench challenge: {scenario}")
    return profile


def challenge_catalog() -> dict[str, Any]:
    return {
        "schema": CHALLENGE_CATALOG_SCHEMA,
        "catalogVersion": 1,
        "scale": {"minimum": 0, "maximum": 4},
        "axes": [
            {
                "id": "parallelism",
                "low": "inherently serial work",
                "high": "independent useful work can occur simultaneously",
            },
            {
                "id": "informationDistribution",
                "low": "all roles begin with the same facts",
                "high": "required facts are split across roles or locations",
            },
            {
                "id": "specialization",
                "low": "roles apply the same judgment",
                "high": "roles apply meaningfully different expertise or criteria",
            },
            {
                "id": "reviewIndependence",
                "low": "fresh judgment is unnecessary",
                "high": "correlated author error is a central risk",
            },
            {
                "id": "workspaceVolatility",
                "low": "workspace state is static",
                "high": "concurrent or external changes must be reconciled",
            },
            {
                "id": "continuity",
                "low": "one uninterrupted session is sufficient",
                "high": "durable state must survive a role or process boundary",
            },
            {
                "id": "coupling",
                "low": "role outputs are independent",
                "high": "role outputs interact and coordination errors are likely",
            },
        ],
        "challenges": [profile.to_public_dict() for profile in _PROFILES],
        "rules": [
            "Demand values describe tasks, not observed model behavior.",
            "No axis is a weight in a universal benchmark score.",
            "Every topology comparison uses the same generated case and logical role budget.",
            "Negative controls remain in the suite even when collaboration is expected to lose.",
            "Family and axis conclusions require paired valid episodes and disclosed sample counts.",
        ],
    }
