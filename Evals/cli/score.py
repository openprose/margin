#!/usr/bin/env python3
"""Deterministically grade one Margin CLI evaluation case."""

from __future__ import annotations

import argparse
import json
import sys
from collections import defaultdict
from pathlib import Path
from typing import Any

sys.dont_write_bytecode = True
from eval_lib import (  # noqa: E402
    DOCUMENT_NAME,
    EvalError,
    Invocation,
    Scenario,
    find_margin_binary,
    invoke,
    load_command_log,
    load_json,
    load_suite,
    sha256_bytes,
)


OPENING = b"<!-- margin:comments:v1\n"
CLOSING = b"\n-->"


def recursive_values(value: Any, key: str) -> list[Any]:
    result: list[Any] = []
    if isinstance(value, dict):
        if key in value:
            result.append(value[key])
        for child in value.values():
            result.extend(recursive_values(child, key))
    elif isinstance(value, list):
        for child in value:
            result.extend(recursive_values(child, key))
    return result


def collect_annotations(value: Any) -> tuple[dict[str, dict[str, Any]], dict[str, dict[str, Any]]]:
    annotations: dict[str, dict[str, Any]] = {}
    wrappers: dict[str, dict[str, Any]] = {}

    def visit(node: Any) -> None:
        if isinstance(node, dict):
            annotation = node.get("annotation")
            if isinstance(annotation, dict) and isinstance(annotation.get("id"), str):
                annotations[annotation["id"]] = annotation
                wrappers[annotation["id"]] = node
            if (
                node.get("type") == "Annotation"
                and isinstance(node.get("id"), str)
                and isinstance(node.get("motivation"), str)
            ):
                annotations[node["id"]] = node
            for child in node.values():
                visit(child)
        elif isinstance(node, list):
            for child in node:
                visit(child)

    visit(value)
    return annotations, wrappers


def body_value(annotation: dict[str, Any]) -> str | None:
    body = annotation.get("body")
    if isinstance(body, dict) and isinstance(body.get("value"), str):
        return body["value"]
    if isinstance(body, list):
        for item in body:
            if isinstance(item, dict) and isinstance(item.get("value"), str):
                return item["value"]
    return body if isinstance(body, str) else None


def selectors(annotation: dict[str, Any]) -> list[dict[str, Any]]:
    target = annotation.get("target")
    if not isinstance(target, dict):
        return []
    raw = target.get("selector")
    if isinstance(raw, dict):
        return [raw]
    return [item for item in raw if isinstance(item, dict)] if isinstance(raw, list) else []


def quote_exact(annotation: dict[str, Any]) -> str | None:
    for selector in selectors(annotation):
        if selector.get("type") == "TextQuoteSelector" and isinstance(selector.get("exact"), str):
            return selector["exact"]
    return None


def position_start(annotation: dict[str, Any]) -> int | None:
    for selector in selectors(annotation):
        if selector.get("type") == "TextPositionSelector" and isinstance(selector.get("start"), int):
            return selector["start"]
    return None


def logical_body(path: Path) -> tuple[bytes | None, bool]:
    if not path.is_file():
        return None, False
    data = path.read_bytes()
    count = data.count(OPENING)
    if count == 0:
        return data, True
    if count != 1 or not (data.endswith(CLOSING) or data.endswith(CLOSING + b"\n")):
        return None, False
    marker = data.index(OPENING)
    closing = data.rfind(CLOSING)
    try:
        envelope = json.loads(data[marker + len(OPENING) : closing])
        length = envelope["margin:contentByteLength"]
    except (json.JSONDecodeError, KeyError, TypeError):
        return None, False
    if not isinstance(length, int) or length < 0 or length > marker:
        return None, False
    return data[:length], True


def normalized_id(value: str) -> str:
    return value if value.startswith("urn:") else f"urn:uuid:{value}"


def status_of(annotation: dict[str, Any], wrapper: dict[str, Any] | None) -> str | None:
    if wrapper and isinstance(wrapper.get("threadStatus"), str):
        return wrapper["threadStatus"]
    value = annotation.get("margin:status")
    return value if isinstance(value, str) else None


