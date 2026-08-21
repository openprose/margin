"""Role-specific neutral oracles for the deliberately isolated control floor."""

from __future__ import annotations

from collections import Counter
from dataclasses import dataclass, replace
from typing import Any, Iterable

from .neutral import NeutralFact, NeutralLedger, expected_neutral_ledger
from .schema import EpisodeDefinition


NO_EXCHANGE_PROFILE = "role-separated-no-exchange-v1"
NO_EXCHANGE_FEASIBILITY_SCHEMA = "urn:marginbench:no-exchange-feasibility:v1"

_INDEPENDENT = "none"
_PRIOR_PARENT = "prior-shared-parent"
_PRIOR_SUGGESTION = "prior-shared-suggestion"
_LATER_COMMIT = "later-collaborator-commit"
_EXTERNAL_STATE = "external-nonfile-state"


@dataclass(frozen=True)
class _Claim:
    seat: str | None
    outcome: str
    kind: str
    dependency: str

    @property
    def independently_satisfiable(self) -> bool:
        return self.dependency == _INDEPENDENT


def _role_by_actor(episode: EpisodeDefinition) -> dict[str, str]:
    result: dict[str, str] = {}
    for role in episode.roles:
        if role.actor.id in result or role.seat in result.values():
            raise ValueError("No-exchange feasibility requires unique role actors and seats.")
        result[role.actor.id] = role.seat
    return result


def _independent_creation(fact: NeutralFact) -> NeutralFact:
    """Project only what the original author can create before any peer acts."""
    state = fact.state
    decision_by = fact.decision_by
    if fact.kind == "suggestion":
        state = "open"
        decision_by = None
    elif state == "resolved":
        state = "open"
    return replace(
        fact,
        state=state,
        decision_by=decision_by,
        transaction=None,
    )


def role_specific_neutral_oracles(
    episode: EpisodeDefinition,
) -> dict[str, NeutralLedger]:
    """Return exact private oracles containing only facts each role can create alone.

    Replies need their parent, and transaction-tagged facts do not exist until a later
    collaborator commits the stage. Those structurally dependent outcomes are therefore
    deliberately absent rather than counted as failures.
    """
    role_by_actor = _role_by_actor(episode)
    by_seat: dict[str, list[NeutralFact]] = {
        role.seat: [] for role in episode.roles
    }
    for fact in expected_neutral_ledger(episode).facts:
        seat = role_by_actor.get(fact.author)
        if seat is None or fact.parent is not None or fact.transaction is not None:
            continue
        by_seat[seat].append(_independent_creation(fact))
    return {
        seat: NeutralLedger(tuple(sorted(facts, key=lambda item: item.id)))
        for seat, facts in by_seat.items()
    }


def _claims(episode: EpisodeDefinition) -> tuple[list[_Claim], list[_Claim]]:
    ledger = expected_neutral_ledger(episode)
    role_by_actor = _role_by_actor(episode)
    by_id = {fact.id: fact for fact in ledger.facts}
    role_claims: list[_Claim] = []
    external_claims: list[_Claim] = []

    for fact in ledger.facts:
        seat = role_by_actor.get(fact.author)
        if seat is None:
            external_claims.append(_Claim(
                None, "create-fact", fact.kind, _EXTERNAL_STATE,
            ))
            continue
        dependency = _INDEPENDENT
        if fact.parent is not None:
            dependency = _PRIOR_PARENT
        elif fact.transaction is not None:
            dependency = _LATER_COMMIT
        role_claims.append(_Claim(seat, "create-fact", fact.kind, dependency))

        if fact.kind == "suggestion" and fact.state in {"accepted", "rejected"}:
            decision_seat = role_by_actor.get(fact.decision_by or "")
            if decision_seat is not None:
                role_claims.append(_Claim(
                    decision_seat,
                    "accept-suggestion" if fact.state == "accepted" else "reject-suggestion",
                    "suggestion",
                    _PRIOR_SUGGESTION,
                ))

    roots = [fact for fact in ledger.facts if fact.parent is None]
    for root in roots:
        if root.state != "resolved" or root.kind == "suggestion":
            continue
        descendants = [
            fact for fact in ledger.facts
            if fact.root == root.id and fact.parent is not None
        ]
        if not descendants:
            continue
        # The frozen scenarios use one response chain. Selecting the deepest
        # terminal author keeps the rule deterministic if deeper trees are added.
        terminal = max(descendants, key=lambda fact: _depth(fact, by_id))
        seat = role_by_actor.get(terminal.author)
        if seat is not None:
            role_claims.append(_Claim(
                seat, "resolve-thread", root.kind, _PRIOR_PARENT,
            ))

    initial_hashes = {
        path: _sha256_text(body) for path, body in episode.files.items()
    }
    expected_hashes = episode.oracle.get("logicalSourceSha256", {})
    changed_files = {
        path for path, digest in expected_hashes.items()
        if initial_hashes.get(path) != digest
    }
    for path in sorted(changed_files):
        deciding = [
            fact for fact in ledger.facts
            if fact.file == path and fact.kind == "suggestion" and fact.state == "accepted"
        ]
        for fact in deciding:
            seat = role_by_actor.get(fact.decision_by or "")
            if seat is not None:
                role_claims.append(_Claim(
                    seat, "change-source", "suggestion", _PRIOR_SUGGESTION,
                ))

    return role_claims, external_claims


