"""Deterministic execution scoring; no model judge and no transcript matching."""

from __future__ import annotations

import os
import re
import time
from pathlib import Path
from typing import Any

from .gateway import MarginGateway, binary_sha256, read_command_events
from .schema import Actor, CommandEvent, EpisodeDefinition, EpisodeResult, sha256_bytes


WEIGHTS = {
    "outcome": 0.45,
    "integrity": 0.20,
    "protocol": 0.15,
    "recovery": 0.10,
    "efficiency": 0.10,
}

UUID_PATTERN = re.compile(
    r"^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$",
    re.IGNORECASE,
)
MAX_WORKSPACE_INVENTORY_ENTRIES = 16_384


def _result(response) -> dict[str, Any]:
    payload = response.json or {}
    value = payload.get("result")
    return value if isinstance(value, dict) else {}


def _canonical_annotation_id(value: str) -> str:
    lowered = value.lower()
    candidate = lowered[9:] if lowered.startswith("urn:uuid:") else lowered
    if UUID_PATTERN.fullmatch(candidate):
        return f"urn:uuid:{candidate}"
    return value


def _id_matches(actual: str, expected: str) -> bool:
    return _canonical_annotation_id(actual) == _canonical_annotation_id(expected)


def _workspace_inventory(workspace: Path) -> tuple[set[str], bool]:
    """Return bounded public workspace entries, excluding Margin's private state.

    Agents are allowed to change the declared documents and Margin may maintain
    `.margin` beside them. Other files, directories, symlinks, or an inventory
    too large to inspect are observable task residue and must not silently
    receive a clean integrity score. Directory entries have a trailing slash.
    """
    paths: set[str] = set()
    entry_count = 0
    traversal_errors: list[OSError] = []
    for root, directories, files in os.walk(
        workspace,
        topdown=True,
        followlinks=False,
        onerror=traversal_errors.append,
    ):
        root_path = Path(root)
        if root_path == workspace:
            directories[:] = [
                name
                for name in directories
                if name != ".margin" or (root_path / name).is_symlink()
            ]
        for name in list(directories):
            entry_count += 1
            path = root_path / name
            paths.add(path.relative_to(workspace).as_posix() + "/")
            if path.is_symlink():
                directories.remove(name)
        for name in files:
            entry_count += 1
            path = root_path / name
            paths.add(path.relative_to(workspace).as_posix())
        if entry_count > MAX_WORKSPACE_INVENTORY_ENTRIES:
            return paths, False
    return paths, not traversal_errors


def _expected_workspace_entries(files: dict[str, str]) -> set[str]:
    expected = set(files)
    for raw_path in files:
        parent = Path(raw_path).parent
        while parent != Path("."):
            expected.add(parent.as_posix() + "/")
            parent = parent.parent
    return expected


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


INITIAL_DISCOVERY_COMMANDS = frozenset({
    "capabilities", "collaborators", "comments get", "comments list",
    "comments validate", "context", "handoff list", "help", "inbox",
    "inspect", "man", "outline", "read", "review", "slice", "stage list",
    "stage show", "suggest list", "suggest wait", "version", "workspace show",
})

PREWRITE_STATE_READ_COMMANDS = frozenset({
    "collaborators", "comments export", "comments get", "comments list",
    "comments validate", "context", "handoff list", "inbox", "inspect",
    "outline", "read", "review", "slice", "stage list", "stage show",
    "suggest list", "suggest wait", "workspace show",
})


def _avoided_redundant_initial_reads(events: tuple[CommandEvent, ...]) -> bool:
    """Detect overlapping context+inbox reads by one role before its first action."""
    roles = sorted({event.role for event in events})
    for role in roles:
        observed: set[str] = set()
        for event in (item for item in events if item.role == role):
            command = event.command
            is_discovery = (
                command in INITIAL_DISCOVERY_COMMANDS
                or command.startswith("help ")
                or command.startswith("man ")
            )
            if not is_discovery:
                break
            if event.exit_code == 0 and command in {"context", "inbox"}:
                observed.add(command)
        if observed == {"context", "inbox"}:
            return False
    return True


