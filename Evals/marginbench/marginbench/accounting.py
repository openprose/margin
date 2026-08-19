"""Deterministic accounting helpers shared by execution and validation."""

from __future__ import annotations

from decimal import Decimal, ROUND_HALF_EVEN


MICRO_USD = Decimal("0.000001")
TOKENS_PER_MILLION = Decimal(1_000_000)


def rounded_token_cost_usd(
    prompt_tokens: int,
    completion_tokens: int,
    input_price_per_million: int | float,
    output_price_per_million: int | float,
) -> float:
    """Return the six-decimal token cost without binary-float accumulation drift."""

    cost = (
        Decimal(prompt_tokens)
        * Decimal(str(input_price_per_million))
        / TOKENS_PER_MILLION
        + Decimal(completion_tokens)
        * Decimal(str(output_price_per_million))
        / TOKENS_PER_MILLION
    )
    return float(cost.quantize(MICRO_USD, rounding=ROUND_HALF_EVEN))
