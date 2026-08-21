"""Bounded, content-free command outcomes for publishable run artifacts."""

from __future__ import annotations

from collections import Counter, defaultdict
from collections.abc import Iterable
from typing import Any

from .gateway import ALLOWED_COMMANDS
from .schema import CommandEvent


MAX_EVENT_SUMMARY_ROWS = 64
SAFE_ERROR_CODES = frozenset({
    "ANCHOR_AMBIGUOUS", "ANCHOR_NOT_FOUND", "CANNOT_CREATE",
    "COLLABORATION_IO_ERROR", "COLLABORATION_LOCK_TIMEOUT",
    "COLLABORATION_PRECONDITION_FAILED", "COLLABORATION_RECOVERY_FAILED",
    "COLLABORATION_ROLLBACK_FAILED", "COLLABORATION_TRANSACTION_FAILED",
    "COMMENT_HAS_REPLIES", "COMMENT_NOT_ANCHORED", "COMMENT_NOT_FOUND",
    "CONCURRENT_MODIFICATION", "CONTENT_CONFLICT", "CONTENT_HASH_MISMATCH",
    "CONTENT_LENGTH_MISMATCH", "DUPLICATE_COLLABORATION_TARGET",
    "EXPECTED_TEXT_MISMATCH", "FILE_READ_FAILED", "ID_CONFLICT",
    "INPUT_TOO_LARGE", "INTERNAL_ERROR", "INVALID_ACTOR", "INVALID_ANCHOR",
    "INVALID_CHANGE_SET_JSON", "INVALID_COLLABORATION_ACTIVITY",
    "INVALID_COLLABORATION_ACTOR", "INVALID_COLLABORATION_CHANGE_SET",
    "INVALID_COLLABORATION_CONTRIBUTION", "INVALID_COLLABORATION_CURSOR",
    "INVALID_COLLABORATION_PATH", "INVALID_COLLABORATION_ROOT",
    "INVALID_COMMENT_ENVELOPE", "INVALID_MESSAGE", "INVALID_STAGE_INTENT",
    "INVALID_STDIN", "INVALID_SUGGESTION_RANGE", "INVALID_UTF8",
    "INVALID_WORKSPACE_MANIFEST", "IO_ERROR", "LOCK_TIMEOUT",
    "MARGINBENCH_ARGUMENT_LIMIT", "MARGINBENCH_COMMAND_BLOCKED",
    "MARGINBENCH_EXECUTION", "MARGINBENCH_IDENTITY_BOUND",
    "MARGINBENCH_INVALID_ARGUMENTS", "MARGINBENCH_INVALID_STDIN",
    "MARGINBENCH_OUTPUT_LIMIT", "MARGINBENCH_STDIN_LIMIT",
    "MARGINBENCH_RENDEZVOUS_FAILED",
    "MARGINBENCH_TIMEOUT", "MARGINBENCH_WORKSPACE_ESCAPE",
    "MESSAGE_READ_FAILED", "MULTIPLE_COMMENT_BLOCKS", "NONTERMINAL_COMMENT_BLOCK",
    "NOT_FOUND", "OUTPUT_CREATE_FAILED", "OUTPUT_EXISTS", "OUTPUT_IS_DIRECTORY",
    "OUTPUT_WRITE_FAILED", "PARENT_NOT_DIRECTORY", "PATH_ESCAPES_ROOT",
    "RECONCILE_BASE_HAS_NO_ANNOTATIONS", "RECONCILE_ENVELOPE_CHANGED",
    "RECONCILE_NEEDS_ATTENTION", "RECONCILE_NOT_NEEDED", "REVISION_CONFLICT",
    "ROOT_MISMATCH", "STAGE_NOT_FOUND", "STAGE_SHOW_TOO_LARGE",
    "STATIC_OUTPUT_TOO_LARGE", "SUGGESTION_NOT_ANCHORED", "SYMLINK_NOT_ALLOWED",
    "THREAD_RESOLVED", "UNDO_CONFLICT", "UNSAFE_OUTPUT",
    "UNSUPPORTED_COLLABORATION_VERSION", "UNSUPPORTED_PROTOCOL_VERSION", "USAGE",
    "WATCH_ALREADY_STARTED", "WATCH_FAILED", "WATCH_READ_FAILED",
})
SAFE_SUBCOMMANDS = {
    "comments": frozenset({
        "add", "delete", "edit", "export", "get", "list", "reanchor",
        "reopen", "reply", "resolve", "validate", "watch",
    }),
    "handoff": frozenset({"add", "list"}),
    "stage": frozenset({"create", "discard", "list", "refresh", "show", "submit"}),
    "suggest": frozenset({"accept", "add", "list", "reject"}),
    "workspace": frozenset({"init", "show"}),
}
SAFE_VARIANTS = frozenset({
    "comments reply --resolve",
    "stage refresh --submit",
})
SAFE_PUBLIC_COMMANDS = (
    ALLOWED_COMMANDS
    | frozenset(
        f"{command} {subcommand}"
        for command, subcommands in SAFE_SUBCOMMANDS.items()
        for subcommand in subcommands
    )
    | SAFE_VARIANTS
    | frozenset({"unknown"})
)


