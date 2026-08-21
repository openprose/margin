"""Content-free command-shape diagnostics for private Prime traces."""

from __future__ import annotations

import hashlib
import json
import re
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any

from .gateway import ALLOWED_COMMANDS, BOOLEAN_OPTIONS, VALUE_OPTIONS, event_command_path
from .scenarios import AVAILABLE_SCENARIO_IDS


TRACE_SHAPE_SCHEMA = "urn:marginbench:trace-shape-report:v1"
MAX_SOURCES = 32
MAX_SOURCE_BYTES = 256 * 1_024 * 1_024
MAX_LINE_BYTES = 16 * 1_024 * 1_024
MAX_TRACES = 10_000
MAX_TOOL_CALLS = 1_000_000
MAX_SEQUENCE_LENGTH = 128
MAX_COMMAND_SIGNATURES = 4_096
RESULT_SIZE_BUCKETS = (
    (1_024, "1-1024"),
    (4_096, "1025-4096"),
    (16_384, "4097-16384"),
    (65_536, "16385-65536"),
)
RESULT_SIZE_OVERFLOW_BUCKET = "65537+"
SAFE_NAME = re.compile(r"^[A-Za-z][A-Za-z0-9_.-]{0,127}$")
SAFE_SUBCOMMANDS = {
    "comments": frozenset({
        "add", "delete", "edit", "export", "get", "list", "reanchor",
        "reopen", "reply", "resolve", "validate", "watch",
    }),
    "handoff": frozenset({"add", "list"}),
    "stage": frozenset({"create", "discard", "list", "refresh", "show", "submit"}),
    "suggest": frozenset({"accept", "add", "batch", "list", "reject", "wait"}),
    "workspace": frozenset({"init", "show"}),
}
SAFE_MAN_TOPICS = {
    "agent": "agents", "agents": "agents", "comment": "comments",
    "comments": "comments", "handoff": "handoff", "handoffs": "handoff",
    "margin": "agents", "merge": "merge", "overview": "agents",
    "reconcile": "merge", "reconciliation": "merge", "review": "review",
    "safety": "safety", "security": "safety", "stage": "staging",
    "stages": "staging", "staging": "staging", "start": "agents",
    "suggest": "suggestions", "suggestion": "suggestions",
    "suggestions": "suggestions", "workflow": "agents", "workflows": "agents",
}
BOUNDARY_ERRORS = frozenset({
    "MARGINBENCH_ARGUMENT_LIMIT",
    "MARGINBENCH_COMMAND_BLOCKED",
    "MARGINBENCH_IDENTITY_BOUND",
    "MARGINBENCH_INVALID_ARGUMENTS",
    "MARGINBENCH_INVALID_STDIN",
    "MARGINBENCH_STDIN_LIMIT",
    "MARGINBENCH_WORKSPACE_ESCAPE",
    "INVALID_CONTENT",
    "INVALID_MARKDOWN",
    "INVALID_RANGE",
    "UNSAFE_PATH",
    "UNSUPPORTED_FILE",
})
WORKSPACE_ACTIONS = frozenset({"guide", "list", "read", "write"})
KNOWN_FLAGS = VALUE_OPTIONS | BOOLEAN_OPTIONS | frozenset({
    "--contribution-id", "--max-source-bytes", "--parent",
})
WRITE_COMMANDS = frozenset({
    "comments add",
    "comments delete",
    "comments edit",
    "comments reanchor",
    "comments reopen",
    "comments reply",
    "comments reply --resolve",
    "comments resolve",
    "handoff add",
    "merge",
    "reconcile",
    "stage create",
    "stage discard",
    "stage refresh",
    "stage refresh --submit",
    "stage submit",
    "suggest accept",
    "suggest add",
    "suggest batch",
    "suggest reject",
    "transact",
    "workspace init",
    "workspace write",
})
SUGGESTION_BATCH_TEACHING_COMMANDS = frozenset({
    "help suggest add",
    "help suggest batch",
    "man suggestions",
})
SUGGESTION_WRITE_COMMANDS = frozenset({"suggest add", "suggest batch"})
SUGGESTION_REVERIFICATION_COMMANDS = frozenset({"suggest list", "suggest wait"})
SUGGESTION_STATE_READ_COMMANDS = frozenset({
    "collaborators", "comments export", "comments get", "comments list",
    "comments validate", "context", "handoff list", "inbox", "inspect",
    "outline", "read", "review", "slice", "stage list", "stage show",
    "suggest list", "suggest wait", "workspace show",
})
SUGGESTION_MECHANISM_FIELDS = (
    "applicableTraceCount",
    "batchTeachingViewedBeforeWriteTraceCount",
    "batchAdoptionTraceCount",
    "batchAdoptionAfterTeachingTraceCount",
    "individualAddTraceCount",
    "individualAddAfterTeachingTraceCount",
    "waitReceiptObservedTraceCount",
    "waitReceiptTrustedTraceCount",
    "postWaitReverificationTraceCount",
    "preWriteStateReadTraceCount",
    "extraPostWriteStateReadTraceCount",
)


