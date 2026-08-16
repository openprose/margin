#!/usr/bin/env python3
"""Score one isolated Margin agent run using command evidence and Margin's JSON CLI."""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable


ROOT = Path(__file__).resolve().parents[2]
EXPECTED_PATH = ROOT / "Fixtures" / "agent-benchmark" / "expected.json"
FIXTURE_PATH = ROOT / "Fixtures" / "agent-benchmark" / "atlas-launch-review.md"
OPENING = b"<!-- margin:comments:v1\n"
CLOSING = b"\n-->"


@dataclass
class CLIResult:
    ok: bool
    value: Any | None
    exit_code: int | None
    stdout_sha256: str | None
    stderr_sha256: str | None


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def parse_json_output(data: bytes) -> Any | None:
    text = data.decode("utf-8", errors="replace").strip()
    if not text:
        return None
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        for line in reversed(text.splitlines()):
            try:
                return json.loads(line)
            except json.JSONDecodeError:
                continue
    return None


def invoke_json(binary: Path, candidates: Iterable[list[str]]) -> CLIResult:
    last: CLIResult | None = None
    for arguments in candidates:
        try:
            completed = subprocess.run(
                [str(binary), *arguments],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
                timeout=20,
            )
        except (OSError, subprocess.TimeoutExpired):
            continue
        value = parse_json_output(completed.stdout)
        last = CLIResult(
            ok=completed.returncode == 0 and value is not None,
            value=value,
            exit_code=completed.returncode,
            stdout_sha256=sha256(completed.stdout),
            stderr_sha256=sha256(completed.stderr),
        )
        if last.ok:
            return last
    return last or CLIResult(False, None, None, None, None)


def load_command_log(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    records: list[dict[str, Any]] = []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict) and isinstance(value.get("argv"), list):
            records.append(value)
    return records


def contains_command(record: dict[str, Any], *words: str) -> bool:
    arguments = [str(value).lower() for value in record.get("argv", [])]
    return all(any(word.lower() == argument or word.lower() in argument for argument in arguments) for word in words)


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
                isinstance(node.get("id"), str)
                and node.get("type") == "Annotation"
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
    if isinstance(body, dict):
        value = body.get("value")
        return value if isinstance(value, str) else None
    if isinstance(body, list):
        for item in body:
            if isinstance(item, dict) and isinstance(item.get("value"), str):
                return item["value"]
    return body if isinstance(body, str) else None


def selectors(annotation: dict[str, Any]) -> list[dict[str, Any]]:
    target = annotation.get("target")
    if not isinstance(target, dict):
        return []
    value = target.get("selector", [])
    if isinstance(value, dict):
        return [value]
    return [item for item in value if isinstance(item, dict)] if isinstance(value, list) else []


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


def status_of(annotation: dict[str, Any], wrapper: dict[str, Any] | None) -> str | None:
    for key in ("margin:status", "status"):
        if isinstance(annotation.get(key), str):
            return annotation[key]
    if wrapper:
        for key in ("threadStatus", "status"):
            if isinstance(wrapper.get(key), str):
                return wrapper[key]
    return None


def logical_body(path: Path) -> tuple[bytes | None, bool]:
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


def add_check(checks: list[dict[str, Any]], name: str, points: int, passed: bool, detail: str) -> None:
    checks.append({
        "detail": detail,
        "earned": points if passed else 0,
        "name": name,
        "passed": bool(passed),
        "possible": points,
    })