def _used_no_prewrite_state_reads(
    events: tuple[CommandEvent, ...],
    write_commands: frozenset[str],
) -> bool:
    """Separate unnecessary preliminary reads from post-write convergence checks."""
    roles = sorted({event.role for event in events})
    if not roles:
        return False
    for role in roles:
        reached_write = False
        for event in (item for item in events if item.role == role):
            if event.command in write_commands:
                reached_write = True
                break
            if event.command in PREWRITE_STATE_READ_COMMANDS:
                return False
        if not reached_write:
            return False
    return True


def _used_atomic_batch(
    events: tuple[CommandEvent, ...],
    *,
    require_every_role: bool,
) -> bool:
    """Report batch adoption without making it part of correctness or score."""
    roles = sorted({event.role for event in events})
    if not roles:
        return False
    adopted = [
        any(
            event.role == role
            and event.command == "suggest batch"
            and event.exit_code == 0
            for event in events
        )
        for role in roles
    ]
    return all(adopted) if require_every_role else any(adopted)


def _used_one_postwrite_verification_per_role(
    events: tuple[CommandEvent, ...],
    write_commands: frozenset[str],
) -> bool:
    """Distinguish one final check from an early finisher repeatedly polling."""
    roles = sorted({event.role for event in events})
    if not roles:
        return False
    for role in roles:
        role_events = [event for event in events if event.role == role]
        successful_writes = [
            index
            for index, event in enumerate(role_events)
            if event.command in write_commands and event.exit_code == 0
        ]
        if not successful_writes:
            return False
        after = role_events[successful_writes[-1] + 1:]
        successful_convergence_checks = sum(
            event.command in {"suggest list", "suggest wait"} and event.exit_code == 0
            for event in after
        )
        successful_reads = sum(
            event.command == "read" and event.exit_code == 0
            for event in after
        )
        if successful_convergence_checks != 1 or successful_reads != 1:
            return False
    return True


def _used_no_extra_postwrite_state_reads(
    events: tuple[CommandEvent, ...],
    write_commands: frozenset[str],
) -> bool:
    """Allow one convergence check and one literal read after the final write."""
    roles = sorted({event.role for event in events})
    if not roles:
        return False
    for role in roles:
        role_events = [event for event in events if event.role == role]
        successful_writes = [
            index
            for index, event in enumerate(role_events)
            if event.command in write_commands and event.exit_code == 0
        ]
        if not successful_writes:
            return False
        convergence_consumed = False
        source_read_consumed = False
        for event in role_events[successful_writes[-1] + 1:]:
            if event.exit_code != 0 or event.command not in PREWRITE_STATE_READ_COMMANDS:
                continue
            if (
                event.command in {"suggest list", "suggest wait"}
                and not convergence_consumed
            ):
                convergence_consumed = True
            elif event.command == "read" and not source_read_consumed:
                source_read_consumed = True
            else:
                return False
    return True


def _used_known_peer_wait(
    events: tuple[CommandEvent, ...],
    *,
    require_every_role: bool,
) -> bool:
    """Measure exact durable-id waiting without treating it as correctness."""
    roles = sorted({event.role for event in events})
    if not roles:
        return False
    adopted = [
        any(
            event.role == role
            and event.command == "suggest wait"
            and event.exit_code == 0
            for event in events
        )
        for role in roles
    ]
    return all(adopted) if require_every_role else any(adopted)


def _used_no_reverification_after_successful_wait(
    events: tuple[CommandEvent, ...],
) -> bool:
    """Treat a successful named wait as conclusive durable-state evidence.

    Roles that never wait are outside this diagnostic. Once a role has a
    successful wait, another successful wait or list is redundant; the task's
    separately required literal-source read remains allowed.
    """
    roles = sorted({event.role for event in events})
    for role in roles:
        role_events = [event for event in events if event.role == role]
        first_wait = next((
            index
            for index, event in enumerate(role_events)
            if event.command == "suggest wait" and event.exit_code == 0
        ), None)
        if first_wait is None:
            continue
        if any(
            event.command in {"suggest list", "suggest wait"}
            and event.exit_code == 0
            for event in role_events[first_wait + 1:]
        ):
            return False
    return True


