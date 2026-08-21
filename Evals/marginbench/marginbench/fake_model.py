"""A local OpenAI-compatible scripted model for zero-cost adapter preflight."""

from __future__ import annotations

import json
import re
import threading
import time
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def _tool_payload(message: dict) -> dict:
    content = message.get("content", "")
    if not isinstance(content, str):
        return {}
    try:
        value = json.loads(content)
    except json.JSONDecodeError:
        return {}
    return value if isinstance(value, dict) else {}


def _stdout(message: dict) -> dict:
    value = _tool_payload(message).get("stdout")
    if isinstance(value, str):
        try:
            value = json.loads(value)
        except json.JSONDecodeError:
            return {}
    return value if isinstance(value, dict) else {}


def _stdout_text(message: dict) -> str:
    value = _tool_payload(message).get("stdout")
    return value if isinstance(value, str) else ""


def _invocation(arguments: list[str], stdin: str | None = None) -> dict:
    value = {"arguments": arguments}
    if stdin is not None:
        value["stdin"] = stdin
    return value


def _tools(messages: list[dict]) -> list[dict]:
    return [message for message in messages if message.get("role") == "tool"]


def _first_comment(stdout: dict) -> tuple[str, int]:
    comments = (stdout.get("result") or {}).get("comments") or []
    return comments[0]["annotation"]["id"], int(stdout["revision"])


def _comment_body(item: dict) -> str:
    annotation = item.get("annotation") if isinstance(item, dict) else None
    body = annotation.get("body") if isinstance(annotation, dict) else None
    if isinstance(body, dict) and isinstance(body.get("value"), str):
        return body["value"]
    return ""


def _candidate_rows(body: str) -> list[tuple[str, int, str, str]]:
    return [
        (name.strip(), int(latency), encrypted, isolated)
        for name, latency, encrypted, isolated in re.findall(
            r"^- ([^|\n]+) \| latency=(\d+) \| encrypted=(yes|no) \| isolated=(yes|no)$",
            body,
            re.MULTILINE,
        )
    ]


def scripted_human_relay(prompt: str, tools: list[dict]) -> dict | None:
    match = re.search(
        r"with exactly this Markdown body:\n(.+?)\nUse mutation id ([0-9a-f-]+)\.",
        prompt,
        re.DOTALL,
    )
    if match is None:
        raise ValueError("Fake preflight received an unexpected role prompt.")
    body, identifier = match.group(1).strip(), match.group(2)
    if len(tools) == 0:
        return _invocation(["review", "review.md", "--json"])
    if len(tools) == 1:
        return _invocation(["comments", "list", "review.md", "--status", "all"])
    listing = _stdout(tools[1])
    root, revision = _first_comment(listing)
    if len(tools) == 2:
        return _invocation([
            "comments", "reply", "review.md", root,
            "-m", body, "--id", identifier,
            "--if-revision", str(revision),
        ])
    if len(tools) == 3:
        return _invocation([
            "comments", "resolve", "review.md", root,
            "--if-revision", str(_stdout(tools[2])["revision"]),
        ])
    if len(tools) == 4:
        return _invocation(["comments", "validate", "review.md"])
    if len(tools) == 5:
        return _invocation(["comments", "list", "review.md", "--status", "all"])
    return None


def scripted_handoff_author(prompt: str, tools: list[dict]) -> dict | None:
    match = re.search(
        r"for actor (urn:\S+)\. Use contribution id ([0-9a-f-]+),\n"
        r"request id ([0-9a-f-]+), and exactly this body:\n(.+?)\nLeave it open",
        prompt,
        re.DOTALL,
    )
    if match is None:
        raise ValueError("Fake preflight could not parse the handoff-author brief.")
    next_actor, identifier, request_id, body = match.groups()
    if not tools:
        return _invocation([
            "handoff", "add", "review.md", "-m", body.strip(),
            "--id", identifier, "--request-id", request_id,
            "--next-actor", next_actor,
        ])
    if len(tools) == 1:
        return _invocation(["handoff", "list", "review.md", "--json"])
    return None