class TraceShapeError(ValueError):
    """A bounded or malformed private trace could not be summarized safely."""


def _sources(paths: list[Path]) -> list[Path]:
    if not 1 <= len(paths) <= MAX_SOURCES:
        raise TraceShapeError(f"Provide between 1 and {MAX_SOURCES} trace paths.")
    values: list[Path] = []
    for original in paths:
        path = original.expanduser()
        if path.is_dir():
            path = path / "traces.jsonl"
        if path.is_symlink() or not path.is_file():
            raise TraceShapeError("Each input must be a regular traces.jsonl file or its directory.")
        resolved = path.resolve()
        if resolved not in values:
            values.append(resolved)
    if sum(path.stat().st_size for path in values) > MAX_SOURCE_BYTES:
        raise TraceShapeError(f"Trace inputs exceed the {MAX_SOURCE_BYTES}-byte aggregate limit.")
    return values


def _safe_scenario(value: object) -> str:
    return value if isinstance(value, str) and value in AVAILABLE_SCENARIO_IDS else "unknown"


def _safe_seat(value: object) -> str:
    return value if value in {"agent", "author", "reviewer"} else "unknown"


def _safe_error(value: object) -> str:
    return value if isinstance(value, str) and SAFE_NAME.fullmatch(value) else "UNCLASSIFIED"


def _safe_help_command(semantic: str) -> str:
    """Retain only a static documented help target, never a user argument."""
    if semantic == "help":
        return semantic
    values = semantic.split()
    if len(values) not in {2, 3} or values[0] != "help":
        return "help"
    top = values[1]
    if top not in ALLOWED_COMMANDS:
        return "help"
    if len(values) == 3:
        subcommand = values[2]
        if subcommand not in SAFE_SUBCOMMANDS.get(top, frozenset()):
            return f"help {top}"
    return semantic


def _safe_command(arguments: list[str]) -> tuple[str, bool]:
    leading = arguments[:1] == ["margin"]
    values = arguments[1:] if leading else arguments
    if not values:
        return "unknown", leading
    if values[0] in {"-h", "--help"}:
        return "help", leading
    if values[0] not in ALLOWED_COMMANDS:
        missing_command = any(
            token.split("=", 1)[0] in KNOWN_FLAGS
            for token in values[1:]
            if token.startswith("-")
        )
        return ("missing-command" if missing_command else "unknown"), leading
    top = values[0]
    if top == "man" and len(values) > 1 and values[1] in SAFE_MAN_TOPICS:
        return f"man {SAFE_MAN_TOPICS[values[1]]}", leading
    semantic = event_command_path(values)
    if semantic == "help" or semantic.startswith("help "):
        return _safe_help_command(semantic), leading
    if semantic == "suggest batch":
        return semantic, leading
    if semantic in {"comments reply --resolve", "stage refresh --submit"}:
        return semantic, leading
    if semantic == "comments reply" and top == "comments":
        return semantic, leading
    if top in SAFE_SUBCOMMANDS and len(values) > 1 and values[1] in SAFE_SUBCOMMANDS[top]:
        return f"{top} {values[1]}", leading
    return top, leading


def _safe_flags(arguments: list[str]) -> list[str]:
    return sorted({
        token.split("=", 1)[0]
        for token in arguments
        if token.startswith("-") and token.split("=", 1)[0] in KNOWN_FLAGS
    })