def _sha256_text(value: str) -> str:
    from .schema import sha256_bytes

    return sha256_bytes(value.encode("utf-8"))


def _depth(fact: NeutralFact, by_id: dict[str, NeutralFact]) -> int:
    depth = 0
    cursor = fact
    seen = {fact.id}
    while cursor.parent is not None:
        if cursor.parent in seen or cursor.parent not in by_id:
            raise ValueError("Neutral reply graph is invalid.")
        seen.add(cursor.parent)
        cursor = by_id[cursor.parent]
        depth += 1
    return depth


def _count_claims(claims: Iterable[_Claim]) -> list[dict[str, Any]]:
    counts = Counter(
        (claim.outcome, claim.kind, claim.dependency) for claim in claims
    )
    return [
        {
            "outcome": outcome,
            "kind": kind,
            "dependency": dependency,
            "count": count,
        }
        for (outcome, kind, dependency), count in sorted(counts.items())
    ]


def assess_no_exchange_episode(episode: EpisodeDefinition) -> dict[str, Any]:
    """Build one content-free feasibility assessment; it is not an agent score."""
    role_claims, external_claims = _claims(episode)
    oracles = role_specific_neutral_oracles(episode)
    roles: list[dict[str, Any]] = []
    independent_total = 0
    dependent_total = 0
    for role in sorted(episode.roles, key=lambda item: (item.phase, item.seat)):
        claims = [claim for claim in role_claims if claim.seat == role.seat]
        independent = [claim for claim in claims if claim.independently_satisfiable]
        dependent = [claim for claim in claims if not claim.independently_satisfiable]
        independent_total += len(independent)
        dependent_total += len(dependent)
        roles.append({
            "seat": role.seat,
            "phase": role.phase,
            "independentOracleFactCount": len(oracles[role.seat].facts),
            "independentOutcomeCount": len(independent),
            "dependentOutcomeCount": len(dependent),
            "independentOutcomes": _count_claims(independent),
            "dependentOutcomes": _count_claims(dependent),
        })
    return {
        "scenario": episode.scenario_id,
        "repetition": episode.repetition,
        "roles": roles,
        "externalOutcomes": _count_claims(external_claims),
        "totals": {
            "independent": independent_total,
            "collaborationDependent": dependent_total,
            "external": len(external_claims),
        },
        "overallScore": None,
    }


def build_no_exchange_feasibility(
    episodes: Iterable[EpisodeDefinition],
) -> dict[str, Any]:
    assessments = sorted(
        (assess_no_exchange_episode(episode) for episode in episodes),
        key=lambda item: (item["repetition"], item["scenario"]),
    )
    if not assessments:
        raise ValueError("No-exchange feasibility requires at least one episode.")
    scenarios = {assessment["scenario"] for assessment in assessments}
    repetitions = {assessment["repetition"] for assessment in assessments}
    return {
        "schema": NO_EXCHANGE_FEASIBILITY_SCHEMA,
        "paidModelsInvoked": False,
        "controlProfile": NO_EXCHANGE_PROFILE,
        "controlRunnable": False,
        "aggregation": "per-role-only-no-overall-score",
        "gateStatus": {
            "roleSpecificNeutralOracle": "complete",
            "independentWorkspaceProof": "blocked",
            "nonVacuousAggregation": "complete",
        },
        "scenarioCount": len(scenarios),
        "repetitionCount": len(repetitions),
        "assessmentCount": len(assessments),
        "assessments": assessments,
        "totals": {
            "independent": sum(item["totals"]["independent"] for item in assessments),
            "collaborationDependent": sum(
                item["totals"]["collaborationDependent"] for item in assessments
            ),
            "external": sum(item["totals"]["external"] for item in assessments),
        },
        "nextBlockingGate": "independent-workspace-proof",
    }