def _used_expected_context_then_inbox(events: tuple[CommandEvent, ...]) -> bool:
    """Require the intentional broad-to-filtered discovery order before action."""
    found_pair = False
    roles = sorted({event.role for event in events})
    for role in roles:
        discovery: list[str] = []
        for event in (item for item in events if item.role == role):
            command = event.command
            is_discovery = (
                command in INITIAL_DISCOVERY_COMMANDS
                or command.startswith("help ")
                or command.startswith("man ")
            )
            if not is_discovery:
                break
            if event.exit_code == 0:
                discovery.append(command)
        if "context" not in discovery or "inbox" not in discovery:
            continue
        found_pair = True
        if discovery.index("context") > discovery.index("inbox"):
            return False
    return found_pair


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

    annotation_identity_checks: list[bool] = []
    annotation_body_checks: list[bool] = []
    annotation_kind_checks: list[bool] = []
    annotation_status_checks: list[bool] = []
    annotation_thread_checks: list[bool] = []
    annotation_property_checks: list[bool] = []
    attribution_checks: list[bool] = []
    for expected in episode.oracle.get("annotations", []):
        path = str(expected["path"])
        candidates = [item for item in by_file.get(path, []) if _id_matches(_annotation_id(item), str(expected["id"]))]
        identity_match = candidates[0] if len(candidates) == 1 else None
        annotation_identity_checks.append(identity_match is not None)
        annotation_body_checks.append(
            identity_match is not None
            and _annotation_body(identity_match) == expected.get("body")
        )
        attribution_checks.append(
            identity_match is not None
            and _creator_id(identity_match) == expected.get("creatorID")
        )
        if expected.get("kind"):
            annotation_kind_checks.append(
                identity_match is not None and _kind(identity_match) == expected["kind"]
            )
        if "status" in expected:
            annotation_status_checks.append(
                identity_match is not None and _status(identity_match) == expected["status"]
            )
        if expected.get("parentID"):
            parent = _parent_id(identity_match) if identity_match is not None else None
            annotation_thread_checks.append(
                isinstance(parent, str) and _id_matches(parent, str(expected["parentID"]))
            )
        if expected.get("rootID"):
            root = _root_id(identity_match) if identity_match is not None else None
            annotation_thread_checks.append(
                isinstance(root, str) and _id_matches(root, str(expected["rootID"]))
            )
        for property_check in expected.get("properties", []):
            path = property_check.get("path")
            annotation_property_checks.append(
                identity_match is not None
                and isinstance(path, list)
                and all(isinstance(component, str) for component in path)
                and _nested_property(identity_match, path) == property_check.get("equals")
            )

    all_items = [item for items in by_file.values() for item in items]
    workspace_paths, workspace_inventory_complete = _workspace_inventory(workspace)
    workspace_expected_paths = (
        workspace_inventory_complete
        and workspace_paths == _expected_workspace_entries(episode.files)
    )

    def body_for_reference(identifier: object) -> str:
        if not isinstance(identifier, str):
            return ""
        matches = [item for item in all_items if _id_matches(_annotation_id(item), identifier)]
        return _annotation_body(matches[0]) if len(matches) == 1 else ""

    diagnostic_checks: dict[str, bool] = {}
    reference = episode.oracle.get("reference")
    if isinstance(reference, dict) and episode.scenario_id == "suggestion_contention":
        suggestion_writes = frozenset({"suggest add", "suggest batch"})
        diagnostic_checks = {
            "diagnostic_no_prewrite_state_reads": _used_no_prewrite_state_reads(
                events, suggestion_writes
            ),
            "diagnostic_atomic_batch_used_anywhere": _used_atomic_batch(
                events, require_every_role=False
            ),
            "diagnostic_atomic_batch_used_by_all_roles": _used_atomic_batch(
                events, require_every_role=True
            ),
            "diagnostic_one_postwrite_verification_per_role": (
                _used_one_postwrite_verification_per_role(events, suggestion_writes)
            ),
            "diagnostic_no_extra_postwrite_state_reads": (
                _used_no_extra_postwrite_state_reads(events, suggestion_writes)
            ),
            "diagnostic_known_peer_wait_used_anywhere": _used_known_peer_wait(
                events, require_every_role=False
            ),
            "diagnostic_known_peer_wait_used_by_all_roles": _used_known_peer_wait(
                events, require_every_role=True
            ),
            "diagnostic_no_reverification_after_successful_wait": (
                _used_no_reverification_after_successful_wait(events)
            ),
        }
    elif isinstance(reference, dict) and episode.scenario_id == "specialist_audit":
        decision_body = body_for_reference(reference.get("decisionID"))
        issue_body = body_for_reference(reference.get("issueID"))
        performance_choice = reference.get("performanceChoice")
        secure_choice = reference.get("secureChoice")
        diagnostic_checks = {
            "diagnostic_decision_fact_recovered": (
                isinstance(performance_choice, str) and performance_choice in decision_body
            ),
            "diagnostic_recorded_choice_recovered": (
                isinstance(performance_choice, str) and performance_choice in issue_body
            ),
            "diagnostic_secure_choice_recovered": (
                isinstance(secure_choice, str) and secure_choice in issue_body
            ),
            "diagnostic_sentence_shape_valid": (
                issue_body.startswith("Security correction: ")
                and issue_body.endswith(".")
                and issue_body.count(" is ineligible; choose ") == 1
            ),
            "diagnostic_template_markers_absent": not any(
                marker in issue_body for marker in ("ORIGINAL", "SECURE", "A-TOKEN", "NAME")
            ),
        }
    elif isinstance(reference, dict) and episode.scenario_id == "distributed_synthesis":
        handoff_body = body_for_reference(reference.get("handoffID"))
        reply_body = body_for_reference(reference.get("replyID"))
        evidence_a = reference.get("evidenceA")
        evidence_b = reference.get("evidenceB")
        diagnostic_checks = {
            "diagnostic_handoff_evidence_recovered": (
                isinstance(evidence_a, str) and evidence_a in handoff_body
            ),
            "diagnostic_reply_handoff_evidence_recovered": (
                isinstance(evidence_a, str) and evidence_a in reply_body
            ),
            "diagnostic_reply_private_evidence_recovered": (
                isinstance(evidence_b, str) and evidence_b in reply_body
            ),
            "diagnostic_sentence_shape_valid": (
                reply_body.startswith("Synthesis: ")
                and reply_body.endswith(".")
                and reply_body.count(" + ") == 1
            ),
            "diagnostic_template_markers_absent": not any(
                marker in reply_body for marker in ("ORIGINAL", "SECURE", "A-TOKEN", "NAME")
            ),
        }
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

    successful_commands = [event.command for event in events if event.exit_code == 0]
    error_codes = [event.error_code for event in events if event.error_code]
    required_groups = episode.oracle.get("requiredCommandGroups")
    if required_groups is None:
        required_groups = [[required] for required in episode.oracle.get("requiredCommands", [])]
    required_command_checks = [
        any(
            actual == alternative or actual.startswith(alternative + " ")
            for actual in successful_commands
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

    annotation_check_groups = {
        "annotation_identity": annotation_identity_checks,
        "annotation_body": annotation_body_checks,
        "annotation_kind": annotation_kind_checks,
        "annotation_status": annotation_status_checks,
        "annotation_thread": annotation_thread_checks,
        "annotation_properties": annotation_property_checks,
    }
    granular_annotation_checks = {
        name: all(values) if values else True
        for name, values in annotation_check_groups.items()
    }
    checks = {
        "all_expected_annotations": all(granular_annotation_checks.values()),
        **granular_annotation_checks,
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
        "workspace_expected_paths": workspace_expected_paths,
        "workspace_policy": not blocked,
        "valid_command_use": valid_command_use,
        "avoided_redundant_initial_reads": (
            _used_expected_context_then_inbox(events)
            if episode.oracle.get("contextThenInboxIsExpected") is True
            else _avoided_redundant_initial_reads(events)
        ),
        **diagnostic_checks,
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
            checks["workspace_expected_paths"],
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
        and checks["workspace_expected_paths"]
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
