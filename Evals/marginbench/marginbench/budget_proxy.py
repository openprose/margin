"""A loopback-only, fail-closed inference spend gate for paid benchmark runs."""

from __future__ import annotations

import json
import secrets
import threading
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any
from urllib.parse import urlsplit

import httpx


MAX_UPSTREAM_RESPONSE_BYTES = 16 * 1024 * 1024


@dataclass(frozen=True)
class InferenceBudgetPolicy:
    allowed_model: str
    max_request_bytes: int
    template_token_allowance: int
    input_token_ceiling: int
    max_output_tokens: int
    input_price_per_million: float
    output_price_per_million: float
    billing_overhead_usd_per_call: float
    max_total_cost_usd: float

    def __post_init__(self) -> None:
        if (
            not isinstance(self.allowed_model, str)
            or not self.allowed_model
            or len(self.allowed_model) > 512
        ):
            raise ValueError("allowed_model must contain between 1 and 512 characters")
        if not 1 <= self.max_request_bytes <= 16 * 1024 * 1024:
            raise ValueError("max_request_bytes must be between 1 and 16777216")
        if not 0 <= self.template_token_allowance <= 1_000_000:
            raise ValueError("template_token_allowance must be between 0 and 1000000")
        if not 1 <= self.input_token_ceiling <= 4_000_000:
            raise ValueError("input_token_ceiling must be between 1 and 4000000")
        if not 1 <= self.max_output_tokens <= 1_000_000:
            raise ValueError("max_output_tokens must be between 1 and 1000000")
        for name, value in (
            ("input_price_per_million", self.input_price_per_million),
            ("output_price_per_million", self.output_price_per_million),
            ("billing_overhead_usd_per_call", self.billing_overhead_usd_per_call),
        ):
            if not 0 <= value <= 1_000:
                raise ValueError(f"{name} must be between 0 and 1000")
        if not 0 < self.max_total_cost_usd <= 1_000:
            raise ValueError("max_total_cost_usd must be between 0 and 1000")

    def input_token_upper_bound(self, request_bytes: int) -> int:
        # A UTF-8 BPE token consumes at least one source byte. Doubling the
        # complete JSON request plus a chat-template allowance is conservative
        # without loading mutable tokenizer code; the separately verified
        # provider/model context contract is an independent upper bound.
        return min(
            self.input_token_ceiling,
            request_bytes * 2 + self.template_token_allowance,
        )

    def request_cost_upper_bound(self, request_bytes: int, output_tokens: int) -> float:
        return (
            self.input_token_upper_bound(request_bytes)
            * self.input_price_per_million
            / 1_000_000
            + output_tokens * self.output_price_per_million / 1_000_000
            + self.billing_overhead_usd_per_call
        )


class InferenceBudgetGate:
    def __init__(self, policy: InferenceBudgetPolicy) -> None:
        self.policy = policy
        self._lock = threading.Lock()
        self._forwarded = 0
        self._rejected = 0
        self._reserved_upper_usd = 0.0
        self._reported_prompt_tokens = 0
        self._reported_completion_tokens = 0
        self._reported_cost_usd = 0.0

    def reserve(self, request_bytes: int, output_tokens: int) -> float | None:
        upper = self.policy.request_cost_upper_bound(request_bytes, output_tokens)
        with self._lock:
            if self._reserved_upper_usd + upper > self.policy.max_total_cost_usd + 1e-12:
                self._rejected += 1
                return None
            # Reservations are never released, including after provider errors.
            # This makes the cumulative cap pessimistic rather than optimistic.
            self._reserved_upper_usd += upper
            self._forwarded += 1
        return upper

    def reject(self) -> None:
        with self._lock:
            self._rejected += 1

    def record_response(self, payload: object) -> None:
        if not isinstance(payload, dict):
            return
        usage = payload.get("usage")
        if not isinstance(usage, dict):
            return
        prompt = usage.get("prompt_tokens", 0)
        completion = usage.get("completion_tokens", 0)
        if (
            not isinstance(prompt, int)
            or isinstance(prompt, bool)
            or prompt < 0
            or not isinstance(completion, int)
            or isinstance(completion, bool)
            or completion < 0
        ):
            return
        cost = (
            prompt * self.policy.input_price_per_million / 1_000_000
            + completion * self.policy.output_price_per_million / 1_000_000
        )
        with self._lock:
            self._reported_prompt_tokens += prompt
            self._reported_completion_tokens += completion
            self._reported_cost_usd += cost

    def report(self) -> dict[str, Any]:
        with self._lock:
            return {
                "enabled": True,
                "forwardedRequestCount": self._forwarded,
                "rejectedRequestCount": self._rejected,
                "reservedCostUpperBoundUSD": round(self._reserved_upper_usd, 6),
                "reportedPromptTokens": self._reported_prompt_tokens,
                "reportedCompletionTokens": self._reported_completion_tokens,
                "reportedTokenCostUSD": round(self._reported_cost_usd, 6),
                "policy": {
                    "allowedModel": self.policy.allowed_model,
                    "maxRequestBytes": self.policy.max_request_bytes,
                    "templateTokenAllowance": self.policy.template_token_allowance,
                    "inputTokenCeiling": self.policy.input_token_ceiling,
                    "maxOutputTokens": self.policy.max_output_tokens,
                    "inputPricePerMillion": self.policy.input_price_per_million,
                    "outputPricePerMillion": self.policy.output_price_per_million,
                    "billingOverheadUSDPerCall": self.policy.billing_overhead_usd_per_call,
                    "maxTotalCostUSD": self.policy.max_total_cost_usd,
                },
            }