def _safe_command(value: str) -> str:
    """Keep only static grammar labels; never publish arguments or identifiers."""
    if value in SAFE_PUBLIC_COMMANDS:
        return value
    parts = value.split()
    if not parts or parts[0] not in ALLOWED_COMMANDS:
        return "unknown"
    if (
        len(parts) == 2
        and parts[0] in SAFE_SUBCOMMANDS
        and parts[1] in SAFE_SUBCOMMANDS[parts[0]]
    ):
        return value
    return parts[0]


def _safe_error(value: str | None) -> str:
    if value in SAFE_ERROR_CODES:
        return value
    return "UNCLASSIFIED"


def _bounded_counts(values: Counter[str]) -> tuple[list[dict[str, Any]], bool]:
    ordered = sorted(values.items(), key=lambda item: (-item[1], item[0]))
    if len(ordered) <= MAX_EVENT_SUMMARY_ROWS:
        return [
            {"name": name, "count": count}
            for name, count in ordered
        ], False
    retained = ordered[: MAX_EVENT_SUMMARY_ROWS - 1]
    omitted = sum(count for _, count in ordered[MAX_EVENT_SUMMARY_ROWS - 1 :])
    return [
        *({"name": name, "count": count} for name, count in retained),
        {"name": "OTHER", "count": omitted},
    ], True


def summarize_command_events(events: Iterable[CommandEvent]) -> dict[str, Any]:
    """Summarize command outcomes without retaining any user-controlled values."""
    materialized = tuple(events)
    command_counts: dict[str, Counter[str]] = defaultdict(Counter)
    errors: Counter[str] = Counter()
    success_count = failure_count = blocked_count = 0
    for event in materialized:
        command = _safe_command(event.command)
        succeeded = event.exit_code == 0
        success_count += int(succeeded)
        failure_count += int(not succeeded)
        blocked_count += int(event.blocked)
        command_counts[command]["count"] += 1
        command_counts[command]["successCount"] += int(succeeded)
        command_counts[command]["failureCount"] += int(not succeeded)
        command_counts[command]["blockedCount"] += int(event.blocked)
        if not succeeded:
            errors[_safe_error(event.error_code)] += 1

    commands = [
        {"name": name, **dict(counts)}
        for name, counts in sorted(
            command_counts.items(),
            key=lambda item: (-item[1]["count"], item[0]),
        )
    ]
    error_rows, truncated = _bounded_counts(errors)
    return {
        "commandCount": len(materialized),
        "successCount": success_count,
        "failureCount": failure_count,
        "blockedCount": blocked_count,
        "commands": commands,
        "errors": error_rows,
        "isTruncated": truncated,
    }
