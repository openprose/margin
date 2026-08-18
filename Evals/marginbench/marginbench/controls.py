"""Frozen control profiles keep unlike benchmark interventions separate."""

from __future__ import annotations

from copy import deepcopy
from typing import Any


DEFAULT_CONTROL_PROFILE = "role-separated-margin-only-v1"
CONTROL_CATALOG_SCHEMA = "urn:marginbench:control-catalog:v1"

_PROFILES: tuple[dict[str, Any], ...] = (
    {
        "id": DEFAULT_CONTROL_PROFILE,
        "status": "implemented",
        "agentTopology": "role-separated",
        "transcriptSharing": "none-between-roles",
        "durableSurface": "margin",
        "toolSurface": ["margin"],
        "shellAccess": False,
        "isolationRequirement": "confined-gateway",
        "scoreComparability": "all-dimensions",
        "purpose": "Primary test of durable collaboration through Margin.",
        "blockingGates": [],
    },
    {
        "id": "single-agent-margin-v1",
        "status": "specified-not-runnable",
        "agentTopology": "single-context",
        "transcriptSharing": "all-phases",
        "durableSurface": "margin",
        "toolSurface": ["margin"],
        "shellAccess": False,
        "isolationRequirement": "actor-preserving-phase-controller",
        "scoreComparability": "outcome-integrity-efficiency",
        "purpose": "Measure the cost or benefit of splitting one task across collaborators.",
        "blockingGates": [
            {
                "id": "continuing-interaction",
                "requirement": "Run every role phase in one promptless continuing model interaction.",
            },
            {
                "id": "phase-bound-identity",
                "requirement": "Bind each phase to its trusted actor identity outside model control.",
            },
            {
                "id": "topology-aware-accounting",
                "requirement": "Separate logical roles, model processes, traces, and compute-matched cost limits.",
            },
            {
                "id": "served-reference-gates",
                "requirement": "Pass local and served reference, adversarial, privacy, and budget gates.",
            },
        ],
    },
    {
        "id": "role-separated-plain-markdown-v1",
        "status": "specified-not-runnable",
        "agentTopology": "role-separated",
        "transcriptSharing": "none-between-roles",
        "durableSurface": "plain-markdown-files",
        "toolSurface": ["workspace_read", "workspace_write"],
        "shellAccess": False,
        "isolationRequirement": "confined-file-gateway",
        "scoreComparability": "task-specific-outcome-integrity",
        "purpose": "Measure what durable coordination is lost without Margin primitives.",
        "blockingGates": [
            {
                "id": "confined-file-gateway",
                "requirement": "Provide bounded list, read, and compare-and-swap write operations without shell access.",
            },
            {
                "id": "representation-neutral-oracle",
                "requirement": "Grade equivalent task facts without requiring Margin protocol representation.",
            },
            {
                "id": "file-gateway-adversarial-tests",
                "requirement": "Prove path, symlink, size, concurrency, and partial-write safety.",
            },
            {
                "id": "transcript-isolation",
                "requirement": "Prove role processes exchange state only through the declared file surface.",
            },
        ],
    },
    {
        "id": "role-separated-margin-shell-v1",
        "status": "specified-not-runnable",
        "agentTopology": "role-separated",
        "transcriptSharing": "none-between-roles",
        "durableSurface": "margin",
        "toolSurface": ["margin", "shell"],
        "shellAccess": True,
        "isolationRequirement": "disposable-per-role-remote-sandbox",
        "scoreComparability": "all-dimensions-plus-policy",
        "purpose": "Measure whether a broad action space helps or distracts from collaboration.",
        "blockingGates": [
            {
                "id": "remote-role-sandbox",
                "requirement": "Run each role in a disposable remote sandbox, never on the benchmark host.",
            },
            {
                "id": "network-and-secret-isolation",
                "requirement": "Confine network access and prove holdout, scorer, credentials, and host paths are unreachable.",
            },
            {
                "id": "redacted-shell-events",
                "requirement": "Record bounded shell telemetry without publishing arguments, environment, or content.",
            },
            {
                "id": "sandbox-lifecycle-gates",
                "requirement": "Pass setup, teardown, cleanup-cost, adversarial, and fake-agent gates.",
            },
        ],
    },
    {
        "id": "role-separated-no-exchange-v1",
        "status": "specified-not-runnable",
        "agentTopology": "role-separated",
        "transcriptSharing": "none-between-roles",
        "durableSurface": "none",
        "toolSurface": ["isolated_workspace_read"],
        "shellAccess": False,
        "isolationRequirement": "independent-initial-workspace-per-role",
        "scoreComparability": "role-specific-representation-neutral-outcomes",
        "purpose": "Establish what each role can accomplish without any collaborator state exchange.",
        "blockingGates": [
            {
                "id": "role-specific-neutral-oracle",
                "requirement": "Define only the representation-neutral outcomes each isolated role can satisfy alone.",
            },
            {
                "id": "independent-workspace-proof",
                "requirement": "Prove roles receive independent initial files and no transcript or durable state exchange.",
            },
            {
                "id": "non-vacuous-aggregation",
                "requirement": "Define reporting that cannot reward or punish structurally impossible handoffs.",
            },
        ],
    },
)


def control_catalog() -> dict[str, Any]:
    return {
        "schema": CONTROL_CATALOG_SCHEMA,
        "default": DEFAULT_CONTROL_PROFILE,
        "profiles": deepcopy(list(_PROFILES)),
        "rules": [
            "Only implemented profiles may execute official runs.",
            "A result must record exactly one profile.",
            "Scores from different profiles are separate tracks, not interchangeable samples.",
            "Shell profiles require disposable remote isolation and may never run on the host.",
            "Single-agent controls must preserve authored identities across phase boundaries.",
            "Plain-Markdown controls need task-neutral outcome oracles before execution.",
        ],
    }


def control_profile(identifier: str) -> dict[str, Any]:
    profile = next((item for item in _PROFILES if item["id"] == identifier), None)
    if profile is None:
        raise ValueError(f"Unknown MarginBench control profile: {identifier}")
    return deepcopy(profile)


def planned_topology(identifier: str, logical_roles: list[str]) -> dict[str, Any]:
    """Describe model processes without making a gated profile executable."""
    control_profile(identifier)
    if (
        not logical_roles
        or len(logical_roles) > 32
        or len(logical_roles) != len(set(logical_roles))
        or any(
            not isinstance(role, str) or not role or len(role.encode("utf-8")) > 128
            for role in logical_roles
        )
    ):
        raise ValueError("Logical roles must be a nonempty unique bounded list.")
    if identifier == "single-agent-margin-v1":
        return {
            "agentProcessCount": 1,
            "traceSeats": ["agent"],
            "phasePolicy": "serial-stable-role-order",
        }
    return {
        "agentProcessCount": len(logical_roles),
        "traceSeats": list(logical_roles),
        "phasePolicy": (
            "independent-workspaces"
            if identifier == "role-separated-no-exchange-v1"
            else "scenario-defined"
        ),
    }


def require_implemented_profile(identifier: str) -> dict[str, Any]:
    profile = control_profile(identifier)
    if profile["status"] != "implemented":
        raise ValueError(
            f"Control profile {identifier!r} is specified but not safely runnable."
        )
    return profile