class InferenceBudgetProxy:
    """Forward non-streaming OpenAI-compatible calls through a bounded local gate."""

    def __init__(
        self,
        upstream_base_url: str,
        upstream_api_key: str,
        policy: InferenceBudgetPolicy,
        *,
        team_id: str | None = None,
        timeout_seconds: float = 120.0,
    ) -> None:
        parsed = urlsplit(upstream_base_url)
        test_loopback = parsed.scheme == "http" and parsed.hostname in {"127.0.0.1", "localhost"}
        if (
            (parsed.scheme != "https" and not test_loopback)
            or not parsed.hostname
            or parsed.query
            or parsed.fragment
        ):
            raise ValueError("upstream_base_url must be HTTPS (or loopback HTTP for tests)")
        if not upstream_api_key:
            raise ValueError("upstream_api_key is required")
        if not 0 < timeout_seconds <= 300:
            raise ValueError("timeout_seconds must be between 0 and 300")
        self.upstream_origin = f"{parsed.scheme}://{parsed.netloc}"
        self.upstream_path = parsed.path.rstrip("/")
        self.upstream_api_key = upstream_api_key
        self.team_id = team_id
        self.timeout_seconds = timeout_seconds
        self.client_token = secrets.token_urlsafe(32)
        self.gate = InferenceBudgetGate(policy)
        self._client = httpx.Client(timeout=timeout_seconds, follow_redirects=False)
        self._server: ThreadingHTTPServer | None = None
        self._thread: threading.Thread | None = None

    @property
    def base_url(self) -> str:
        if self._server is None:
            raise RuntimeError("Inference budget proxy is not running")
        host, port = self._server.server_address[:2]
        return f"http://{host}:{port}{self.upstream_path}"

    def __enter__(self) -> "InferenceBudgetProxy":
        owner = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, format: str, *args: object) -> None:
                return

            def _json_error(self, status: int, code: str, message: str) -> None:
                raw = json.dumps(
                    {"error": {"code": code, "message": message, "type": "marginbench_budget_error"}},
                    separators=(",", ":"),
                ).encode("utf-8")
                self.send_response(status)
                self.send_header("content-type", "application/json")
                self.send_header("content-length", str(len(raw)))
                self.send_header("connection", "close")
                self.end_headers()
                self.wfile.write(raw)
                self.close_connection = True

            def do_POST(self) -> None:  # noqa: N802
                authorization = self.headers.get("authorization", "")
                expected = f"Bearer {owner.client_token}"
                if not secrets.compare_digest(authorization, expected):
                    owner.gate.reject()
                    self._json_error(401, "BUDGET_PROXY_UNAUTHORIZED", "Invalid local proxy capability.")
                    return
                request_url = urlsplit(self.path)
                allowed_path = owner.upstream_path + "/chat/completions"
                if request_url.path != allowed_path or request_url.query or request_url.fragment:
                    owner.gate.reject()
                    self._json_error(404, "BUDGET_PROXY_ROUTE", "Unsupported inference route.")
                    return
                length_value = self.headers.get("content-length")
                try:
                    length = int(length_value or "")
                except ValueError:
                    length = -1
                if length < 0 or length > owner.gate.policy.max_request_bytes:
                    owner.gate.reject()
                    self._json_error(413, "BUDGET_PROXY_REQUEST_LIMIT", "Inference request exceeds its byte limit.")
                    return
                raw = self.rfile.read(length)
                if len(raw) != length:
                    owner.gate.reject()
                    self._json_error(400, "BUDGET_PROXY_TRUNCATED", "Inference request body is incomplete.")
                    return
                try:
                    payload = json.loads(raw)
                except (UnicodeDecodeError, json.JSONDecodeError):
                    owner.gate.reject()
                    self._json_error(400, "BUDGET_PROXY_JSON", "Inference request is not valid JSON.")
                    return
                if not isinstance(payload, dict) or payload.get("stream") is True:
                    owner.gate.reject()
                    self._json_error(400, "BUDGET_PROXY_STREAMING", "Only bounded non-streaming requests are supported.")
                    return
                if payload.get("model") != owner.gate.policy.allowed_model:
                    owner.gate.reject()
                    self._json_error(400, "BUDGET_PROXY_MODEL", "Inference model differs from the priced model.")
                    return
                output_tokens = payload.get("max_completion_tokens", payload.get("max_tokens"))
                if (
                    not isinstance(output_tokens, int)
                    or isinstance(output_tokens, bool)
                    or not 1 <= output_tokens <= owner.gate.policy.max_output_tokens
                ):
                    owner.gate.reject()
                    self._json_error(400, "BUDGET_PROXY_OUTPUT_LIMIT", "A bounded output-token limit is required.")
                    return
                try:
                    upstream_body = json.dumps(
                        payload,
                        ensure_ascii=False,
                        allow_nan=False,
                        separators=(",", ":"),
                    ).encode("utf-8")
                except (TypeError, ValueError):
                    owner.gate.reject()
                    self._json_error(400, "BUDGET_PROXY_JSON", "Inference request is not canonical JSON.")
                    return
                if owner.gate.reserve(length, output_tokens) is None:
                    self._json_error(429, "BUDGET_PROXY_COST_LIMIT", "Cumulative inference cost bound exhausted.")
                    return

                headers = {
                    "authorization": f"Bearer {owner.upstream_api_key}",
                    "content-type": "application/json",
                    "accept": "application/json",
                    "accept-encoding": "identity",
                }
                if owner.team_id:
                    headers["x-prime-team-id"] = owner.team_id
                try:
                    with owner._client.stream(
                        "POST",
                        owner.upstream_origin + self.path,
                        content=upstream_body,
                        headers=headers,
                    ) as response:
                        response_content = bytearray()
                        for chunk in response.iter_bytes():
                            response_content.extend(chunk)
                            if len(response_content) > MAX_UPSTREAM_RESPONSE_BYTES:
                                self._json_error(
                                    502,
                                    "BUDGET_PROXY_RESPONSE_LIMIT",
                                    "Inference provider response exceeds its byte limit.",
                                )
                                return
                        response_status = response.status_code
                        response_type = response.headers.get("content-type", "application/json")
                        response_request_id = response.headers.get("x-request-id")
                        response_retry_after = response.headers.get("retry-after")
                except httpx.HTTPError:
                    self._json_error(502, "BUDGET_PROXY_UPSTREAM", "Inference provider request failed.")
                    return
                try:
                    owner.gate.record_response(json.loads(response_content))
                except (UnicodeDecodeError, json.JSONDecodeError):
                    pass
                self.send_response(response_status)
                self.send_header("content-type", response_type)
                self.send_header("content-length", str(len(response_content)))
                if response_request_id is not None:
                    self.send_header("x-request-id", response_request_id)
                if response_retry_after is not None:
                    self.send_header("retry-after", response_retry_after)
                self.end_headers()
                self.wfile.write(response_content)

        self._server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self._server.daemon_threads = True
        self._thread = threading.Thread(target=self._server.serve_forever, daemon=True)
        self._thread.start()
        return self

    def __exit__(self, exc_type, exc, traceback) -> None:
        if self._server is not None:
            self._server.shutdown()
            self._server.server_close()
        if self._thread is not None:
            self._thread.join(timeout=5)
        self._client.close()
        self._server = None
        self._thread = None