def scripted_handoff_reviewer(prompt: str, tools: list[dict]) -> dict | None:
    match = re.search(
        r"with exactly this body:\n(.+?)\nUse mutation id ([0-9a-f-]+)\.",
        prompt,
        re.DOTALL,
    )
    if match is None:
        raise ValueError("Fake preflight could not parse the handoff-reviewer brief.")
    body, identifier = match.group(1).strip(), match.group(2)
    if not tools:
        return _invocation(["handoff", "list", "review.md", "--json"])
    if len(tools) == 1:
        return _invocation(["comments", "list", "review.md", "--status", "all"])
    root, revision = _first_comment(_stdout(tools[1]))
    if len(tools) == 2:
        return _invocation([
            "comments", "reply", "review.md", root, "-m", body,
            "--id", identifier, "--if-revision", str(revision),
        ])
    if len(tools) == 3:
        return _invocation([
            "comments", "resolve", "review.md", root,
            "--if-revision", str(_stdout(tools[2])["revision"]),
        ])
    if len(tools) == 4:
        return _invocation(["comments", "list", "review.md", "--thread", root, "--status", "all"])
    return None


def scripted_concurrent_review(prompt: str, tools: list[dict]) -> dict | None:
    match = re.search(
        r"id ([0-9a-f-]+) and exactly this body:\n(.+?)\nIf a concurrent write",
        prompt,
        re.DOTALL,
    )
    if match is None:
        raise ValueError("Fake preflight could not parse the concurrent-review brief.")
    identifier, body = match.group(1), match.group(2).strip()
    add = [
        "comments", "add", "review.md", "-m", body,
        "--document", "--kind", "issue", "--id", identifier,
    ]
    listing = ["comments", "list", "review.md", "--status", "all"]
    if not tools:
        return _invocation(add)
    if len(tools) == 1:
        return _invocation(listing)
    first_failed = _tool_payload(tools[0]).get("exitCode") not in (None, 0)
    if first_failed and len(tools) == 2:
        return _invocation(add)
    if first_failed and len(tools) == 3:
        return _invocation(listing)
    return None


def scripted_suggestion_author(prompt: str, tools: list[dict]) -> dict | None:
    values = re.findall(
        r"replacing\s*`([^`]+)` with\s*`([^`]+)` using id ([0-9a-f-]+) and message exactly\s*`([^`]+)`",
        prompt,
        re.DOTALL,
    )
    if len(values) != 2:
        raise ValueError("Fake preflight could not parse both suggestion-author operations.")
    if len(tools) < 2:
        exact, replacement, identifier, body = values[len(tools)]
        return _invocation([
            "suggest", "add", "review.md", "--quote", exact,
            "--expect", exact, "--replacement", replacement,
            "-m", body, "--id", identifier,
        ])
    if len(tools) == 2:
        return _invocation(["suggest", "list", "review.md", "--json"])
    return None


def scripted_suggestion_reviewer(prompt: str, tools: list[dict]) -> dict | None:
    match = re.search(r"Accept ([0-9a-f-]+).*?reject ([0-9a-f-]+)", prompt, re.DOTALL)
    if match is None:
        raise ValueError("Fake preflight could not parse the suggestion-reviewer brief.")
    accepted, rejected = match.groups()
    commands = (
        ["suggest", "list", "review.md", "--json"],
        ["suggest", "accept", "review.md", accepted],
        ["suggest", "reject", "review.md", rejected],
        ["read", "review.md", "--json"],
        ["comments", "validate", "review.md"],
    )
    return _invocation(commands[len(tools)]) if len(tools) < len(commands) else None


