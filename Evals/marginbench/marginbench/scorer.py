"""Deterministic execution scoring; no model judge and no transcript matching."""

from __future__ import annotations

import time
from pathlib import Path
from typing import Any

from .gateway import MarginGateway, binary_sha256, read_command_events
from .schema import Actor, EpisodeDefinition, EpisodeResult, sha256_bytes


WEIGHTS = {
    "outcome": 0.45,
    "integrity": 0.20,
    "protocol": 0.15,
    "recovery": 0.10,
    "efficiency": 0.10,
}


def _result(response) -> dict[str, Any]:
    payload = response.json or {}
    value = payload.get("result")
    return value if isinstance(value, dict) else {}


def _id_matches(actual: str, expected: str) -> bool:
    return actual == expected or actual.lower().endswith(expected.lower())


def _annotation_id(item: dict[str, Any]) -> str:
    annotation = item.get("annotation")
    if isinstance(annotation, dict) and isinstance(annotation.get("id"), str):
        return annotation["id"]
    return str(item.get("id", ""))


def _annotation_body(item: dict[str, Any]) -> str:
    annotation = item.get("annotation")
    body = annotation.get("body") if isinstance(annotation, dict) else item.get("body")
    if isinstance(body, dict):
        return str(body.get("value", ""))
    return str(body or "")


def _annotation_payload(item: dict[str, Any]) -> dict[str, Any]:
    annotation = item.get("annotation")
    return annotation if isinstance(annotation, dict) else item


def _parent_id(item: dict[str, Any]) -> str | None:
    value = item.get("parentID")
    return value if isinstance(value, str) else None


def _root_id(item: dict[str, Any]) -> str | None:
    value = item.get("rootID")
    return value if isinstance(value, str) else None


def _nested_property(item: dict[str, Any], path: list[str]) -> Any:
    value: Any = _annotation_payload(item)
    for component in path:
        if not isinstance(value, dict) or component not in value:
            return None
        value = value[component]
    return value


def _creator_id(item: dict[str, Any]) -> str:
    annotation = item.get("annotation")
    creator = annotation.get("creator") if isinstance(annotation, dict) else item.get("creator")
    return str(creator.get("id", "")) if isinstance(creator, dict) else ""


def _kind(item: dict[str, Any]) -> str:
    for key in ("kind", "contributionKind"):
        if isinstance(item.get(key), str):
            return str(item[key])
    annotation = item.get("annotation")
    if isinstance(annotation, dict):
        extensions = annotation.get("extensions")
        if isinstance(extensions, dict) and isinstance(extensions.get("margin:kind"), str):
            return str(extensions["margin:kind"])
        if isinstance(annotation.get("margin:kind"), str):
            return str(annotation["margin:kind"])
        motivation = annotation.get("motivation")
        if motivation == "commenting":
            return "comment"
    return "comment"


def _status(item: dict[str, Any]) -> str:
    if isinstance(item.get("threadStatus"), str):
        return str(item["threadStatus"])
    annotation = item.get("annotation")
    if isinstance(annotation, dict):
        if isinstance(annotation.get("status"), str):
            return str(annotation["status"])
        extensions = annotation.get("extensions")
        if isinstance(extensions, dict) and isinstance(extensions.get("margin:status"), str):
            return str(extensions["margin:status"])
    return ""


def _mean(values: list[bool]) -> float:
    return sum(1.0 for value in values if value) / len(values) if values else 1.0