def command_matches(record: dict[str, Any], matcher: dict[str, Any]) -> bool:
    argv = [str(item) for item in record.get("argv", [])]
    starts = [str(item) for item in matcher.get("startsWith", [])]
    actual_prefix = argv[: len(starts)]
    if actual_prefix and actual_prefix[0] == "comment":
        actual_prefix[0] = "comments"
    if starts and actual_prefix != starts:
        return False
    if any(str(flag) not in argv for flag in matcher.get("hasFlags", [])):
        return False
    any_flags = [str(flag) for flag in matcher.get("hasAnyFlags", [])]
    if any_flags and not any(flag in argv for flag in any_flags):
        return False
    for flag, expected in matcher.get("flagValues", {}).items():
        try:
            index = argv.index(str(flag))
        except ValueError:
            return False
        if index + 1 >= len(argv) or argv[index + 1] != str(expected):
            return False
    if any(str(flag) in argv for flag in matcher.get("lacksFlags", [])):
        return False
    if "exitCode" in matcher and record.get("exitCode") != matcher["exitCode"]:
        return False
    if matcher.get("nonzero") is True and int(record.get("exitCode", 0)) == 0:
        return False
    if isinstance(matcher.get("errorCode"), str) and record.get("errorCode") != matcher["errorCode"]:
        return False
    if "changed" in matcher and record.get("changed") is not matcher["changed"]:
        return False
    return True


def find_command_matches(records: list[dict[str, Any]], matcher: dict[str, Any]) -> list[int]:
    return [index for index, record in enumerate(records) if command_matches(record, matcher)]


def grade_comment(
    spec: dict[str, Any],
    annotations: dict[str, dict[str, Any]],
    wrappers: dict[str, dict[str, Any]],
    source: str,
) -> tuple[bool, str]:
    expected_body = spec.get("body")
    matches = [item for item in annotations.values() if body_value(item) == expected_body]
    if spec.get("absent") is True:
        return not matches, f"Expected no comment with body {expected_body!r}; found {len(matches)}."
    expected_count = int(spec.get("count", 1))
    if len(matches) != expected_count:
        return False, f"Expected {expected_count} matching comment(s); found {len(matches)}."
    annotation = matches[0]
    wrapper = wrappers.get(str(annotation.get("id")), {})
    failures: list[str] = []
    if isinstance(spec.get("id"), str) and annotation.get("id") != normalized_id(spec["id"]):
        failures.append("id")
    if isinstance(spec.get("motivation"), str) and annotation.get("motivation") != spec["motivation"]:
        failures.append("motivation")
    if isinstance(spec.get("status"), str) and status_of(annotation, wrapper) != spec["status"]:
        failures.append("thread status")
    if isinstance(spec.get("depth"), int) and wrapper.get("depth") != spec["depth"]:
        failures.append("depth")
    if isinstance(spec.get("creatorID"), str):
        creator = annotation.get("creator")
        if not isinstance(creator, dict) or creator.get("id") != spec["creatorID"]:
            failures.append("creator")
    target_kind = spec.get("target")
    if target_kind == "document" and not isinstance(annotation.get("target"), str):
        failures.append("document target")
    if target_kind == "selection" and not isinstance(annotation.get("target"), dict):
        failures.append("selection target")
    if isinstance(spec.get("anchorExact"), str) and quote_exact(annotation) != spec["anchorExact"]:
        failures.append("exact quote")
    if isinstance(spec.get("anchorState"), str):
        anchor = wrapper.get("anchor")
        if not isinstance(anchor, dict) or anchor.get("state") != spec["anchorState"]:
            failures.append("anchor state")
    if isinstance(spec.get("occurrence"), int) and isinstance(spec.get("anchorExact"), str):
        exact = spec["anchorExact"]
        offsets: list[int] = []
        cursor = 0
        while True:
            found = source.find(exact, cursor)
            if found < 0:
                break
            offsets.append(found)
            cursor = found + 1
        occurrence = spec["occurrence"]
        expected = offsets[occurrence - 1] if 0 < occurrence <= len(offsets) else None
        if position_start(annotation) != expected:
            failures.append(f"occurrence {occurrence}")
    parent_body = spec.get("parentBody")
    if isinstance(parent_body, str):
        parent_id = annotation.get("target")
        parent = annotations.get(parent_id) if isinstance(parent_id, str) else None
        if not parent or body_value(parent) != parent_body:
            failures.append("parent")
    root_body = spec.get("rootBody")
    if isinstance(root_body, str):
        root_id = wrapper.get("rootID")
        root = annotations.get(root_id) if isinstance(root_id, str) else None
        if not root or body_value(root) != root_body:
            failures.append("root")
    return not failures, "Comment matched." if not failures else "Mismatched " + ", ".join(failures) + "."