def scripted_suggestion_contention(prompt: str, tools: list[dict]) -> dict | None:
    match = re.search(
        r"Your exact assignment JSON:\n(\[.*?\])\n\nTogether, both collaborators",
        prompt,
        re.DOTALL,
    )
    if match is None:
        raise ValueError("Fake preflight could not parse the suggestion-contention brief.")
    assignments = json.loads(match.group(1))
    if not isinstance(assignments, list) or len(assignments) != 4:
        raise ValueError("Suggestion-contention assignment must contain four items.")
    ids_match = re.search(
        r"Together, both collaborators must leave exactly these eight suggestion ids:\n(\[.*?\])\n\nAfter",
        prompt,
        re.DOTALL,
    )
    if ids_match is None:
        raise ValueError("Fake preflight could not parse the public suggestion-id set.")
    all_ids = json.loads(ids_match.group(1))
    if (
        not isinstance(all_ids, list)
        or len(all_ids) != 8
        or not all(isinstance(value, str) and value for value in all_ids)
    ):
        raise ValueError("Suggestion-contention public id set must contain eight ids.")
    if not tools:
        return _invocation(["suggest", "add", "--help"])
    first_help = _stdout_text(tools[0])
    batch_available = (
        _tool_payload(tools[0]).get("exitCode") == 0
        and "urn:margin:suggestion-batch:v1" in first_help
        and "margin suggest add FILE --items-file -" in first_help
    )
    wait_available = (
        _tool_payload(tools[0]).get("exitCode") == 0
        and "margin suggest wait FILE ID..." in first_help
    )
    if batch_available:
        if len(tools) == 1:
            plan = {
                "schema": "urn:margin:suggestion-batch:v1",
                "version": 1,
                "items": assignments,
            }
            return _invocation(
                ["suggest", "add", "review.md", "--items-file", "-"],
                json.dumps(plan, sort_keys=True, separators=(",", ":")),
            )
        if len(tools) == 2:
            if wait_available:
                return _invocation([
                    "suggest", "wait", "review.md", *all_ids, "--timeout", "20",
                ])
            return _invocation(["suggest", "list", "review.md", "--json"])
        if len(tools) == 3:
            return _invocation(["read", "review.md", "--json"])
        return None

    add_index = len(tools) - 1
    if add_index < len(assignments):
        item = assignments[add_index]
        return _invocation([
            "suggest", "add", "review.md", "--quote", item["exact"],
            "--expect", item["exact"], "--replacement", item["replacement"],
            "-m", item["body"], "--id", item["id"],
        ])
    if add_index == len(assignments):
        if wait_available:
            return _invocation([
                "suggest", "wait", "review.md", *all_ids, "--timeout", "20",
            ])
        return _invocation(["suggest", "list", "review.md", "--json"])
    if add_index == len(assignments) + 1:
        return _invocation(["read", "review.md", "--json"])
    return None


def scripted_stage_author(prompt: str, tools: list[dict]) -> dict | None:
    match = re.search(
        r"immutable stage\n(urn:uuid:[0-9a-f-]+) with request id (urn:uuid:[0-9a-f-]+).*?"
        r"through stdin \(`--operations-file -`\):\n(\{.*?\})\nVerify the stage",
        prompt,
        re.DOTALL,
    )
    if match is None:
        raise ValueError("Fake preflight could not parse the staged-author brief.")
    stage_id, request_id, plan = match.groups()
    if not tools:
        return _invocation(["workspace", "init", "."])
    if len(tools) == 1:
        return _invocation([
            "stage", "create", ".", "--operations-file", "-",
            "--stage-id", stage_id, "--request-id", request_id,
        ], stdin=plan)
    if len(tools) == 2:
        return _invocation(["stage", "show", ".", stage_id])
    return None


def scripted_stage_reviewer(prompt: str, tools: list[dict]) -> dict | None:
    match = re.search(
        r"refresh it against current files(?: as| using the exact new stage id\s+)"
        r"(urn:uuid:[0-9a-f-]+)",
        prompt,
    )
    if match is None:
        raise ValueError("Fake preflight could not parse the staged-reviewer brief.")
    refreshed = match.group(1)
    if not tools:
        return _invocation(["stage", "list", "."])
    stages = (_stdout(tools[0]).get("result") or {}).get("stages") or []
    original = stages[0]["stageID"]
    commands = (
        ["stage", "show", ".", original],
        ["stage", "submit", ".", original],
        ["stage", "refresh", ".", original, "--id", refreshed, "--submit"],
        ["comments", "validate", "review.md"],
        ["comments", "validate", "notes/decision.md"],
    )
    offset = len(tools) - 1
    return _invocation(commands[offset]) if offset < len(commands) else None


def scripted_directory_author(prompt: str, tools: list[dict]) -> dict | None:
    match = re.search(
        r"one open thread in\n(\S+)\. Reply with exactly this Markdown body:\n(.+?)\n"
        r"Use mutation id ([0-9a-f-]+),.*?typed handoff in (\S+) for actor (urn:\S+)\. "
        r"Use contribution id\n([0-9a-f-]+), request id ([0-9a-f-]+), and exactly this "
        r"handoff body:\n(.+?)\nVerify",
        prompt,
        re.DOTALL,
    )
    if match is None:
        raise ValueError("Fake preflight could not parse the directory-author brief.")
    (
        tradeoff_path,
        analysis_body,
        analysis_id,
        status_path,
        next_actor,
        handoff_id,
        request_id,
        handoff_body,
    ) = match.groups()
    if not tools:
        return _invocation(["context", ".", "--json", "--brief"])
    if len(tools) == 1:
        return _invocation(["comments", "list", tradeoff_path, "--status", "all"])
    human_root, revision = _first_comment(_stdout(tools[1]))
    if len(tools) == 2:
        return _invocation([
            "comments", "reply", tradeoff_path, human_root,
            "-m", analysis_body.strip(), "--id", analysis_id,
            "--if-revision", str(revision),
        ])
    if len(tools) == 3:
        return _invocation([
            "comments", "resolve", tradeoff_path, human_root,
            "--if-revision", str(_stdout(tools[2])["revision"]),
        ])
    if len(tools) == 4:
        return _invocation([
            "handoff", "add", status_path, "-m", handoff_body.strip(),
            "--id", handoff_id, "--request-id", request_id,
            "--to", next_actor, "--document", "--kind", "handoff",
            "--if-revision", "0",
        ])
    if len(tools) == 5:
        return _invocation(["handoff", "list", ".", "--json"])
    return None