def _tool_arguments(call: dict[str, Any]) -> list[str]:
    raw = call.get("arguments")
    try:
        payload = json.loads(raw) if isinstance(raw, str) else raw
    except json.JSONDecodeError:
        return []
    values = payload.get("arguments") if isinstance(payload, dict) else None
    if not isinstance(values, list) or len(values) > 128:
        return []
    return [str(value) for value in values if isinstance(value, (str, int)) and not isinstance(value, bool)]


def _tool_descriptor(call: dict[str, Any]) -> tuple[str, bool, list[str], str]:
    """Return a content-free command shape for either supported tool surface."""
    if call.get("name") == "workspace":
        raw = call.get("arguments")
        try:
            payload = json.loads(raw) if isinstance(raw, str) else raw
        except json.JSONDecodeError:
            payload = None
        action = payload.get("action") if isinstance(payload, dict) else None
        command = f"workspace {action}" if action in WORKSPACE_ACTIONS else "workspace unknown"
        return command, False, [], "workspace"
    arguments = _tool_arguments(call)
    command, leading = _safe_command(arguments)
    return command, leading, _safe_flags(arguments), "margin"


def _tool_result(message: dict[str, Any]) -> dict[str, Any]:
    raw = message.get("content")
    try:
        value = json.loads(raw) if isinstance(raw, str) else raw
    except json.JSONDecodeError:
        return {}
    return value if isinstance(value, dict) else {}