def grade_check(
    check: dict[str, Any],
    *,
    document: Path,
    fixture: Path,
    source: str,
    command_log: list[dict[str, Any]],
    annotations: dict[str, dict[str, Any]],
    wrappers: dict[str, dict[str, Any]],
    list_result: Invocation,
    validate_result: Invocation,
    trace: dict[str, Any],
) -> tuple[bool, str]:
    kind = check.get("type")
    spec = check.get("expect", {})
    if not isinstance(spec, dict):
        spec = {}
    if kind == "source_preserved":
        body, valid = logical_body(document)
        passed = valid and body == fixture.read_bytes()
        return passed, "Logical Markdown bytes match the fixture." if passed else "Logical Markdown bytes changed."
    if kind == "protocol_valid":
        value = validate_result.json
        valid_field = recursive_values(value, "valid") if value is not None else []
        passed = validate_result.exit_code == 0 and True in valid_field
        return passed, "Margin accepted the embedded protocol." if passed else "Margin validation failed."
    if kind == "trace_policy":
        passed = bool(trace.get("policyCompliant", True))
        detail = (
            "No direct document access was observed."
            if passed
            else f"Observed {trace.get('directDocumentReads', 0)} direct read(s) and "
            f"{trace.get('directDocumentWrites', 0)} direct write(s), "
            f"{trace.get('harnessAccesses', 0)} harness access(es), and "
            f"{trace.get('sensitiveAccesses', 0)} sensitive access(es)."
        )
        return passed, detail
    if kind == "command":
        indices = find_command_matches(command_log, spec)
        at_least = int(spec.get("atLeast", 1))
        at_most = int(spec["atMost"]) if "atMost" in spec else None
        passed = len(indices) >= at_least and (at_most is None or len(indices) <= at_most)
        if spec.get("first") is True:
            passed = passed and bool(indices) and indices[0] == 0
        bound = f"{at_least}+" if at_most is None else f"{at_least}–{at_most}"
        return passed, f"Matched {len(indices)} command(s); required {bound}."
    if kind == "command_sequence":
        steps = spec.get("steps", [])
        cursor = -1
        positions: list[int] = []
        for step in steps:
            candidates = [index for index in find_command_matches(command_log, step) if index > cursor]
            if not candidates:
                return False, f"Sequence stopped after {len(positions)} of {len(steps)} steps."
            cursor = candidates[0]
            positions.append(cursor)
        return True, f"Observed ordered command sequence at {positions}."
    if kind == "command_budget":
        maximum = int(spec.get("maximum", 0))
        return len(command_log) <= maximum, f"Used {len(command_log)} commands; budget is {maximum}."
    if kind == "error_budget":
        errors = sum(1 for record in command_log if int(record.get("exitCode", 0)) != 0)
        minimum = int(spec.get("minimum", 0))
        maximum = int(spec.get("maximum", minimum))
        return minimum <= errors <= maximum, f"Observed {errors} failed commands; expected {minimum}–{maximum}."
    if kind == "comment":
        return grade_comment(spec, annotations, wrappers, source)
    if kind == "counts":
        roots = [
            annotation for annotation_id, annotation in annotations.items()
            if wrappers.get(annotation_id, {}).get("depth") == 0
        ]
        actual = {
            "annotations": len(annotations),
            "openThreads": sum(1 for root in roots if status_of(root, wrappers.get(str(root.get("id")))) == "open"),
            "resolvedThreads": sum(1 for root in roots if status_of(root, wrappers.get(str(root.get("id")))) == "resolved"),
        }
        revision_values = recursive_values(list_result.json, "revision") if list_result.json is not None else []
        revisions = [item for item in revision_values if isinstance(item, int)]
        actual["revision"] = max(revisions) if revisions else 0
        mismatches = [f"{key}={actual.get(key)}" for key, value in spec.items() if actual.get(key) != value]
        return not mismatches, "Counts matched." if not mismatches else "Unexpected " + ", ".join(mismatches) + "."
    raise EvalError(f"Unknown check type {kind!r} in {check.get('id')!r}.")