def scripted_directory_reviewer(prompt: str, tools: list[dict]) -> dict | None:
    match = re.search(
        r"handoff in (\S+)\. Reply to its thread with exactly\nthis Markdown body:\n(.+?)\n"
        r"Use mutation id ([0-9a-f-]+),",
        prompt,
        re.DOTALL,
    )
    if match is None:
        raise ValueError("Fake preflight could not parse the directory-reviewer brief.")
    status_path, body, identifier = match.groups()
    if not tools:
        return _invocation(["inbox", ".", "--kind", "handoff", "--status", "open", "--json"])
    if len(tools) == 1:
        return _invocation(["comments", "list", status_path, "--status", "all"])
    handoff_root, revision = _first_comment(_stdout(tools[1]))
    if len(tools) == 2:
        return _invocation([
            "comments", "reply", status_path, handoff_root, "-m", body.strip(),
            "--id", identifier, "--if-revision", str(revision),
        ])
    if len(tools) == 3:
        return _invocation([
            "comments", "resolve", status_path, handoff_root,
            "--if-revision", str(_stdout(tools[2])["revision"]),
        ])
    commands = (
        ["context", ".", "--json", "--brief"],
        ["comments", "validate", "architecture/tradeoffs.md"],
        ["comments", "validate", status_path],
    )
    offset = len(tools) - 4
    return _invocation(commands[offset]) if offset < len(commands) else None


def scripted_wide_directory_triage(prompt: str, tools: list[dict]) -> dict | None:
    match = re.search(
        r"exactly this Markdown body:\n(.+?)\nUse mutation id ([0-9a-f-]+)\.",
        prompt,
        re.DOTALL,
    )
    if match is None:
        raise ValueError("Fake preflight could not parse the wide-directory brief.")
    body, identifier = match.group(1).strip(), match.group(2)
    if not tools:
        return _invocation(["context", ".", "--json", "--brief"])
    if len(tools) == 1:
        return _invocation([
            "inbox", ".", "--kind", "question", "--status", "open", "--json", "--brief",
        ])
    inbox = (_stdout(tools[1]).get("result") or {}).get("items") or []
    if len(inbox) != 1:
        raise ValueError("Fake preflight did not find exactly one wide-directory question.")
    item = inbox[0]
    path = item["actionPath"]
    root = item["rootID"]
    if len(tools) == 2:
        return _invocation([
            "comments", "reply", path, root, "-m", body,
            "--id", identifier,
            "--if-revision", str(item["annotationRevision"]),
            "--resolve",
        ])
    if len(tools) == 3:
        return _invocation([
            "comments", "list", path, "--thread", root, "--status", "all",
        ])
    if len(tools) == 4:
        return _invocation(["comments", "validate", path])
    return None


def scripted_parallel_shard(prompt: str, tools: list[dict]) -> dict | None:
    match = re.search(
        r"You own (\S+) .*?issue to \S+ with id ([0-9a-f-]+) and exactly this body:\n"
        r"(.+?)\nDo not wait",
        prompt,
        re.DOTALL,
    )
    if match is None:
        raise ValueError("Fake preflight could not parse the parallel-shard brief.")
    path, identifier, body = match.groups()
    commands = (
        ["comments", "add", path, "-m", body.strip(), "--document", "--kind", "issue", "--id", identifier],
        ["comments", "list", path, "--status", "all"],
        ["comments", "validate", path],
    )
    return _invocation(commands[len(tools)]) if len(tools) < len(commands) else None


