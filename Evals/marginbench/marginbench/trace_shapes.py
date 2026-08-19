"""Content-free command-shape diagnostics for private Prime traces."""

from __future__ import annotations

import hashlib
import json
import re
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any

from .gateway import ALLOWED_COMMANDS, BOOLEAN_OPTIONS, VALUE_OPTIONS
from .scenarios import SCENARIO_IDS


TRACE_SHAPE_SCHEMA = "urn:marginbench:trace-shape-report:v1"
MAX_SOURCES = 32
MAX_SOURCE_BYTES = 256 * 1_024 * 1_024
MAX_LINE_BYTES = 16 * 1_024 * 1_024
MAX_TRACES = 10_000
MAX_TOOL_CALLS = 1_000_000
MAX_SEQUENCE_LENGTH = 128
MAX_COMMAND_SIGNATURES = 4_096
SAFE_NAME = re.compile(r"^[A-Za-z][A-Za-z0-9_.-]{0,127}$")
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
    return value if isinstance(value, str) and value in SCENARIO_IDS else "unknown"


def _safe_seat(value: object) -> str:
    return value if value in {"agent", "author", "reviewer"} else "unknown"


def _safe_error(value: object) -> str:
    return value if isinstance(value, str) and SAFE_NAME.fullmatch(value) else "UNCLASSIFIED"


def _safe_command(arguments: list[str]) -> tuple[str, bool]:
    leading = arguments[:1] == ["margin"]
    values = arguments[1:] if leading else arguments
    if not values:
        return "unknown", leading
    if values[0] not in ALLOWED_COMMANDS:
        missing_command = any(
            token.split("=", 1)[0] in KNOWN_FLAGS
            for token in values[1:]
            if token.startswith("-")
        )
        return ("missing-command" if missing_command else "unknown"), leading
    top = values[0]
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


def _counts(counter: Counter[str], maximum: int = 256) -> list[dict[str, Any]]:
    return [
        {"name": name, "count": count}
        for name, count in sorted(counter.items(), key=lambda item: (-item[1], item[0]))[:maximum]
    ]


def summarize_trace_shapes(paths: list[Path]) -> dict[str, Any]:
    sources = _sources(paths)
    source_receipts = []
    traces: list[dict[str, Any]] = []
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
                    traces.extend(value for value in values if isinstance(value, dict))
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
    errors: Counter[str] = Counter()
    flags: Counter[str] = Counter()
    unanswered_commands: Counter[str] = Counter()
    final_finish_reasons: Counter[str] = Counter()
    stop_conditions: Counter[str] = Counter()
    sequences: Counter[tuple[str, ...]] = Counter()
    scenarios: dict[str, Counter[str]] = defaultdict(Counter)
    scenario_finish_reasons: dict[str, Counter[str]] = defaultdict(Counter)
    scenario_stop_conditions: dict[str, Counter[str]] = defaultdict(Counter)
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
            tool_calls += 1
            successes += int(ok)
            failures += int(not ok)
            blocked += int(is_blocked)
            leading_count += int(leading)
            commands[command]["count"] += 1
            commands[command]["successCount"] += int(ok)
            commands[command]["failureCount"] += int(not ok)
            commands[command]["blockedCount"] += int(is_blocked)
            scenarios[scenario_key]["toolCallCount"] += 1
            scenarios[scenario_key]["failureCount"] += int(not ok)
            scenarios[scenario_key]["blockedCount"] += int(is_blocked)
            scenarios[scenario_key]["leadingLiteralMarginCount"] += int(leading)
            if error is not None:
                errors[error] += 1
            flags.update(command_flags)
            signature_key = (command, tuple(command_flags))
            if signature_key not in command_signatures and len(command_signatures) >= MAX_COMMAND_SIGNATURES:
                raise TraceShapeError(
                    f"Distinct command signature count exceeds {MAX_COMMAND_SIGNATURES}."
                )
            command_signatures[signature_key]["count"] += 1
            command_signatures[signature_key]["successCount"] += int(ok)
            command_signatures[signature_key]["failureCount"] += int(not ok)
            command_signatures[signature_key]["blockedCount"] += int(is_blocked)
            if error is not None:
                command_signature_errors[signature_key][error] += 1
            if len(sequence) < MAX_SEQUENCE_LENGTH:
                sequence.append(command)
        if sequence:
            sequences[tuple(sequence)] += 1
        for command, _, _, _ in pending.values():
            unanswered_commands[command] += 1
            scenarios[scenario_key]["unansweredToolCallCount"] += 1

    command_rows = [
        {"name": name, **dict(values)}
        for name, values in sorted(
            commands.items(),
            key=lambda item: (-item[1]["count"], item[0]),
        )
    ]
    command_signature_rows = [
        {
            "command": command,
            "flags": list(signature_flags),
            **dict(values),
            "errors": _counts(command_signature_errors[(command, signature_flags)]),
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
        })
    sequence_rows = [
        {"commands": list(sequence), "count": count}
        for sequence, count in sorted(
            sequences.items(),
            key=lambda item: (-item[1], item[0]),
        )[:256]
    ]
    return {
        "schema": TRACE_SHAPE_SCHEMA,
        "sourceCount": len(source_receipts),
        "sources": source_receipts,
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
        "errors": _counts(errors),
        "flags": _counts(flags),
        "sequences": sequence_rows,
        "scenarios": scenario_rows,
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
        },
    }