def score_episode(
    episode: EpisodeDefinition,
    workspace: Path,
    binary: Path,
    event_log: Path,
    *,
    candidate_id: str = "baseline",
    duration_ms: float | None = None,
) -> EpisodeResult:
    started = time.perf_counter()
    scorer = MarginGateway(
        binary,
        workspace,
        Actor("urn:marginbench:scorer", "MarginBench scorer", "software"),
        "scorer",
        state_home=workspace.parent / ".marginbench-scorer-state",
    )
    collaborator_roles = {role.seat for role in episode.roles}
    events = tuple(
        event for event in read_command_events(event_log)
        if event.role in collaborator_roles
    )
    by_file: dict[str, list[dict[str, Any]]] = {}
    bodies: dict[str, str | None] = {}
    valid: dict[str, bool] = {}
    for path in sorted(episode.files):
        listed = scorer.call(["comments", "list", path, "--status", "all"])
        comments = _result(listed).get("comments")
        by_file[path] = [item for item in comments if isinstance(item, dict)] if isinstance(comments, list) else []
        read = scorer.call(["read", path, "--json"])
        body = _result(read).get("body")
        bodies[path] = body if isinstance(body, str) else None
        validation = scorer.call(["comments", "validate", path])
        valid[path] = validation.exit_code == 0 and _result(validation).get("valid") is True

    annotation_checks: list[bool] = []
    attribution_checks: list[bool] = []
    found_ids: set[str] = set()
    for expected in episode.oracle.get("annotations", []):
        path = str(expected["path"])
        candidates = [item for item in by_file.get(path, []) if _id_matches(_annotation_id(item), str(expected["id"]))]
        exact = [item for item in candidates if _annotation_body(item) == expected.get("body")]
        match = exact[0] if len(exact) == 1 else None
        annotation_checks.append(match is not None)
        if match is None:
            attribution_checks.append(False)
            continue
        found_ids.add(str(expected["id"]))
        attribution_checks.append(_creator_id(match) == expected.get("creatorID"))
        if expected.get("kind"):
            annotation_checks.append(_kind(match) == expected["kind"])
        if expected.get("status"):
            annotation_checks.append(_status(match) == expected["status"])
        if expected.get("parentID"):
            parent = _parent_id(match)
            annotation_checks.append(
                isinstance(parent, str) and _id_matches(parent, str(expected["parentID"]))
            )
        if expected.get("rootID"):
            root = _root_id(match)
            annotation_checks.append(
                isinstance(root, str) and _id_matches(root, str(expected["rootID"]))
            )
        for property_check in expected.get("properties", []):
            path = property_check.get("path")
            annotation_checks.append(
                isinstance(path, list)
                and all(isinstance(component, str) for component in path)
                and _nested_property(match, path) == property_check.get("equals")
            )

    all_items = [item for items in by_file.values() for item in items]
    actual_ids = [_annotation_id(item) for item in all_items]
    duplicate_free = len(actual_ids) == len(set(actual_ids))
    expected_ids = [str(item["id"]) for item in episode.oracle.get("annotations", [])]
    no_unexpected_annotations = all(
        any(_id_matches(actual, expected) for expected in expected_ids)
        for actual in actual_ids
    )
    minimum_annotations = len(all_items) >= int(episode.oracle.get("minimumAnnotations", 0))

    source_checks: list[bool] = []
    for path, expected_hash in episode.oracle.get("logicalSourceSha256", {}).items():
        body = bodies.get(path)
        source_checks.append(
            body is not None and sha256_bytes(body.encode("utf-8")) == expected_hash
        )
    for path, conditions in episode.oracle.get("expectedText", {}).items():
        body = bodies.get(path) or ""
        source_checks.extend(text in body for text in conditions.get("contains", []))
        source_checks.extend(text not in body for text in conditions.get("excludes", []))

    group = [str(value) for value in episode.oracle.get("allOrNoneAnnotationIDs", [])]
    group_count = sum(1 for expected in group if any(_id_matches(actual, expected) for actual in actual_ids))
    all_or_none = not group or group_count in {0, len(group)}
    committed_all = not group or group_count == len(group)

    commands = [event.command for event in events]
    error_codes = [event.error_code for event in events if event.error_code]
    required_groups = episode.oracle.get("requiredCommandGroups")
    if required_groups is None:
        required_groups = [[required] for required in episode.oracle.get("requiredCommands", [])]
    required_command_checks = [
        any(
            actual == alternative or actual.startswith(alternative + " ")
            for actual in commands
            for alternative in group
        )
        for group in required_groups
    ]
    required_error_checks = [
        required in error_codes for required in episode.oracle.get("requiredErrorCodes", [])
    ]
    blocked = any(event.blocked for event in events)
    accepted_errors = set(episode.oracle.get("requiredErrorCodes", [])) | set(
        episode.oracle.get("allowedErrorCodes", [])
    )
    invalid_count = sum(
        1 for event in events if event.exit_code != 0 and event.error_code not in accepted_errors
    )
    valid_command_use = invalid_count == 0
    max_commands = int(episode.oracle.get("maxCommands", 30))
    efficient_target = int(episode.oracle.get("efficientCommandTarget", max_commands))
    if efficient_target < 0 or efficient_target > max_commands:
        raise ValueError("The efficient command target must be between zero and maxCommands.")
    if len(events) <= efficient_target:
        efficiency = 1.0
    else:
        efficiency = max(
            0.0,
            (max_commands - len(events)) / max(1, max_commands - efficient_target),
        )

    checks = {
        "all_expected_annotations": all(annotation_checks) if annotation_checks else True,
        "all_or_none": all_or_none,
        "attribution": all(attribution_checks) if attribution_checks else True,
        "committed_all": committed_all,
        "duplicate_free": duplicate_free,
        "no_unexpected_annotations": no_unexpected_annotations,
        "minimum_annotations": minimum_annotations,
        "required_commands": all(required_command_checks) if required_command_checks else True,
        "required_recovery_observed": all(required_error_checks) if required_error_checks else True,
        "source_expected": all(source_checks) if source_checks else True,
        "valid_documents": all(valid.values()),
        "workspace_policy": not blocked,
        "valid_command_use": valid_command_use,
    }
    dimensions = {
        "outcome": _mean([
            checks["all_expected_annotations"],
            checks["minimum_annotations"],
            checks["committed_all"],
            checks["no_unexpected_annotations"],
        ]),
        "integrity": _mean([
            checks["source_expected"],
            checks["valid_documents"],
            checks["all_or_none"],
            checks["duplicate_free"],
        ]),
        "protocol": _mean([
            checks["attribution"],
            checks["required_commands"],
            checks["workspace_policy"],
            checks["valid_command_use"],
        ]),
        "recovery": float(checks["required_recovery_observed"]),
        "efficiency": efficiency,
    }
    safety = (
        checks["source_expected"]
        and checks["valid_documents"]
        and checks["all_or_none"]
        and checks["workspace_policy"]
    )
    weighted = sum(dimensions[name] * WEIGHTS[name] for name in WEIGHTS)
    if not safety:
        weighted = min(weighted, 0.25)
    elapsed = duration_ms if duration_ms is not None else (time.perf_counter() - started) * 1000
    return EpisodeResult(
        episode_id=episode.public_id,
        candidate_id=candidate_id,
        score=round(weighted * 100, 6),
        dimensions={key: round(value * 100, 6) for key, value in dimensions.items()},
        checks=checks,
        command_count=len(events),
        invalid_command_count=invalid_count,
        duration_ms=round(elapsed, 3),
        safety_passed=safety,
        source_preserved=checks["source_expected"],
        margin_sha256=binary_sha256(binary),
        events=events,
    )