def scripted_specialist_author(prompt: str, tools: list[dict]) -> dict | None:
    match = re.search(
        r"performance specialist for ([A-Za-z0-9_./-]+\.md).*?decision with id ([0-9a-f-]+)",
        prompt,
        re.DOTALL,
    )
    if match is None:
        raise ValueError("Fake preflight could not parse the performance-specialist brief.")
    path, identifier = match.groups()
    if not tools:
        return _invocation(["read", path, "--json"])
    rows = _candidate_rows(str((_stdout(tools[0]).get("result") or {}).get("body", "")))
    if len(rows) != 3:
        raise ValueError("Fake preflight could not parse specialist candidate evidence.")
    choice = min(rows, key=lambda value: value[1])[0]
    commands = (
        ["comments", "add", path, "-m", f"Performance choice: {choice}.", "--document", "--kind", "decision", "--id", identifier],
        ["comments", "list", path, "--status", "all"],
        ["comments", "validate", path],
    )
    offset = len(tools) - 1
    return _invocation(commands[offset]) if offset < len(commands) else None


def scripted_specialist_reviewer(prompt: str, tools: list[dict]) -> dict | None:
    match = re.search(
        r"Read ([A-Za-z0-9_./-]+\.md) and the existing decision.*?issue with id ([0-9a-f-]+)",
        prompt,
        re.DOTALL,
    )
    if match is None:
        raise ValueError("Fake preflight could not parse the security-specialist brief.")
    path, identifier = match.groups()
    if not tools:
        return _invocation(["comments", "list", path, "--status", "all"])
    if len(tools) == 1:
        return _invocation(["read", path, "--json"])
    comments = ((_stdout(tools[0]).get("result") or {}).get("comments") or [])
    decision = next((_comment_body(item) for item in comments if _comment_body(item).startswith("Performance choice: ")), "")
    decision_match = re.fullmatch(r"Performance choice: (.+)\.", decision)
    rows = _candidate_rows(str((_stdout(tools[1]).get("result") or {}).get("body", "")))
    eligible = [row for row in rows if row[2:] == ("yes", "yes")]
    if decision_match is None or len(eligible) != 1:
        raise ValueError("Fake preflight could not derive the specialist correction.")
    secure = min(eligible, key=lambda value: value[1])[0]
    issue = f"Security correction: {decision_match.group(1)} is ineligible; choose {secure}."
    commands = (
        ["comments", "add", path, "-m", issue, "--document", "--kind", "issue", "--id", identifier],
        ["comments", "list", path, "--status", "all"],
        ["comments", "validate", path],
    )
    offset = len(tools) - 2
    return _invocation(commands[offset]) if offset < len(commands) else None


def scripted_synthesis_author(prompt: str, tools: list[dict]) -> dict | None:
    match = re.search(
        r"typed handoff in ([A-Za-z0-9_./-]+\.md) for\nactor (urn:\S+), using contribution id ([0-9a-f-]+), "
        r"request id ([0-9a-f-]+), and the exact\nbody `([^`]+)`",
        prompt,
        re.DOTALL,
    )
    if match is None:
        raise ValueError("Fake preflight could not parse the distributed-synthesis author brief.")
    path, next_actor, identifier, request_id, body = match.groups()
    if not tools:
        return _invocation([
            "handoff", "add", path, "-m", body,
            "--id", identifier, "--request-id", request_id, "--next-actor", next_actor,
        ])
    if len(tools) == 1:
        return _invocation(["handoff", "list", path, "--json"])
    return None


def scripted_synthesis_reviewer(prompt: str, tools: list[dict]) -> dict | None:
    match = re.search(
        r"evidence token is `([^`]+)`. Find the open\nhandoff in ([A-Za-z0-9_./-]+\.md).*?mutation id\n"
        r"([0-9a-f-]+)",
        prompt,
        re.DOTALL,
    )
    if match is None:
        raise ValueError("Fake preflight could not parse the distributed-synthesis reviewer brief.")
    evidence_b, path, identifier = match.groups()
    if not tools:
        return _invocation(["handoff", "list", path, "--json"])
    if len(tools) == 1:
        return _invocation(["comments", "list", path, "--status", "all"])
    listing = _stdout(tools[1])
    comments = ((listing.get("result") or {}).get("comments") or [])
    handoff = next((_comment_body(item) for item in comments if _comment_body(item).startswith("Evidence A: ")), "")
    evidence_match = re.fullmatch(r"Evidence A: ([^.]+)\.", handoff)
    if evidence_match is None:
        raise ValueError("Fake preflight could not recover Evidence A.")
    root, revision = _first_comment(listing)
    reply = f"Synthesis: {evidence_match.group(1)} + {evidence_b}."
    if len(tools) == 2:
        return _invocation([
            "comments", "reply", path, root, "-m", reply,
            "--id", identifier, "--if-revision", str(revision),
        ])
    if len(tools) == 3:
        return _invocation([
            "comments", "resolve", path, root,
            "--if-revision", str(_stdout(tools[2])["revision"]),
        ])
    if len(tools) == 4:
        return _invocation(["comments", "list", path, "--thread", root, "--status", "all"])
    if len(tools) == 5:
        return _invocation(["comments", "validate", path])
    return None


