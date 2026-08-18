"""A loopback-only, fail-closed inference spend gate for paid benchmark runs."""

from __future__ import annotations

import json
import math
import secrets
import threading
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any
from urllib.parse import urlsplit

import httpx


MAX_UPSTREAM_RESPONSE_BYTES = 16 * 1024 * 1024


def _decode_unique_json(raw: bytes) -> object:
    def object_without_duplicates(pairs: list[tuple[str, object]]) -> dict[str, object]:
        result: dict[str, object] = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("duplicate JSON key")
            result[key] = value
        return result

    def reject_nonfinite(value: str) -> object:
        raise ValueError(f"non-finite JSON number: {value}")

    return json.loads(
        raw,
        object_pairs_hook=object_without_duplicates,
        parse_constant=reject_nonfinite,
    )


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
        try:
            model_bytes = len(self.allowed_model.encode("utf-8"))
        except (AttributeError, UnicodeEncodeError):
            model_bytes = 0
        if (
            not isinstance(self.allowed_model, str)
            or not 1 <= model_bytes <= 512
        ):
            raise ValueError("allowed_model must contain between 1 and 512 UTF-8 bytes")
        if (
            not isinstance(self.max_request_bytes, int)
            or isinstance(self.max_request_bytes, bool)
            or not 1 <= self.max_request_bytes <= 16 * 1024 * 1024
        ):
            raise ValueError("max_request_bytes must be between 1 and 16777216")
        if (
            not isinstance(self.template_token_allowance, int)
            or isinstance(self.template_token_allowance, bool)
            or not 0 <= self.template_token_allowance <= 1_000_000
        ):
            raise ValueError("template_token_allowance must be between 0 and 1000000")
        if (
            not isinstance(self.input_token_ceiling, int)
            or isinstance(self.input_token_ceiling, bool)
            or not 1 <= self.input_token_ceiling <= 4_000_000
        ):
            raise ValueError("input_token_ceiling must be between 1 and 4000000")
        if (
            not isinstance(self.max_output_tokens, int)
            or isinstance(self.max_output_tokens, bool)
            or not 1 <= self.max_output_tokens <= 1_000_000
        ):
            raise ValueError("max_output_tokens must be between 1 and 1000000")
        for name, value in (
            ("input_price_per_million", self.input_price_per_million),
            ("output_price_per_million", self.output_price_per_million),
            ("billing_overhead_usd_per_call", self.billing_overhead_usd_per_call),
        ):
            if (
                not isinstance(value, (int, float))
                or isinstance(value, bool)
                or not math.isfinite(value)
                or not 0 <= value <= 1_000
            ):
                raise ValueError(f"{name} must be between 0 and 1000")
        if (
            not isinstance(self.max_total_cost_usd, (int, float))
            or isinstance(self.max_total_cost_usd, bool)
            or not math.isfinite(self.max_total_cost_usd)
            or not 0 < self.max_total_cost_usd <= 1_000
        ):
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