def _result_size_bucket(message: dict[str, Any]) -> str:
    """Coarsen agent-visible result size without retaining an exact payload size."""
    raw = message.get("content")
    if isinstance(raw, str):
        byte_count = len(raw.encode("utf-8"))
    elif raw is None:
        byte_count = 0
    else:
        byte_count = len(
            json.dumps(raw, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
            .encode("utf-8")
        )
    if byte_count == 0:
        return "0"
    for maximum, name in RESULT_SIZE_BUCKETS:
        if byte_count <= maximum:
            return name
    return RESULT_SIZE_OVERFLOW_BUCKET


def _counts(counter: Counter[str], maximum: int = 256) -> list[dict[str, Any]]:
    return [
        {"name": name, "count": count}
        for name, count in sorted(counter.items(), key=lambda item: (-item[1], item[0]))[:maximum]
    ]


def _command_rows(values: dict[str, Counter[str]]) -> list[dict[str, Any]]:
    return [
        {"name": name, **dict(counts)}
        for name, counts in sorted(
            values.items(),
            key=lambda item: (-item[1]["count"], item[0]),
        )
    ]


def _command_bucket_rows(
    values: dict[str, Counter[str]],
) -> list[dict[str, Any]]:
    return [
        {"command": command, "buckets": _counts(buckets)}
        for command, buckets in sorted(values.items())
    ]


def _sequence_rows(
    values: Counter[tuple[str, ...]],
    *,
    maximum: int,
) -> list[dict[str, Any]]:
    return [
        {"commands": list(sequence), "count": count}
        for sequence, count in sorted(
            values.items(),
            key=lambda item: (-item[1], item[0]),
        )[:maximum]
    ]


def _pre_write_bucket(call_count: int | None) -> str:
    if call_count is None:
        return "none"
    if call_count == 0:
        return "0"
    if call_count <= 2:
        return "1-2"
    if call_count <= 4:
        return "3-4"
    if call_count <= 6:
        return "5-6"
    return "7+"


def _write_latency(trace_count: int, write_attempt_count: int, buckets: Counter[str]) -> dict[str, Any]:
    without_write = buckets.get("none", 0)
    return {
        "traceCount": trace_count,
        "tracesWithWriteAttempt": trace_count - without_write,
        "tracesWithoutWriteAttempt": without_write,
        "writeAttemptCount": write_attempt_count,
        "preWriteToolCallBuckets": _counts(buckets),
    }


def _suggestion_mechanism_counts(successful_sequence: list[str]) -> Counter[str]:
    """Project one suggestion-contention role into content-free mechanism counts."""
    counts: Counter[str] = Counter({"applicableTraceCount": 1})
    first_write = next(
        (
            index
            for index, command in enumerate(successful_sequence)
            if command in SUGGESTION_WRITE_COMMANDS
        ),
        None,
    )
    teaching_viewed = first_write is not None and any(
        command in SUGGESTION_BATCH_TEACHING_COMMANDS
        for command in successful_sequence[:first_write]
    )
    batch_adopted = "suggest batch" in successful_sequence
    individual_add_used = "suggest add" in successful_sequence
    counts["batchTeachingViewedBeforeWriteTraceCount"] += int(teaching_viewed)
    counts["batchAdoptionTraceCount"] += int(batch_adopted)
    counts["batchAdoptionAfterTeachingTraceCount"] += int(
        teaching_viewed and batch_adopted
    )
    counts["individualAddTraceCount"] += int(individual_add_used)
    counts["individualAddAfterTeachingTraceCount"] += int(
        teaching_viewed and individual_add_used
    )

    first_wait = next(
        (
            index
            for index, command in enumerate(successful_sequence)
            if command == "suggest wait"
        ),
        None,
    )
    wait_observed = first_wait is not None
    reverified = wait_observed and any(
        command in SUGGESTION_REVERIFICATION_COMMANDS
        for command in successful_sequence[first_wait + 1 :]
    )
    counts["waitReceiptObservedTraceCount"] += int(wait_observed)
    counts["waitReceiptTrustedTraceCount"] += int(wait_observed and not reverified)
    counts["postWaitReverificationTraceCount"] += int(reverified)

    prewrite_state_read = first_write is not None and any(
        command in SUGGESTION_STATE_READ_COMMANDS
        for command in successful_sequence[:first_write]
    )
    counts["preWriteStateReadTraceCount"] += int(prewrite_state_read)

    last_write = next(
        (
            index
            for index in range(len(successful_sequence) - 1, -1, -1)
            if successful_sequence[index] in SUGGESTION_WRITE_COMMANDS
        ),
        None,
    )
    convergence_consumed = False
    source_read_consumed = False
    extra_postwrite_state_read = False
    if last_write is not None:
        for command in successful_sequence[last_write + 1:]:
            if command not in SUGGESTION_STATE_READ_COMMANDS:
                continue
            if (
                command in SUGGESTION_REVERIFICATION_COMMANDS
                and not convergence_consumed
            ):
                convergence_consumed = True
            elif command == "read" and not source_read_consumed:
                source_read_consumed = True
            else:
                extra_postwrite_state_read = True
                break
    counts["extraPostWriteStateReadTraceCount"] += int(extra_postwrite_state_read)
    return counts


def _suggestion_mechanism_report(counts: Counter[str]) -> dict[str, int]:
    return {field: counts[field] for field in SUGGESTION_MECHANISM_FIELDS}


def summarize_trace_shapes(paths: list[Path]) -> dict[str, Any]:
    sources = _sources(paths)
    source_receipts = []
    traces: list[dict[str, Any]] = []
    candidate_margin_sha256s: set[str] = set()
    for path in sources:
        digest = hashlib.sha256()
        byte_count = 0
        with path.open("rb") as handle:
            for raw in handle:
                byte_count += len(raw)
                digest.update(raw)
                if len(raw) > MAX_LINE_BYTES:
                    raise TraceShapeError("A trace line exceeds the bounded parser limit.")
                try:
                    envelope = json.loads(raw)
                except (UnicodeDecodeError, json.JSONDecodeError) as error:
                    raise TraceShapeError("Trace input must be UTF-8 JSONL.") from error
                values = envelope.get("traces") if isinstance(envelope, dict) else None
                if isinstance(values, list):
                    for value in values:
                        if not isinstance(value, dict):
                            continue
                        traces.append(value)
                        info = value.get("info") if isinstance(value.get("info"), dict) else {}
                        marginbench = (
                            info.get("marginbench")
                            if isinstance(info.get("marginbench"), dict)
                            else {}
                        )
                        candidate_digest = marginbench.get("marginSha256")
                        if (
                            isinstance(candidate_digest, str)
                            and re.fullmatch(r"[0-9a-f]{64}", candidate_digest)
                        ):
                            candidate_margin_sha256s.add(candidate_digest)
                if len(traces) > MAX_TRACES:
                    raise TraceShapeError(f"Trace count exceeds {MAX_TRACES}.")
        source_receipts.append({
            "sha256": digest.hexdigest(),
            "byteCount": byte_count,
        })

    commands: dict[str, Counter[str]] = defaultdict(Counter)
    command_signatures: dict[tuple[str, tuple[str, ...]], Counter[str]] = defaultdict(Counter)
    command_signature_errors: dict[
        tuple[str, tuple[str, ...]], Counter[str]
    ] = defaultdict(Counter)
    command_signature_result_size_buckets: dict[
        tuple[str, tuple[str, ...]], Counter[str]
    ] = defaultdict(Counter)
    errors: Counter[str] = Counter()
    flags: Counter[str] = Counter()
    unanswered_commands: Counter[str] = Counter()
    final_finish_reasons: Counter[str] = Counter()
    stop_conditions: Counter[str] = Counter()
    sequences: Counter[tuple[str, ...]] = Counter()
    scenarios: dict[str, Counter[str]] = defaultdict(Counter)
    scenario_finish_reasons: dict[str, Counter[str]] = defaultdict(Counter)
    scenario_stop_conditions: dict[str, Counter[str]] = defaultdict(Counter)
    scenario_commands: dict[str, dict[str, Counter[str]]] = defaultdict(
        lambda: defaultdict(Counter)
    )
    scenario_errors: dict[str, Counter[str]] = defaultdict(Counter)
    scenario_flags: dict[str, Counter[str]] = defaultdict(Counter)
    scenario_unanswered_commands: dict[str, Counter[str]] = defaultdict(Counter)
    scenario_sequences: dict[str, Counter[tuple[str, ...]]] = defaultdict(Counter)
    result_size_buckets: Counter[str] = Counter()
    command_result_size_buckets: dict[str, Counter[str]] = defaultdict(Counter)
    scenario_result_size_buckets: dict[str, Counter[str]] = defaultdict(Counter)
    scenario_command_result_size_buckets: dict[
        str, dict[str, Counter[str]]
    ] = defaultdict(lambda: defaultdict(Counter))
    pre_write_tool_call_buckets: Counter[str] = Counter()
    scenario_pre_write_tool_call_buckets: dict[str, Counter[str]] = defaultdict(Counter)
    write_attempt_count = 0
    scenario_write_attempt_count: Counter[str] = Counter()
    suggestion_mechanisms: Counter[str] = Counter()
    scenario_suggestion_mechanisms: dict[str, Counter[str]] = defaultdict(Counter)
    tool_calls = successes = failures = blocked = leading_count = 0

    for trace in traces:
        task = trace.get("task") if isinstance(trace.get("task"), dict) else {}
        data = task.get("data") if isinstance(task.get("data"), dict) else {}
        scenario = _safe_scenario(data.get("scenario_id"))
        agent = trace.get("agent") if isinstance(trace.get("agent"), dict) else {}
        seat = _safe_seat(agent.get("name"))
        scenario_key = f"{scenario}:{seat}"
        scenarios[scenario_key]["traceCount"] += 1
        calls = trace.get("calls") if isinstance(trace.get("calls"), list) else []
        if calls:
            final_finish = _safe_error(calls[-1].get("finish_reason"))
            final_finish_reasons[final_finish] += 1
            scenario_finish_reasons[scenario_key][final_finish] += 1
        if trace.get("stop_condition") is not None:
            stop = _safe_error(trace.get("stop_condition"))
            stop_conditions[stop] += 1
            scenario_stop_conditions[scenario_key][stop] += 1
        pending: dict[str, tuple[str, bool, list[str], str]] = {}
        sequence: list[str] = []
        successful_sequence: list[str] = []
        issued_before_first_write = 0
        first_write_after: int | None = None
        trace_write_attempt_count = 0
        nodes = trace.get("nodes") if isinstance(trace.get("nodes"), list) else []
        for node in nodes:
            message = node.get("message") if isinstance(node, dict) else None
            if not isinstance(message, dict):
                continue
            calls = message.get("tool_calls")
            if isinstance(calls, list):
                for call in calls:
                    if not isinstance(call, dict):
                        continue
                    if len(pending) + tool_calls >= MAX_TOOL_CALLS:
                        raise TraceShapeError(f"Tool call count exceeds {MAX_TOOL_CALLS}.")
                    command, leading, command_flags, surface = _tool_descriptor(call)
                    if command in WRITE_COMMANDS:
                        trace_write_attempt_count += 1
                        if first_write_after is None:
                            first_write_after = issued_before_first_write
                    elif first_write_after is None:
                        issued_before_first_write += 1
                    identifier = call.get("id")
                    if isinstance(identifier, str) and len(identifier) <= 512:
                        pending[identifier] = (command, leading, command_flags, surface)
            if message.get("role") != "tool":
                continue
            identifier = message.get("tool_call_id")
            descriptor = pending.pop(identifier, None) if isinstance(identifier, str) else None
            if descriptor is None:
                continue
            command, leading, command_flags, surface = descriptor
            result = _tool_result(message)
            ok = result.get("ok") is True and (
                surface == "workspace" or result.get("exitCode") == 0
            )
            raw_error = result.get("errorCode")
            if surface == "workspace" and isinstance(result.get("error"), dict):
                raw_error = result["error"].get("code")
            error = None if ok else _safe_error(raw_error)
            is_blocked = error in BOUNDARY_ERRORS
            size_bucket = _result_size_bucket(message)
            tool_calls += 1
            successes += int(ok)
            failures += int(not ok)
            blocked += int(is_blocked)
            leading_count += int(leading)
            commands[command]["count"] += 1
            commands[command]["successCount"] += int(ok)
            commands[command]["failureCount"] += int(not ok)
            commands[command]["blockedCount"] += int(is_blocked)
            scenario_commands[scenario_key][command]["count"] += 1
            scenario_commands[scenario_key][command]["successCount"] += int(ok)
            scenario_commands[scenario_key][command]["failureCount"] += int(not ok)
            scenario_commands[scenario_key][command]["blockedCount"] += int(is_blocked)
            scenarios[scenario_key]["toolCallCount"] += 1
            scenarios[scenario_key]["failureCount"] += int(not ok)
            scenarios[scenario_key]["blockedCount"] += int(is_blocked)
            scenarios[scenario_key]["leadingLiteralMarginCount"] += int(leading)
            result_size_buckets[size_bucket] += 1
            command_result_size_buckets[command][size_bucket] += 1
            scenario_result_size_buckets[scenario_key][size_bucket] += 1
            scenario_command_result_size_buckets[scenario_key][command][size_bucket] += 1
            if error is not None:
                errors[error] += 1
                scenario_errors[scenario_key][error] += 1
            flags.update(command_flags)
            scenario_flags[scenario_key].update(command_flags)
            signature_key = (command, tuple(command_flags))
            if signature_key not in command_signatures and len(command_signatures) >= MAX_COMMAND_SIGNATURES:
                raise TraceShapeError(
                    f"Distinct command signature count exceeds {MAX_COMMAND_SIGNATURES}."
                )
            command_signatures[signature_key]["count"] += 1
            command_signatures[signature_key]["successCount"] += int(ok)
            command_signatures[signature_key]["failureCount"] += int(not ok)
            command_signatures[signature_key]["blockedCount"] += int(is_blocked)
            command_signature_result_size_buckets[signature_key][size_bucket] += 1
            if error is not None:
                command_signature_errors[signature_key][error] += 1
            if len(sequence) < MAX_SEQUENCE_LENGTH:
                sequence.append(command)
            # The published generic sequence is deliberately capped, but these
            # fixed mechanism counters must still see every bounded tool call.
            # Otherwise a long orientation phase could hide later adoption.
            if ok:
                successful_sequence.append(command)
        if sequence:
            sequences[tuple(sequence)] += 1
            scenario_sequences[scenario_key][tuple(sequence)] += 1
        if scenario == "suggestion_contention":
            mechanism_counts = _suggestion_mechanism_counts(successful_sequence)
            suggestion_mechanisms.update(mechanism_counts)
            scenario_suggestion_mechanisms[scenario_key].update(mechanism_counts)
        write_attempt_count += trace_write_attempt_count
        scenario_write_attempt_count[scenario_key] += trace_write_attempt_count
        pre_write_bucket = _pre_write_bucket(first_write_after)
        pre_write_tool_call_buckets[pre_write_bucket] += 1
        scenario_pre_write_tool_call_buckets[scenario_key][pre_write_bucket] += 1
        for command, _, _, _ in pending.values():
            unanswered_commands[command] += 1
            scenario_unanswered_commands[scenario_key][command] += 1
            scenarios[scenario_key]["unansweredToolCallCount"] += 1

    command_rows = _command_rows(commands)
    command_signature_rows = [
        {
            "command": command,
            "flags": list(signature_flags),
            **dict(values),
            "errors": _counts(command_signature_errors[(command, signature_flags)]),
            "resultSizeBuckets": _counts(
                command_signature_result_size_buckets[(command, signature_flags)]
            ),
        }
        for (command, signature_flags), values in sorted(
            command_signatures.items(),
            key=lambda item: (-item[1]["count"], item[0]),
        )
    ]
    scenario_rows = []
    for key, values in sorted(scenarios.items()):
        scenario, seat = key.rsplit(":", 1)
        scenario_rows.append({
            "scenario": scenario,
            "seat": seat,
            "traceCount": values["traceCount"],
            "toolCallCount": values["toolCallCount"],
            "failureCount": values["failureCount"],
            "blockedCount": values["blockedCount"],
            "unansweredToolCallCount": values["unansweredToolCallCount"],
            "leadingLiteralMarginCount": values["leadingLiteralMarginCount"],
            "finalFinishReasons": _counts(scenario_finish_reasons[key]),
            "stopConditions": _counts(scenario_stop_conditions[key]),
            "commands": _command_rows(scenario_commands[key]),
            "resultSizeBuckets": _counts(scenario_result_size_buckets[key]),
            "commandResultSizeBuckets": _command_bucket_rows(
                scenario_command_result_size_buckets[key]
            ),
            "errors": _counts(scenario_errors[key]),
            "flags": _counts(scenario_flags[key]),
            "unansweredCommands": _counts(scenario_unanswered_commands[key]),
            "sequences": _sequence_rows(scenario_sequences[key], maximum=64),
            "writeLatency": _write_latency(
                values["traceCount"],
                scenario_write_attempt_count[key],
                scenario_pre_write_tool_call_buckets[key],
            ),
            "suggestionMechanisms": _suggestion_mechanism_report(
                scenario_suggestion_mechanisms[key]
            ),
        })
    sequence_rows = _sequence_rows(sequences, maximum=256)
    return {
        "schema": TRACE_SHAPE_SCHEMA,
        "sourceCount": len(source_receipts),
        "sources": source_receipts,
        "candidateMarginSha256s": sorted(candidate_margin_sha256s),
        "traceCount": len(traces),
        "toolCallCount": tool_calls,
        "successCount": successes,
        "failureCount": failures,
        "blockedCount": blocked,
        "unansweredToolCallCount": sum(unanswered_commands.values()),
        "unansweredCommands": _counts(unanswered_commands),
        "finalFinishReasons": _counts(final_finish_reasons),
        "stopConditions": _counts(stop_conditions),
        "leadingLiteralMarginCount": leading_count,
        "commands": command_rows,
        "commandSignatures": command_signature_rows,
        "resultSizeBuckets": _counts(result_size_buckets),
        "commandResultSizeBuckets": _command_bucket_rows(command_result_size_buckets),
        "errors": _counts(errors),
        "flags": _counts(flags),
        "sequences": sequence_rows,
        "scenarios": scenario_rows,
        "writeLatency": _write_latency(
            len(traces), write_attempt_count, pre_write_tool_call_buckets
        ),
        "suggestionMechanisms": _suggestion_mechanism_report(
            suggestion_mechanisms
        ),
        "privacy": {
            "rawArgumentsRetained": False,
            "stdinRetained": False,
            "stdoutRetained": False,
            "stderrRetained": False,
            "documentContentRetained": False,
            "promptsRetained": False,
            "identifiersRetained": False,
            "pathsRetained": False,
            "sourcePathsRetained": False,
            "exactResultSizesRetained": False,
        },
    }