def score(run_dir: Path, margin_binary: Path) -> dict[str, Any]:
    expected = json.loads(EXPECTED_PATH.read_text(encoding="utf-8"))
    document = run_dir / "workspace" / "review.md"
    command_log = load_command_log(run_dir / "command-log.jsonl")

    list_result = invoke_json(margin_binary, [
        ["comments", "list", str(document), "--status", "all"],
        ["comments", "list", str(document), "--json", "--status", "all"],
        ["comment", "list", str(document), "--status", "all"],
    ])
    validate_result = invoke_json(margin_binary, [
        ["comments", "validate", str(document)],
        ["comments", "validate", str(document), "--json"],
        ["comment", "validate", str(document)],
    ])
    annotations, wrappers = collect_annotations(list_result.value) if list_result.ok else ({}, {})
    by_body = {body_value(annotation): annotation for annotation in annotations.values() if body_value(annotation)}
    comments = expected["comments"]

    quote = by_body.get(comments["quote"]["body"])
    range_comment = by_body.get(comments["range"]["body"])
    document_comment = by_body.get(comments["document"]["body"])
    ambiguous = by_body.get(comments["ambiguous_second"]["body"])
    reply = by_body.get(comments["reply"]["body"])
    nested = by_body.get(comments["nestedReply"]["body"])

    first_help = bool(command_log) and command_log[0].get("argv") == ["--help"] and command_log[0].get("exitCode") == 0
    used_inspect = any(contains_command(record, "inspect") and record.get("exitCode") == 0 for record in command_log)
    used_outline = any(contains_command(record, "outline") and record.get("exitCode") == 0 for record in command_log)
    used_slice = any(contains_command(record, "slice") and record.get("exitCode") == 0 for record in command_log)
    used_list = any(contains_command(record, "comments", "list") and record.get("exitCode") == 0 for record in command_log)
    used_validate = any(contains_command(record, "comments", "validate") and record.get("exitCode") == 0 for record in command_log)

    failed_ambiguous = any(
        contains_command(record, "comments", "add", "shared signal") and int(record.get("exitCode", 0)) != 0
        for record in command_log
    )
    successful_occurrence = any(
        contains_command(record, "comments", "add", "shared signal", "--occurrence")
        and int(record.get("exitCode", 1)) == 0
        for record in command_log
    )
    used_range_anchor = any(
        contains_command(record, "comments", "add")
        and any(str(argument).lower() in ("--range", "--from") for argument in record.get("argv", []))
        and int(record.get("exitCode", 1)) == 0
        for record in command_log
    )

    fixture_text = FIXTURE_PATH.read_text(encoding="utf-8")
    occurrence_starts: list[int] = []
    search = 0
    while True:
        found = fixture_text.find(comments["ambiguous_second"]["anchorExact"], search)
        if found < 0:
            break
        occurrence_starts.append(found)
        search = found + 1
    expected_second_start = occurrence_starts[1] if len(occurrence_starts) > 1 else None

    body, structurally_valid = logical_body(document)
    original = FIXTURE_PATH.read_bytes()
    source_preserved = structurally_valid and body == original

    quote_ok = bool(quote) and quote_exact(quote) == comments["quote"]["anchorExact"]
    range_ok = (
        bool(range_comment)
        and quote_exact(range_comment) == comments["range"]["anchorExact"]
        and position_start(range_comment) is not None
        and used_range_anchor
    )
    document_ok = bool(document_comment) and isinstance(document_comment.get("target"), str)
    reply_ok = bool(quote and reply) and reply.get("target") == quote.get("id")
    nested_ok = bool(reply and nested) and nested.get("target") == reply.get("id")
    second_ok = (
        bool(ambiguous)
        and quote_exact(ambiguous) == comments["ambiguous_second"]["anchorExact"]
        and expected_second_start is not None
        and position_start(ambiguous) == expected_second_start
    )
    resolved_ok = bool(quote) and status_of(quote, wrappers.get(str(quote.get("id")))) == "resolved"

    checks: list[dict[str, Any]] = []
    add_check(checks, "help_discovery", 5, first_help, "The first Margin call was `margin --help`.")
    add_check(checks, "inspect_usage", 4, used_inspect, "A successful inspect command was observed.")
    add_check(checks, "outline_usage", 4, used_outline, "A successful outline command was observed.")
    add_check(checks, "slice_usage", 4, used_slice, "A successful slice command was observed.")
    add_check(checks, "quote_comment", 10, quote_ok, "The launch-budget quote comment exists.")
    add_check(checks, "range_comment", 10, range_ok, "The exact sentence has a position-backed range comment.")
    add_check(checks, "document_comment", 8, document_ok, "The document-level compatibility comment exists.")
    add_check(checks, "first_reply", 7, reply_ok, "The first reply targets the quote annotation.")
    add_check(checks, "nested_reply", 8, nested_ok, "The nested reply targets the first reply.")
    add_check(checks, "ambiguity_error", 4, failed_ambiguous, "An ambiguous quote attempt failed before disambiguation.")
    add_check(checks, "second_occurrence", 6, second_ok, "The final shared-signal comment targets occurrence two.")
    add_check(checks, "occurrence_cli", 2, successful_occurrence, "A successful documented occurrence option was observed.")
    add_check(checks, "resolved_thread", 8, resolved_ok, "The launch-budget root thread is resolved.")
    add_check(checks, "source_preservation", 10, source_preserved, "Logical Markdown bytes equal the fixed fixture.")
    final_cli = list_result.ok and validate_result.ok and used_list and used_validate
    add_check(checks, "final_cli_validation", 10, final_cli, "Agent and scorer both completed list/validate JSON checks.")

    total = sum(int(check["earned"]) for check in checks)
    return {
        "checks": checks,
        "commandCount": len(command_log),
        "documentSha256": sha256(document.read_bytes()) if document.exists() else None,
        "fixtureSha256": sha256(original),
        "marginValidation": {
            "listExitCode": list_result.exit_code,
            "listStdoutSha256": list_result.stdout_sha256,
            "validateExitCode": validate_result.exit_code,
            "validateStdoutSha256": validate_result.stdout_sha256,
        },
        "possible": 100,
        "schema": "urn:margin:agent-benchmark-score:v1",
        "score": total,
        "sourcePreserved": source_preserved,
    }


def render_markdown(result: dict[str, Any]) -> str:
    lines = [
        "# Margin agent benchmark result",
        "",
        f"Score: **{result['score']}/{result['possible']}**",
        "",
        "| Check | Earned | Result |",
        "|---|---:|:---:|",
    ]
    for check in result["checks"]:
        mark = "pass" if check["passed"] else "fail"
        lines.append(f"| {check['name']} | {check['earned']}/{check['possible']} | {mark} |")
    lines.extend(["", f"Source preserved: **{str(result['sourcePreserved']).lower()}**", ""])
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-dir", required=True, type=Path)
    parser.add_argument("--margin-bin", required=True, type=Path)
    parser.add_argument("--no-write", action="store_true")
    arguments = parser.parse_args()

    result = score(arguments.run_dir.resolve(), arguments.margin_bin.resolve())
    if not arguments.no_write:
        (arguments.run_dir / "score.json").write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        (arguments.run_dir / "report.md").write_text(render_markdown(result), encoding="utf-8")
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0 if result["score"] == result["possible"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