def score_case(case_dir: Path, scenario: Scenario, margin_binary: Path) -> dict[str, Any]:
    document = case_dir / "workspace" / DOCUMENT_NAME
    command_log = load_command_log(case_dir / "command-log.jsonl")
    trace_path = case_dir / "trace.json"
    trace = load_json(trace_path) if trace_path.is_file() else {
        "directDocumentReads": 0,
        "directDocumentWrites": 0,
        "policyCompliant": True,
        "toolCalls": 0,
    }
    integrity_path = case_dir / "integrity.json"
    integrity = load_json(integrity_path) if integrity_path.is_file() else {"ok": True, "reasons": []}
    list_result = invoke(margin_binary, ["comments", "list", str(document), "--status", "all"])
    validate_result = invoke(margin_binary, ["comments", "validate", str(document)])
    annotations, wrappers = collect_annotations(list_result.json) if list_result.exit_code == 0 else ({}, {})
    logical, structurally_valid = logical_body(document)
    source = logical.decode("utf-8", errors="replace") if logical is not None else ""

    checks: list[dict[str, Any]] = []
    dimensions: dict[str, dict[str, int]] = defaultdict(lambda: {"earned": 0, "possible": 0})
    for check in scenario.checks:
        passed, detail = grade_check(
            check,
            document=document,
            fixture=scenario.fixture,
            source=source,
            command_log=command_log,
            annotations=annotations,
            wrappers=wrappers,
            list_result=list_result,
            validate_result=validate_result,
            trace=trace,
        )
        possible = int(check["points"])
        earned = possible if passed else 0
        dimension = str(check.get("dimension", "task"))
        dimensions[dimension]["possible"] += possible
        dimensions[dimension]["earned"] += earned
        checks.append({
            "detail": detail,
            "dimension": dimension,
            "earned": earned,
            "id": check["id"],
            "passed": passed,
            "possible": possible,
        })

    raw_score = sum(item["earned"] for item in checks)
    by_id = {item["id"]: item for item in checks}
    applied_caps: list[dict[str, Any]] = []
    score = raw_score
    for cap in scenario.manifest.get("caps", []):
        failed = by_id.get(cap.get("ifCheckFails"))
        maximum = int(cap.get("maxScore", 100))
        if failed and not failed["passed"] and score > maximum:
            score = maximum
            applied_caps.append({"check": failed["id"], "maxScore": maximum})
    if not integrity.get("ok", True):
        score = min(score, 30)
        applied_caps.append({"check": "telemetry_integrity", "maxScore": 30})

    return {
        "appliedCaps": applied_caps,
        "checks": checks,
        "commandCount": len(command_log),
        "dimensions": dict(sorted(dimensions.items())),
        "documentSha256": sha256_bytes(document.read_bytes()) if document.is_file() else None,
        "failedCheckIDs": [item["id"] for item in checks if not item["passed"]],
        "marginValidation": {
            "listExitCode": list_result.exit_code,
            "validateExitCode": validate_result.exit_code,
        },
        "possible": 100,
        "protocolStructurallyValid": structurally_valid,
        "rawScore": raw_score,
        "scenario": scenario.id,
        "schema": "urn:margin:cli-eval-score:v1",
        "score": score,
        "sourcePreserved": structurally_valid and logical == scenario.fixture.read_bytes(),
        "telemetryIntegrity": integrity,
        "trace": trace,
    }


def render_markdown(result: dict[str, Any]) -> str:
    lines = [
        f"# CLI eval: {result['scenario']}",
        "",
        f"Score: **{result['score']}/{result['possible']}** (raw {result['rawScore']})",
        "",
        "| Check | Dimension | Earned | Result |",
        "|---|---|---:|:---:|",
    ]
    for check in result["checks"]:
        lines.append(
            f"| {check['id']} | {check['dimension']} | {check['earned']}/{check['possible']} | "
            f"{'pass' if check['passed'] else 'fail'} |"
        )
    lines.extend(["", f"Commands: **{result['commandCount']}**", ""])
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--case-dir", required=True, type=Path)
    parser.add_argument("--scenario", required=True)
    parser.add_argument("--margin-bin", type=Path)
    parser.add_argument("--no-write", action="store_true")
    arguments = parser.parse_args()
    try:
        scenario = load_suite([arguments.scenario])[0]
        binary = find_margin_binary(arguments.margin_bin)
        if binary is None:
            raise EvalError("Margin CLI binary not found.")
        result = score_case(arguments.case_dir.resolve(), scenario, binary)
        if not arguments.no_write:
            (arguments.case_dir / "score.json").write_text(
                json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8"
            )
            (arguments.case_dir / "report.md").write_text(render_markdown(result), encoding="utf-8")
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0 if result["score"] == result["possible"] else 1
    except EvalError as error:
        print(str(error), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
