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
    return value if isinstance(value, dict) else {}


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
    if not tools:
        return _invocation([
            "comments", "add", "review.md", "-m", body,
            "--document", "--kind", "issue", "--id", identifier,
        ])
    if len(tools) == 1:
        return _invocation(["comments", "list", "review.md", "--status", "all"])
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
    match = re.search(r"refresh it against current files as (urn:uuid:[0-9a-f-]+)", prompt)
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
        ["stage", "refresh", ".", original, "--id", refreshed],
        ["stage", "submit", ".", refreshed],
        ["comments", "validate", "review.md"],
        ["comments", "validate", "notes/decision.md"],
    )
    offset = len(tools) - 1
    return _invocation(commands[offset]) if offset < len(commands) else None


def scripted_response(messages: list[dict]) -> dict | None:
    prompt = "\n".join(
        message.get("content", "")
        for message in messages
        if message.get("role") == "user" and isinstance(message.get("content"), str)
    )
    tools = _tools(messages)
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
