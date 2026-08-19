"""Deterministic partial scorer for the still-gated plain-Markdown control."""

from __future__ import annotations

import hashlib
from collections import Counter
from pathlib import Path
from typing import Any

from .neutral import NeutralFormatError, NeutralLedger, expected_neutral_ledger
from .plain_gateway import PlainGatewayError, PlainProvenanceLog, PlainWorkspaceGateway
from .schema import Actor, EpisodeDefinition


NEUTRAL_ASSESSMENT_SCHEMA = "urn:marginbench:neutral-assessment:v1"


def _mean(values: tuple[bool, ...]) -> float:
    return round(100 * sum(1 for value in values if value) / len(values), 6)


def _comparable_fact(value, by_id) -> dict[str, Any]:
    projected = value.to_dict()
    projected.pop("extensions", None)
    root = by_id.get(value.root)
    if (
        value.kind == "reply"
        and value.audience
        and root is not None
        and value.audience == root.audience
    ):
        # Repeating the root's audience on a reply adds no routing information.
        # Margin replies inherit their thread audience implicitly, whereas the
        # plain ledger can spell it out. Normalize that representation-only
        # difference without accepting an unrelated or enlarged audience.
        projected["audience"] = []
    return projected


def score_neutral_state(
    episode: EpisodeDefinition,
    workspace: Path,
    state_directory: Path,
    provenance: PlainProvenanceLog,
) -> dict[str, Any]:
    """Score deterministic state and history; resource reporting is separate."""
    expected = expected_neutral_ledger(episode)
    scorer = PlainWorkspaceGateway(
        workspace,
        Actor("urn:marginbench:neutral-scorer", "MarginBench neutral scorer"),
        state_directory,
        provenance,
    )
    ledger_error: str | None = None
    try:
        with scorer._workspace_lock(exclusive=False):
            ledger_raw, _ = scorer._read_file("COLLABORATION.md")
        actual = NeutralLedger.parse(ledger_raw)
    except (NeutralFormatError, PlainGatewayError) as error:
        actual = NeutralLedger(())
        ledger_error = error.code

    expected_by_id = {fact.id: fact for fact in expected.facts}
    actual_by_id = {fact.id: fact for fact in actual.facts}
    shared = expected_by_id.keys() & actual_by_id.keys()
    mismatch_counts: Counter[str] = Counter()
    redundant_inherited_audience_count = 0
    for identifier in shared:
        expected_fact = expected_by_id[identifier]
        actual_fact = actual_by_id[identifier]
        expected_fields = _comparable_fact(expected_fact, expected_by_id)
        actual_fields = _comparable_fact(actual_fact, actual_by_id)
        for field_name in expected_fields.keys() | actual_fields.keys():
            if expected_fields.get(field_name) != actual_fields.get(field_name):
                mismatch_counts[field_name] += 1
        actual_root = actual_by_id.get(actual_fact.root)
        if (
            expected_fact.kind == actual_fact.kind == "reply"
            and not expected_fact.audience
            and actual_fact.audience
            and actual_root is not None
            and actual_fact.audience == actual_root.audience
        ):
            redundant_inherited_audience_count += 1
    exact_fields = all(
        _comparable_fact(expected_by_id[identifier], expected_by_id)
        == _comparable_fact(actual_by_id[identifier], actual_by_id)
        for identifier in shared
    )
    all_expected = set(expected_by_id) <= set(actual_by_id) and exact_fields
    no_unexpected = set(actual_by_id) <= set(expected_by_id)

    introduction: dict[str, str] = {}
    introduction_events = {}
    decision: dict[str, str] = {}
    decision_events = {}
    ledger_events = []
    for event in provenance.snapshot():
        if event.path != "COLLABORATION.md":
            continue
        ledger_events.append(event)
        for identifier in event.introduced_fact_ids:
            introduction.setdefault(identifier, event.actor_id)
            introduction_events.setdefault(identifier, event)
        for identifier in event.decided_fact_ids:
            decision.setdefault(identifier, event.actor_id)
            decision_events.setdefault(identifier, event)
    trusted_attribution = all(
        introduction.get(fact.id) == fact.author
        for fact in expected.facts
        if fact.id in actual_by_id
    ) and set(actual_by_id) <= set(introduction)
    expected_decisions = {
        fact.id: fact.decision_by
        for fact in expected.facts
        if fact.decision_by is not None
    }
    trusted_decisions = all(
        decision.get(identifier) == actor
        for identifier, actor in expected_decisions.items()
    )

    reads = provenance.read_snapshot()

    def observed(actor: str, required_ids: set[str], action_sequence: int | None) -> bool:
        return action_sequence is not None and any(
            read.actor_id == actor
            and read.sequence < action_sequence
            and required_ids <= set(read.visible_fact_ids)
            for read in reads
        )

    continuity_checks: list[bool] = []
    for fact in expected.facts:
        if fact.parent is not None:
            action = introduction_events.get(fact.id)
            continuity_checks.append(observed(
                fact.author,
                {fact.parent},
                None if action is None else action.sequence,
            ))
    if episode.scenario_id == "specialist_audit":
        reference = episode.oracle.get("reference", {})
        decision_id = str(reference.get("decisionID", ""))
        issue_id = str(reference.get("issueID", ""))
        issue = expected_by_id.get(issue_id)
        action = introduction_events.get(issue_id)
        continuity_checks.append(
            issue is not None
            and observed(
                issue.author,
                {decision_id},
                None if action is None else action.sequence,
            )
        )
    if episode.scenario_id == "suggestion_decision":
        for fact in expected.facts:
            action = decision_events.get(fact.id)
            continuity_checks.append(
                fact.decision_by is not None
                and observed(
                    fact.decision_by,
                    {fact.id},
                    None if action is None else action.sequence,
                )
            )
    if episode.scenario_id == "staged_multifile":
        grouped_ids = {fact.id for fact in expected.facts if fact.transaction is not None}
        reviewer = next((role.actor.id for role in episode.roles if role.seat == "reviewer"), "")
        action = next((
            event
            for event in ledger_events
            if event.actor_id == reviewer and grouped_ids <= set(event.changed_fact_ids)
        ), None)
        continuity_checks.append(observed(
            reviewer,
            grouped_ids,
            None if action is None else action.sequence,
        ))
    continuity_observed = all(continuity_checks) if continuity_checks else True
    failures = provenance.failure_snapshot()
    recovery_required = bool(episode.oracle.get("requiredErrorCodes"))
    recovery_observed = (
        any(event.error_code == "PRECONDITION_FAILED" for event in failures)
        if recovery_required
        else True
    )

    source_expected = True
    source_error_count = 0
    for relative, expected_sha in episode.oracle.get("logicalSourceSha256", {}).items():
        try:
            with scorer._workspace_lock(exclusive=False):
                raw, _ = scorer._read_file(str(relative))
        except PlainGatewayError:
            source_expected = False
            source_error_count += 1
            continue
        if hashlib.sha256(raw).hexdigest() != expected_sha:
            source_expected = False

    group = {str(value) for value in episode.oracle.get("allOrNoneAnnotationIDs", [])}
    present_group = group & set(actual_by_id)
    all_or_none_final = not group or len(present_group) in {0, len(group)}
    committed_all = not group or present_group == group
    all_or_none_history = not group or all(
        len(group & set(event.visible_fact_ids)) in {0, len(group)}
        for event in ledger_events
    )
    checks = {
        "allExpectedFacts": all_expected,
        "allOrNoneFinal": all_or_none_final,
        "allOrNoneHistory": all_or_none_history,
        "committedAll": committed_all,
        "continuityObserved": continuity_observed,
        "duplicateFree": ledger_error is None,
        "exactFactFields": exact_fields,
        "ledgerValid": ledger_error is None,
        "noUnexpectedFacts": no_unexpected,
        "recoveryObserved": recovery_observed,
        "sourceExpected": source_expected,
        "trustedAttribution": trusted_attribution,
        "trustedDecisions": trusted_decisions,
    }
    dimensions = {
        "outcome": _mean((
            checks["allExpectedFacts"],
            checks["noUnexpectedFacts"],
            checks["exactFactFields"],
            checks["committedAll"],
        )),
        "integrity": _mean((
            checks["sourceExpected"],
            checks["ledgerValid"],
            checks["duplicateFree"],
            checks["allOrNoneFinal"],
            checks["allOrNoneHistory"],
        )),
        "attribution": _mean((
            checks["trustedAttribution"],
            checks["trustedDecisions"],
        )),
        "continuity": float(100 if checks["continuityObserved"] else 0),
        "recovery": float(100 if checks["recoveryObserved"] else 0),
    }
    safety = (
        checks["sourceExpected"]
        and checks["ledgerValid"]
        and checks["allOrNoneFinal"]
        and checks["allOrNoneHistory"]
    )
    return {
        "schema": NEUTRAL_ASSESSMENT_SCHEMA,
        "episodeID": episode.public_id,
        "representation": "plain-markdown-v1",
        "expectedFactCount": len(expected.facts),
        "actualFactCount": len(actual.facts),
        "writeEventCount": len(ledger_events),
        "readEventCount": len(reads),
        "failureEventCount": len(failures),
        "checks": checks,
        "dimensions": dimensions,
        "sourcePreserved": checks["sourceExpected"],
        "safetyPassed": safety,
        "notEvaluated": ["efficiency"],
        "diagnostics": {
            "ledgerError": ledger_error,
            "sourceErrorCount": source_error_count,
            "continuityRequirementCount": len(continuity_checks),
            "recoveryRequired": recovery_required,
            "missingExpectedFactCount": len(set(expected_by_id) - set(actual_by_id)),
            "unexpectedFactCount": len(set(actual_by_id) - set(expected_by_id)),
            "fieldMismatchCounts": [
                {"name": name, "count": count}
                for name, count in sorted(mismatch_counts.items())
            ],
            "redundantInheritedAudienceCount": redundant_inherited_audience_count,
        },
    }
