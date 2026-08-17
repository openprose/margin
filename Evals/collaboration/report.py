#!/usr/bin/env python3
"""Privacy-safe collaboration eval aggregation and Markdown rendering."""

from __future__ import annotations

import hashlib
import math
import random
import statistics
from collections import defaultdict
from typing import Any, Mapping, Sequence


def mean_confidence_interval(
    values: Sequence[float],
    *,
    seed_material: str,
    weights: Sequence[float] | None = None,
    confidence: float = 0.95,
    resamples: int = 10_000,
) -> dict[str, Any]:
    if not values:
        return {"confidence": confidence, "high": None, "low": None, "mean": None, "n": 0}
    if weights is None:
        weights = [1.0] * len(values)
    if len(weights) != len(values) or any(weight <= 0 for weight in weights):
        raise ValueError("Confidence-interval weights must be positive and match values.")

    def weighted_mean(indices: Sequence[int]) -> float:
        denominator = sum(weights[index] for index in indices)
        return sum(values[index] * weights[index] for index in indices) / denominator

    mean = weighted_mean(list(range(len(values))))
    if len(values) == 1:
        return {
            "confidence": confidence,
            "high": round(mean, 4),
            "low": round(mean, 4),
            "mean": round(mean, 4),
            "n": 1,
            "singleObservation": True,
        }
    seed = int.from_bytes(hashlib.sha256(seed_material.encode("utf-8")).digest()[:8], "big")
    generator = random.Random(seed)
    sampled: list[float] = []
    for _ in range(resamples):
        indices = [generator.randrange(len(values)) for _ in values]
        sampled.append(weighted_mean(indices))
    sampled.sort()
    tail = (1 - confidence) / 2
    low_index = max(0, min(len(sampled) - 1, math.floor(tail * len(sampled))))
    high_index = max(0, min(len(sampled) - 1, math.ceil((1 - tail) * len(sampled)) - 1))
    return {
        "confidence": confidence,
        "high": round(sampled[high_index], 4),
        "low": round(sampled[low_index], 4),
        "mean": round(mean, 4),
        "n": len(values),
        "resamples": resamples,
    }


def aggregate(payload: Mapping[str, Any]) -> dict[str, Any]:
    runs = [item for item in payload.get("runs", []) if isinstance(item, dict)]
    completed = [item for item in runs if isinstance(item.get("score"), (int, float))]
    scores = [float(item["score"]) for item in completed]
    score_weights = [float(item.get("weight", 1.0)) for item in completed]
    commands = [float(item["commandCount"]) for item in completed if isinstance(item.get("commandCount"), (int, float))]
    durations = [float(item["durationSeconds"]) for item in completed if isinstance(item.get("durationSeconds"), (int, float))]
    costs = [float(item.get("usage", {}).get("cost", 0)) for item in completed if isinstance(item.get("usage"), dict)]
    usage_totals = {
        key: sum(
            int(item.get("usage", {}).get(key, 0))
            for item in completed
            if isinstance(item.get("usage"), dict)
        )
        for key in ("cacheRead", "cacheWrite", "input", "output")
    }
    usage_totals["cost"] = round(sum(costs), 8)
    seed = str(payload.get("metadata", {}).get("suiteSha256", "collaboration"))
    by_scenario: dict[str, Any] = {}
    grouped: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for item in completed:
        grouped[str(item.get("scenario", "unknown"))].append(item)
    for scenario, items in sorted(grouped.items()):
        scenario_scores = [float(item["score"]) for item in items]
        by_scenario[scenario] = {
            "policyComplianceRate": round(sum(bool(item.get("policyCompliant")) for item in items) / len(items), 4),
            "safetyPassRate": round(sum(bool(item.get("safetyPassed")) for item in items) / len(items), 4),
            "score": mean_confidence_interval(scenario_scores, seed_material=f"{seed}:{scenario}:score"),
        }
    skipped = [item for item in runs if item.get("status") == "skipped"]
    return {
        "byScenario": by_scenario,
        "commandCount": mean_confidence_interval(commands, seed_material=f"{seed}:commands"),
        "completedRuns": len(completed),
        "cost": {"mean": round(statistics.fmean(costs), 6) if costs else None, "total": round(sum(costs), 6)},
        "durationSeconds": mean_confidence_interval(durations, seed_material=f"{seed}:duration"),
        "policyComplianceRate": round(sum(bool(item.get("policyCompliant")) for item in completed) / len(completed), 4) if completed else None,
        "safetyPassRate": round(sum(bool(item.get("safetyPassed")) for item in completed) / len(completed), 4) if completed else None,
        "score": mean_confidence_interval(scores, weights=score_weights, seed_material=f"{seed}:score"),
        "skippedRuns": len(skipped),
        "totalRuns": len(runs),
        "usage": usage_totals,
    }


def _format_ci(value: Mapping[str, Any]) -> str:
    mean = value.get("mean")
    low = value.get("low")
    high = value.get("high")
    if mean is None:
        return "—"
    return f"{mean:.2f} ({low:.2f}–{high:.2f})"


def render(payload: Mapping[str, Any]) -> str:
    summary = payload.get("aggregate") if isinstance(payload.get("aggregate"), dict) else aggregate(payload)
    metadata = payload.get("metadata", {})
    usage = summary.get("usage", {}) if isinstance(summary.get("usage"), dict) else {}
    lines = [
        "# Margin collaboration evaluation",
        "",
        f"Experiment: `{metadata.get('experiment', 'unnamed')}`  ",
        f"Paid model execution: `{'yes' if metadata.get('paidModelsInvoked') else 'no'}`  ",
        f"Completed / skipped: `{summary.get('completedRuns', 0)}` / `{summary.get('skippedRuns', 0)}`  ",
        f"Mean score (95% bootstrap CI): `{_format_ci(summary.get('score', {}))}`  ",
        f"Safety pass rate: `{summary.get('safetyPassRate')}`  ",
        f"Policy compliance rate: `{summary.get('policyComplianceRate')}`  ",
        f"Generated/output-token cap per Prime subprocess: `{metadata.get('generatedOutputTokenBudgetPerInvocation', metadata.get('tokenBudgetPerInvocation', '—'))}`  ",
        f"Planned generated/output-token ceiling: `{metadata.get('plannedGeneratedOutputTokenCeiling', metadata.get('plannedAutonomousTokenCeiling', '—'))}`  ",
        f"Actual input / generated output tokens: `{usage.get('input', 0)}` / `{usage.get('output', 0)}`  ",
        f"Actual cache read / write tokens: `{usage.get('cacheRead', 0)}` / `{usage.get('cacheWrite', 0)}`  ",
        f"Actual cost: `${float(usage.get('cost', 0)):.8f}`",
        "",
        "| Scenario | Score, 95% CI | Safety | Policy |",
        "|---|---:|---:|---:|",
    ]
    for scenario, value in summary.get("byScenario", {}).items():
        lines.append(
            f"| `{scenario}` | {_format_ci(value.get('score', {}))} | "
            f"{value.get('safetyPassRate', 0):.1%} | {value.get('policyComplianceRate', 0):.1%} |"
        )
    lines.extend([
        "",
        "Raw prompts, Markdown, comments, paths, environment values, and model transcripts are not retained.",
        "",
    ])
    return "\n".join(lines)
