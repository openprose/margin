"""Local scripted OpenAI endpoint for transcript-isolation preflight.

The endpoint reconstructs the next public plain-workspace action from the
conversation it receives. It never receives an episode object or oracle. A
role-specific canary is included in every assistant message so accidental
cross-role transcript reuse becomes directly observable.
"""

from __future__ import annotations

import asyncio
import hashlib
import json
import threading
import time
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Iterator

from .plain_scripted import run_plain_scripted_role
from .schema import canonical_json


class _NextWorkspaceCall(Exception):
    def __init__(self, arguments: dict[str, Any]) -> None:
        super().__init__("next workspace call")
        self.arguments = arguments


def _decode_object(value: object) -> dict[str, Any]:
    if isinstance(value, dict):
        return value
    if not isinstance(value, str):
        raise ValueError("Plain fake model received a non-object tool result.")
    decoded = json.loads(value)
    if not isinstance(decoded, dict):
        raise ValueError("Plain fake model received a non-object tool result.")
    return decoded


def _tool_result(message: dict[str, Any]) -> dict[str, Any]:
    value = _decode_object(message.get("content"))
    # Prime's null harness wraps MCP text in stdout. Direct OpenAI-compatible
    # harnesses may pass the gateway object through unchanged.
    stdout = value.get("stdout")
    if isinstance(stdout, (str, dict)):
        return _decode_object(stdout)
    return value


def _history(messages: list[dict[str, Any]], start: int) -> list[tuple[dict[str, Any], dict[str, Any]]]:
    pending: dict[str, dict[str, Any]] = {}
    history: list[tuple[dict[str, Any], dict[str, Any]]] = []
    for message in messages[start:]:
        role = message.get("role")
        if role == "assistant":
            calls = message.get("tool_calls") or []
            if not isinstance(calls, list) or len(calls) > 1:
                raise ValueError("Plain fake model requires zero or one tool call per turn.")
            if not calls:
                continue
            call = calls[0]
            function = call.get("function") if isinstance(call, dict) else None
            if not isinstance(function, dict) or function.get("name") != "workspace":
                raise ValueError("Plain fake model observed an unexpected tool name.")
            identifier = call.get("id")
            if not isinstance(identifier, str) or identifier in pending:
                raise ValueError("Plain fake model observed an invalid tool call id.")
            arguments = _decode_object(function.get("arguments"))
            pending[identifier] = arguments
        elif role == "tool":
            identifier = message.get("tool_call_id")
            if not isinstance(identifier, str) or identifier not in pending:
                raise ValueError("Plain fake model observed an unmatched tool result.")
            history.append((pending.pop(identifier), _tool_result(message)))
    if pending:
        raise ValueError("Plain fake model observed a tool call without its result.")
    return history


async def _next_invocation(
    prompt: str,
    history: list[tuple[dict[str, Any], dict[str, Any]]],
) -> dict[str, Any] | None:
    index = 0

    async def call(**arguments: Any) -> dict[str, Any]:
        nonlocal index
        if index == len(history):
            raise _NextWorkspaceCall(arguments)
        expected, result = history[index]
        if canonical_json(arguments) != canonical_json(expected):
            raise ValueError("Plain fake model transcript diverged from its public policy.")
        index += 1
        return result

    try:
        await run_plain_scripted_role(prompt, call)
    except _NextWorkspaceCall as next_call:
        return next_call.arguments
    if index != len(history):
        raise ValueError("Plain fake model transcript contains unused tool results.")
    return None


def scripted_plain_response(messages: list[dict[str, Any]]) -> tuple[str, dict[str, Any] | None]:
    user_positions = [
        index
        for index, message in enumerate(messages)
        if message.get("role") == "user" and isinstance(message.get("content"), str)
    ]
    if len(user_positions) != 1:
        raise ValueError("A role-separated plain rollout must contain exactly one user brief.")
    current = user_positions[0]
    prompt = str(messages[current]["content"])
    history = _history(messages, current + 1)
    invocation = asyncio.run(_next_invocation(prompt, history))
    return prompt, invocation


def _message_strings(value: object) -> Iterator[str]:
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for child in value.values():
            yield from _message_strings(child)
    elif isinstance(value, list):
        for child in value:
            yield from _message_strings(child)


class _PlainHandler(BaseHTTPRequestHandler):
    request_count = 0
    cross_role_canary_leak_count = 0
    own_canary_missing_count = 0
    own_canary_echo_count = 0
    malformed_request_count = 0
    prompt_digests: set[str] = set()
    canaries: dict[str, str] = {}
    lock = threading.Lock()

    def log_message(self, _format, *_args) -> None:
        return None

    def do_POST(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        try:
            size = int(self.headers.get("content-length", "0"))
            if not 0 < size <= 1_048_576:
                raise ValueError("Plain fake model request size is outside the bound.")
            request = json.loads(self.rfile.read(size))
            messages = request.get("messages") if isinstance(request, dict) else None
            if not isinstance(messages, list):
                raise ValueError("Plain fake model request lacks messages.")
            prompt, invocation = scripted_plain_response(messages)
            prompt_digest = hashlib.sha256(prompt.encode("utf-8")).hexdigest()
            canary = f"marginbench-isolation-{prompt_digest[:24]}"
            rendered_request = "\n".join(_message_strings(messages))
            with type(self).lock:
                prior_own_canary = type(self).canaries.get(prompt_digest)
                if prior_own_canary is not None:
                    if prior_own_canary in rendered_request:
                        type(self).own_canary_echo_count += 1
                    else:
                        type(self).own_canary_missing_count += 1
                other_canaries = {
                    value
                    for digest, value in type(self).canaries.items()
                    if digest != prompt_digest
                }
                type(self).cross_role_canary_leak_count += sum(
                    value in rendered_request for value in other_canaries
                )
                type(self).prompt_digests.add(prompt_digest)
                type(self).canaries[prompt_digest] = canary
                type(self).request_count += 1
                request_number = type(self).request_count
        except (TypeError, ValueError, json.JSONDecodeError):
            with type(self).lock:
                type(self).malformed_request_count += 1
            self.send_error(400)
            return

        if invocation is None:
            message = {
                "role": "assistant",
                "content": f"Completed and verified. {canary}",
            }
            finish_reason = "stop"
        else:
            message = {
                "role": "assistant",
                "content": canary,
                "tool_calls": [{
                    "id": f"plain_call_{request_number}",
                    "type": "function",
                    "function": {
                        "name": "workspace",
                        "arguments": json.dumps(invocation, separators=(",", ":")),
                    },
                }],
            }
            finish_reason = "tool_calls"
        response = {
            "id": f"marginbench-plain-fake-{request_number}",
            "object": "chat.completion",
            "created": int(time.time()),
            "model": request.get("model", "marginbench-plain-fake"),
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
def plain_fake_model_server():
    _PlainHandler.request_count = 0
    _PlainHandler.cross_role_canary_leak_count = 0
    _PlainHandler.own_canary_missing_count = 0
    _PlainHandler.own_canary_echo_count = 0
    _PlainHandler.malformed_request_count = 0
    _PlainHandler.prompt_digests = set()
    _PlainHandler.canaries = {}
    server = ThreadingHTTPServer(("127.0.0.1", 0), _PlainHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield server, _PlainHandler
    finally:
        server.shutdown()
        thread.join(timeout=5)
        server.server_close()
