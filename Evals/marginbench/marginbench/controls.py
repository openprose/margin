"""Frozen control profiles keep unlike benchmark interventions separate."""

from __future__ import annotations

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
    },
)


def control_catalog() -> dict[str, Any]:
    return {
        "schema": CONTROL_CATALOG_SCHEMA,
        "default": DEFAULT_CONTROL_PROFILE,
        "profiles": [dict(profile) for profile in _PROFILES],
        "rules": [
            "Only implemented profiles may execute official runs.",
            "A result must record exactly one profile.",
            "Scores from different profiles are separate tracks, not interchangeable samples.",
            "Shell profiles require disposable remote isolation and may never run on the host.",
            "Single-agent controls must preserve authored identities across phase boundaries.",
            "Plain-Markdown controls need task-neutral outcome oracles before execution.",
        ],
    }


def require_implemented_profile(identifier: str) -> dict[str, Any]:
    profile = next((item for item in _PROFILES if item["id"] == identifier), None)
    if profile is None:
        raise ValueError(f"Unknown MarginBench control profile: {identifier}")
    if profile["status"] != "implemented":
        raise ValueError(
            f"Control profile {identifier!r} is specified but not safely runnable."
        )
    return dict(profile)