@dataclass(frozen=True)
class InferenceReservation:
    cost_upper_usd: float
    input_tokens_upper: int
    output_tokens_upper: int


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
        self._provider_bound_violations = 0
        self._latched_closed = False

    def reserve(self, request_bytes: int, output_tokens: int) -> InferenceReservation | None:
        input_tokens = self.policy.input_token_upper_bound(request_bytes)
        upper = self.policy.request_cost_upper_bound(request_bytes, output_tokens)
        with self._lock:
            if (
                self._latched_closed
                or self._reserved_upper_usd + upper > self.policy.max_total_cost_usd + 1e-12
            ):
                self._rejected += 1
                return None
            # Reservations are never released, including after provider errors.
            # This makes the cumulative cap pessimistic rather than optimistic.
            self._reserved_upper_usd += upper
            self._forwarded += 1
        return InferenceReservation(upper, input_tokens, output_tokens)

    def reject(self) -> None:
        with self._lock:
            self._rejected += 1

    def record_response(self, payload: object, reservation: InferenceReservation) -> None:
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
        violation = (
            prompt > reservation.input_tokens_upper
            or completion > reservation.output_tokens_upper
            or not math.isfinite(cost)
            or cost > reservation.cost_upper_usd + 1e-12
        )
        with self._lock:
            self._reported_prompt_tokens += prompt
            self._reported_completion_tokens += completion
            self._reported_cost_usd += cost
            if violation:
                self._provider_bound_violations += 1
                self._latched_closed = True

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
                "providerBoundViolationCount": self._provider_bound_violations,
                "latchedClosed": self._latched_closed,
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
            or parsed.username is not None
            or parsed.password is not None
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
                authorizations = self.headers.get_all("authorization", failobj=[])
                expected = f"Bearer {owner.client_token}"
                if (
                    len(authorizations) != 1
                    or not secrets.compare_digest(authorizations[0], expected)
                ):
                    owner.gate.reject()
                    self._json_error(401, "BUDGET_PROXY_UNAUTHORIZED", "Invalid local proxy capability.")
                    return
                request_url = urlsplit(self.path)
                allowed_path = owner.upstream_path + "/chat/completions"
                if (
                    request_url.scheme
                    or request_url.netloc
                    or request_url.path != allowed_path
                    or request_url.query
                    or request_url.fragment
                ):
                    owner.gate.reject()
                    self._json_error(404, "BUDGET_PROXY_ROUTE", "Unsupported inference route.")
                    return
                content_lengths = self.headers.get_all("content-length", failobj=[])
                transfer_encodings = self.headers.get_all("transfer-encoding", failobj=[])
                if len(content_lengths) != 1 or transfer_encodings:
                    owner.gate.reject()
                    self._json_error(400, "BUDGET_PROXY_FRAMING", "Ambiguous request framing is unsupported.")
                    return
                try:
                    length = int(content_lengths[0])
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
                    payload = _decode_unique_json(raw)
                except (UnicodeDecodeError, json.JSONDecodeError, ValueError):
                    owner.gate.reject()
                    self._json_error(400, "BUDGET_PROXY_JSON", "Inference request is not valid JSON.")
                    return
                if not isinstance(payload, dict) or (
                    "stream" in payload and payload["stream"] is not False
                ):
                    owner.gate.reject()
                    self._json_error(400, "BUDGET_PROXY_STREAMING", "Only bounded non-streaming requests are supported.")
                    return
                if payload.get("model") != owner.gate.policy.allowed_model:
                    owner.gate.reject()
                    self._json_error(400, "BUDGET_PROXY_MODEL", "Inference model differs from the priced model.")
                    return
                output_limits = [
                    payload[name]
                    for name in ("max_completion_tokens", "max_tokens")
                    if name in payload
                ]
                if not output_limits or any(
                    not isinstance(value, int)
                    or isinstance(value, bool)
                    or not 1 <= value <= owner.gate.policy.max_output_tokens
                    for value in output_limits
                ):
                    owner.gate.reject()
                    self._json_error(400, "BUDGET_PROXY_OUTPUT_LIMIT", "A bounded output-token limit is required.")
                    return
                output_tokens = max(output_limits)
                try:
                    upstream_body = json.dumps(
                        payload,
                        ensure_ascii=False,
                        allow_nan=False,
                        separators=(",", ":"),
                    ).encode("utf-8")
                except (TypeError, UnicodeEncodeError, ValueError):
                    owner.gate.reject()
                    self._json_error(400, "BUDGET_PROXY_JSON", "Inference request is not canonical JSON.")
                    return
                if len(upstream_body) > owner.gate.policy.max_request_bytes:
                    owner.gate.reject()
                    self._json_error(413, "BUDGET_PROXY_REQUEST_LIMIT", "Inference request exceeds its byte limit.")
                    return
                reservation = owner.gate.reserve(len(upstream_body), output_tokens)
                if reservation is None:
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
                        owner.upstream_origin + allowed_path,
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
                    owner.gate.record_response(
                        _decode_unique_json(response_content),
                        reservation,
                    )
                except (UnicodeDecodeError, json.JSONDecodeError, ValueError):
                    pass
                self.send_response(response_status)
                self.send_header("content-type", response_type)
                self.send_header("content-length", str(len(response_content)))
                self.send_header("connection", "close")
                if response_request_id is not None:
                    self.send_header("x-request-id", response_request_id)
                if response_retry_after is not None:
                    self.send_header("retry-after", response_retry_after)
                self.end_headers()
                self.wfile.write(response_content)
                self.close_connection = True

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