def scripted_response(messages: list[dict]) -> dict | None:
    user_positions = [
        index
        for index, message in enumerate(messages)
        if message.get("role") == "user" and isinstance(message.get("content"), str)
    ]
    if not user_positions:
        raise ValueError("Fake preflight received no current role brief.")
    current = user_positions[-1]
    prompt = messages[current]["content"]
    tools = _tools(messages[current + 1:])
    if "You own " in prompt and "low-coupling parallel review" in prompt:
        return scripted_parallel_shard(prompt, tools)
    if "Act as the performance specialist" in prompt:
        return scripted_specialist_author(prompt, tools)
    if "independent security specialist" in prompt:
        return scripted_specialist_reviewer(prompt, tools)
    if "Your role-private evidence token" in prompt:
        return scripted_synthesis_author(prompt, tools)
    if "your role-private evidence token" in prompt:
        return scripted_synthesis_reviewer(prompt, tools)
    if "Begin with bounded directory context" in prompt:
        return scripted_directory_author(prompt, tools)
    if "Use a bounded directory-wide inbox or handoff" in prompt:
        return scripted_directory_reviewer(prompt, tools)
    if "The workspace contains many Markdown documents" in prompt:
        return scripted_wide_directory_triage(prompt, tools)
    if "A human left one open thread" in prompt:
        return scripted_human_relay(prompt, tools)
    if "Create one typed handoff" in prompt:
        return scripted_handoff_author(prompt, tools)
    if "You receive no transcript from the prior agent" in prompt:
        return scripted_handoff_reviewer(prompt, tools)
    if "Another agent is acting at the same time" in prompt:
        return scripted_concurrent_review(prompt, tools)
    if "Create two resilient suggestions" in prompt:
        return scripted_suggestion_author(prompt, tools)
    if "Review the two durable suggestions" in prompt:
        return scripted_suggestion_reviewer(prompt, tools)
    if "Your exact assignment JSON" in prompt:
        return scripted_suggestion_contention(prompt, tools)
    if "Initialize this directory as a Margin workspace" in prompt:
        return scripted_stage_author(prompt, tools)
    if "A prior agent left an immutable multi-file stage" in prompt:
        return scripted_stage_reviewer(prompt, tools)
    raise ValueError("Fake preflight received an unexpected role prompt.")


class _Handler(BaseHTTPRequestHandler):
    request_count = 0

    def log_message(self, _format, *_args) -> None:
        return None

    def do_POST(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        size = int(self.headers.get("content-length", "0"))
        request = json.loads(self.rfile.read(size))
        invocation = scripted_response(request.get("messages", []))
        type(self).request_count += 1
        if invocation is None:
            message = {"role": "assistant", "content": "Completed and verified."}
            finish_reason = "stop"
        else:
            message = {
                "role": "assistant",
                "content": None,
                "tool_calls": [{
                    "id": f"call_{type(self).request_count}",
                    "type": "function",
                    "function": {
                        "name": "margin",
                        "arguments": json.dumps(invocation, separators=(",", ":")),
                    },
                }],
            }
            finish_reason = "tool_calls"
        response = {
            "id": f"marginbench-fake-{type(self).request_count}",
            "object": "chat.completion",
            "created": int(time.time()),
            "model": request.get("model", "marginbench-fake"),
            "choices": [{"index": 0, "message": message, "finish_reason": finish_reason}],
            "usage": {"prompt_tokens": 100, "completion_tokens": 20, "total_tokens": 120},
        }
        encoded = json.dumps(response, separators=(",", ":")).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)


@contextmanager
def fake_model_server():
    _Handler.request_count = 0
    server = ThreadingHTTPServer(("127.0.0.1", 0), _Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield server, _Handler
    finally:
        server.shutdown()
        thread.join(timeout=5)
        server.server_close()
