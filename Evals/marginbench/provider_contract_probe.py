#!/usr/bin/env python3
"""One-request, fail-closed check for a provider's reasoning-token contract.

Dry-run is the default. A live probe requires a separate literal confirmation,
never retries, never runs an agent, and publishes no prompt or response body.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import shutil
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import httpx

sys.dont_write_bytecode = True
PACKAGE_ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(PACKAGE_ROOT))

from marginbench.budget_proxy import InferenceBudgetPolicy, InferenceBudgetProxy  # noqa: E402
from marginbench.schema import canonical_json  # noqa: E402
from marginbench.validation import validate_bytes  # noqa: E402
from prime_pilot import (  # noqa: E402
    DEFAULT_PROVIDER_RESPONSE_TOKEN_ALLOWANCE,
    WALLET_DEBIT_ATTRIBUTION,
    WALLET_OBSERVATION_SCOPE,
    _write_new_artifact,
    claim_paid_start,
    load_prime_inference_credentials,
    resolve_provider_reasoning_contract,
    wallet,
)


PLAN_SCHEMA = "urn:marginbench:provider-contract-probe-plan:v1"
RESULT_SCHEMA = "urn:marginbench:provider-contract-probe:v1"
CONFIRMATION = "RUN_PAID_PROVIDER_CONTRACT_PROBE"
PROVIDER = "Prime Intellect"
PUBLIC_PROMPT = "Return exactly one lowercase word: ready"
PUBLIC_PROMPT_SHA256 = "sha256:" + hashlib.sha256(PUBLIC_PROMPT.encode("utf-8")).hexdigest()
DEFAULT_MAX_COST_USD = 0.001
HARD_MAX_COST_USD = 0.01


def _finite_nonnegative(value: float, name: str) -> float:
    if (
        not isinstance(value, (int, float))
        or isinstance(value, bool)
        or not math.isfinite(value)
        or value < 0
    ):
        raise ValueError(f"{name} must be finite and nonnegative")
    return float(value)


def _https_source(value: str, name: str) -> str:
    if (
        not isinstance(value, str)
        or not value.startswith("https://")
        or len(value.encode("utf-8")) > 2_048
    ):
        raise ValueError(f"{name} must be a bounded HTTPS evidence URL")
    return value


def build_plan(
    *,
    model: str,
    visible_token_ceiling: int,
    reasoning_token_ceiling: int | None,
    reasoning_token_ceiling_source: str | None,
    response_token_allowance: int,
    max_request_bytes: int,
    template_token_allowance: int,
    input_token_ceiling: int,
    input_token_ceiling_source: str,
    input_price_per_million: float,
    output_price_per_million: float,
    pricing_source: str,
    billing_overhead_usd_per_call: float,
    max_cost_usd: float,
    minimum_wallet_reserve_usd: float,
    timeout_seconds: float,
    minimum_start_interval_seconds: float,
) -> dict[str, Any]:
    if not isinstance(model, str) or not model or len(model.encode("utf-8")) > 256:
        raise ValueError("model must be bounded nonempty text")
    reasoning_token_ceiling, reasoning_token_ceiling_source = (
        resolve_provider_reasoning_contract(
            model,
            reasoning_token_ceiling,
            reasoning_token_ceiling_source,
        )
    )
    if reasoning_token_ceiling is None or reasoning_token_ceiling_source is None:
        raise ValueError("a source-backed reasoning-token ceiling is required")
    _https_source(input_token_ceiling_source, "input-token-ceiling-source")
    _https_source(pricing_source, "pricing-source")
    policy = InferenceBudgetPolicy(
        allowed_model=model,
        max_request_bytes=max_request_bytes,
        template_token_allowance=template_token_allowance,
        input_token_ceiling=input_token_ceiling,
        max_output_tokens=visible_token_ceiling,
        reasoning_token_ceiling=reasoning_token_ceiling,
        response_token_allowance=response_token_allowance,
        input_price_per_million=_finite_nonnegative(
            input_price_per_million, "input-price-per-million"
        ),
        output_price_per_million=_finite_nonnegative(
            output_price_per_million, "output-price-per-million"
        ),
        billing_overhead_usd_per_call=_finite_nonnegative(
            billing_overhead_usd_per_call, "billing-overhead-usd-per-call"
        ),
        max_total_cost_usd=max_cost_usd,
    )
    if not 0 < max_cost_usd <= HARD_MAX_COST_USD:
        raise ValueError(f"max-cost-usd must be above zero and at most {HARD_MAX_COST_USD}")
    if not 0 <= minimum_wallet_reserve_usd <= 1_000_000:
        raise ValueError("minimum-wallet-reserve-usd must be between zero and 1000000")
    if not 0 < timeout_seconds <= 300:
        raise ValueError("timeout-seconds must be above zero and at most 300")
    if not 0 <= minimum_start_interval_seconds <= 3_600:
        raise ValueError("minimum-start-interval-seconds must be between zero and 3600")
    maximum = policy.request_cost_upper_bound(max_request_bytes, visible_token_ceiling)
    if maximum > max_cost_usd + 1e-12:
        raise ValueError(
            "the complete one-request reservation exceeds max-cost-usd; "
            "reduce a token or request bound explicitly"
        )
    return {
        "schema": PLAN_SCHEMA,
        "provider": PROVIDER,
        "model": model,
        "endpointKind": "openai-chat-completions",
        "requestCount": 1,
        "promptSha256": PUBLIC_PROMPT_SHA256,
        "limits": {
            "visibleTokenCeiling": visible_token_ceiling,
            "reasoningTokenCeiling": reasoning_token_ceiling,
            "reasoningTokenCeilingSource": reasoning_token_ceiling_source,
            "responseTokenAllowance": response_token_allowance,
            "maxRequestBytes": max_request_bytes,
            "templateTokenAllowance": template_token_allowance,
            "inputTokenCeiling": input_token_ceiling,
            "inputTokenCeilingSource": input_token_ceiling_source,
            "timeoutSeconds": timeout_seconds,
            "minimumStartIntervalSeconds": minimum_start_interval_seconds,
        },
        "pricing": {
            "inputPricePerMillion": float(input_price_per_million),
            "outputPricePerMillion": float(output_price_per_million),
            "billingOverheadUSDPerCall": float(billing_overhead_usd_per_call),
            "source": pricing_source,
        },
        "budget": {
            "currency": "USD",
            "maximumReservedCostUSD": round(maximum, 9),
            "hardCapUSD": round(float(max_cost_usd), 9),
            "minimumWalletReserveUSD": round(float(minimum_wallet_reserve_usd), 6),
        },
        "safety": {
            "agentProcesses": 0,
            "automaticRetries": 0,
            "fixedPublicPrompt": True,
            "rawPromptPublished": False,
            "rawResponsePublished": False,
            "credentialsPublished": False,
            "explicitConfirmationRequired": True,
        },
        "paidModelsInvoked": False,
    }


def _usage(payload: Any) -> tuple[int | None, int | None, int | None]:
    if not isinstance(payload, dict) or not isinstance(payload.get("usage"), dict):
        return None, None, None
    usage = payload["usage"]
    prompt = usage.get("prompt_tokens")
    completion = usage.get("completion_tokens")
    details = usage.get("completion_tokens_details")
    reasoning = details.get("reasoning_tokens") if isinstance(details, dict) else None
    values = []
    for value in (prompt, completion, reasoning):
        values.append(value if isinstance(value, int) and not isinstance(value, bool) and value >= 0 else None)
    return values[0], values[1], values[2]


def execute_probe(
    plan: dict[str, Any],
    *,
    upstream_base_url: str,
    upstream_api_key: str,
    team_id: str | None = None,
) -> dict[str, Any]:
    receipt = validate_bytes(canonical_json(plan))
    if not receipt["valid"] or receipt.get("artifactSchema") != PLAN_SCHEMA:
        raise ValueError("provider-contract probe plan is invalid")
    limits = plan["limits"]
    pricing = plan["pricing"]
    policy = InferenceBudgetPolicy(
        allowed_model=plan["model"],
        max_request_bytes=limits["maxRequestBytes"],
        template_token_allowance=limits["templateTokenAllowance"],
        input_token_ceiling=limits["inputTokenCeiling"],
        max_output_tokens=limits["visibleTokenCeiling"],
        reasoning_token_ceiling=limits["reasoningTokenCeiling"],
        response_token_allowance=limits["responseTokenAllowance"],
        input_price_per_million=pricing["inputPricePerMillion"],
        output_price_per_million=pricing["outputPricePerMillion"],
        billing_overhead_usd_per_call=pricing["billingOverheadUSDPerCall"],
        max_total_cost_usd=plan["budget"]["hardCapUSD"],
    )
    started_at = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
    started = time.monotonic()
    response_status = 0
    response_payload: Any = None
    with InferenceBudgetProxy(
        upstream_base_url,
        upstream_api_key,
        policy,
        team_id=team_id,
        timeout_seconds=limits["timeoutSeconds"],
    ) as proxy:
        try:
            with httpx.Client(timeout=limits["timeoutSeconds"], follow_redirects=False) as client:
                response = client.post(
                    proxy.base_url + "/chat/completions",
                    headers={"authorization": f"Bearer {proxy.client_token}"},
                    json={
                        "model": plan["model"],
                        "messages": [{"role": "user", "content": PUBLIC_PROMPT}],
                        "max_tokens": limits["visibleTokenCeiling"],
                        "stream": False,
                        "temperature": 0,
                    },
                )
                response_status = response.status_code
                try:
                    response_payload = response.json()
                except (UnicodeDecodeError, json.JSONDecodeError, ValueError):
                    response_payload = None
        except httpx.HTTPError:
            response_payload = None
        live_budget = proxy.gate.report()

    prompt_tokens, completion_tokens, reasoning_tokens = _usage(response_payload)
    assistant_present = False
    if isinstance(response_payload, dict) and isinstance(response_payload.get("choices"), list):
        for choice in response_payload["choices"]:
            message = choice.get("message") if isinstance(choice, dict) else None
            content = message.get("content") if isinstance(message, dict) else None
            if isinstance(content, str) and bool(content.strip()):
                assistant_present = True
                break
    usage_bound = (
        completion_tokens is not None
        and completion_tokens
        <= limits["visibleTokenCeiling"]
        + limits["reasoningTokenCeiling"]
        + limits["responseTokenAllowance"]
        and live_budget["providerBoundViolationCount"] == 0
    )
    checks = {
        "providerReturnedSuccessForRequestWithReasoningParameter": response_status == 200,
        "exactlyOneRequestForwarded": live_budget["forwardedRequestCount"] == 1,
        "usageReportedWithinFrozenBound": usage_bound,
        "assistantResponsePresent": assistant_present,
        "proxyRemainedOpen": live_budget["latchedClosed"] is False,
    }
    errors: list[str] = []
    if response_status != 200:
        errors.append("PROVIDER_CONTRACT_REJECTED")
    if live_budget["providerBoundViolationCount"]:
        errors.append("PROVIDER_USAGE_BOUND_VIOLATION")
    if response_status == 200 and (completion_tokens is None or not assistant_present):
        errors.append("PROVIDER_RESPONSE_INVALID")
    if live_budget["forwardedRequestCount"] != 1:
        errors.append("PROBE_REQUEST_COUNT_INVALID")
    status = "passed" if all(checks.values()) and not errors else "infrastructure_error"
    return {
        "schema": RESULT_SCHEMA,
        "planSha256": "sha256:" + hashlib.sha256(canonical_json(plan)).hexdigest(),
        "provider": plan["provider"],
        "model": plan["model"],
        "status": status,
        "startedAt": started_at,
        "durationMs": round((time.monotonic() - started) * 1_000, 3),
        "requestCount": 1,
        "contract": {
            "endpointKind": plan["endpointKind"],
            "promptSha256": plan["promptSha256"],
            "visibleTokenCeiling": limits["visibleTokenCeiling"],
            "reasoningTokenCeiling": limits["reasoningTokenCeiling"],
            "reasoningTokenCeilingSource": limits["reasoningTokenCeilingSource"],
            "responseTokenAllowance": limits["responseTokenAllowance"],
        },
        "observed": {
            "httpStatus": response_status,
            "promptTokens": prompt_tokens,
            "completionTokens": completion_tokens,
            "reasoningTokens": reasoning_tokens,
            "assistantResponsePresent": assistant_present,
        },
        "checks": checks,
        "infrastructureCodes": errors,
        "liveBudget": live_budget,
        "wallet": {
            "observationScope": WALLET_OBSERVATION_SCOPE,
            "debitAttribution": WALLET_DEBIT_ATTRIBUTION,
            "afterAvailable": False,
            "observedDebitUSD": None,
        },
        "privacy": {
            "credentialsPresent": False,
            "rawPromptPublished": False,
            "rawResponsePublished": False,
        },
        "paidModelsInvoked": live_budget["forwardedRequestCount"] > 0,
        "automaticRetryCount": 0,
    }


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", required=True)
    parser.add_argument("--visible-token-ceiling", type=int, default=16)
    parser.add_argument("--reasoning-token-ceiling", type=int)
    parser.add_argument("--reasoning-token-ceiling-source")
    parser.add_argument(
        "--response-token-allowance",
        type=int,
        default=DEFAULT_PROVIDER_RESPONSE_TOKEN_ALLOWANCE,
    )
    parser.add_argument("--max-request-bytes", type=int, default=4_096)
    parser.add_argument("--template-token-allowance", type=int, default=256)
    parser.add_argument("--input-token-ceiling", type=int, required=True)
    parser.add_argument("--input-token-ceiling-source", required=True)
    parser.add_argument("--input-price-per-million", type=float, required=True)
    parser.add_argument("--output-price-per-million", type=float, required=True)
    parser.add_argument("--pricing-source", required=True)
    parser.add_argument("--billing-overhead-usd-per-call", type=float, default=0.0002)
    parser.add_argument("--max-cost-usd", type=float, default=DEFAULT_MAX_COST_USD)
    parser.add_argument("--minimum-wallet-reserve-usd", type=float, default=190.0)
    parser.add_argument("--timeout-seconds", type=float, default=60.0)
    parser.add_argument("--minimum-start-interval-seconds", type=float, default=300.0)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--execute", action="store_true")
    parser.add_argument(
        "--confirm-paid",
        help=f"live execution requires the literal {CONFIRMATION}",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    arguments = _parser().parse_args(argv)
    try:
        plan = build_plan(
            model=arguments.model,
            visible_token_ceiling=arguments.visible_token_ceiling,
            reasoning_token_ceiling=arguments.reasoning_token_ceiling,
            reasoning_token_ceiling_source=arguments.reasoning_token_ceiling_source,
            response_token_allowance=arguments.response_token_allowance,
            max_request_bytes=arguments.max_request_bytes,
            template_token_allowance=arguments.template_token_allowance,
            input_token_ceiling=arguments.input_token_ceiling,
            input_token_ceiling_source=arguments.input_token_ceiling_source,
            input_price_per_million=arguments.input_price_per_million,
            output_price_per_million=arguments.output_price_per_million,
            pricing_source=arguments.pricing_source,
            billing_overhead_usd_per_call=arguments.billing_overhead_usd_per_call,
            max_cost_usd=arguments.max_cost_usd,
            minimum_wallet_reserve_usd=arguments.minimum_wallet_reserve_usd,
            timeout_seconds=arguments.timeout_seconds,
            minimum_start_interval_seconds=arguments.minimum_start_interval_seconds,
        )
    except ValueError as error:
        raise SystemExit(str(error)) from error
    if not arguments.execute:
        if arguments.output is not None or arguments.confirm_paid is not None:
            raise SystemExit("--output and --confirm-paid are live-execution options")
        print(canonical_json(plan).decode("utf-8"))
        return 0
    if arguments.confirm_paid != CONFIRMATION:
        raise SystemExit(f"live execution requires --confirm-paid {CONFIRMATION}")
    if arguments.output is None:
        raise SystemExit("live execution requires --output")
    output = arguments.output.expanduser()
    if output.is_symlink() or output.exists():
        raise SystemExit(f"refusing to replace an existing output: {output}")
    prime_name = shutil.which("prime")
    if not prime_name:
        raise SystemExit("Prime CLI is not installed")
    prime = Path(prime_name).resolve()
    before = wallet(prime)
    if before["balanceUSD"] - plan["budget"]["hardCapUSD"] < plan["budget"]["minimumWalletReserveUSD"]:
        raise SystemExit("wallet reserve would be crossed by the hard probe cap")
    claim_paid_start(
        PACKAGE_ROOT / "runs" / ".last-paid-provider-contract-probe-start",
        now=time.time(),
        minimum_interval_seconds=plan["limits"]["minimumStartIntervalSeconds"],
    )
    try:
        inference_url, api_key, team_id = load_prime_inference_credentials()
        result = execute_probe(
            plan,
            upstream_base_url=inference_url,
            upstream_api_key=api_key,
            team_id=team_id,
        )
    except (OSError, RuntimeError, ValueError) as error:
        raise SystemExit("provider-contract probe could not start safely") from error
    try:
        after = wallet(prime)
        observed_debit = round(max(0.0, before["balanceUSD"] - after["balanceUSD"]), 6)
        result["wallet"] = {
            "observationScope": WALLET_OBSERVATION_SCOPE,
            "debitAttribution": WALLET_DEBIT_ATTRIBUTION,
            "afterAvailable": True,
            "observedDebitUSD": observed_debit,
        }
    except RuntimeError:
        result["status"] = "infrastructure_error"
        result["infrastructureCodes"].append("WALLET_AFTER_UNAVAILABLE")
    raw = canonical_json(result) + b"\n"
    receipt = validate_bytes(raw)
    if not receipt["valid"] or receipt.get("artifactSchema") != RESULT_SCHEMA:
        raise SystemExit("provider-contract probe result failed local validation")
    _write_new_artifact(output, raw)
    print(raw.decode("utf-8"), end="")
    return 0 if result["status"] == "passed" else 2


if __name__ == "__main__":
    raise SystemExit(main())
