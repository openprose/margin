#!/usr/bin/env python3
"""Paired baseline/candidate collaboration comparison with bootstrap intervals."""

from __future__ import annotations

import argparse
import json
import sys
from collections import defaultdict
from pathlib import Path
from typing import Any, Mapping

sys.dont_write_bytecode = True
from eval_lib import EvalError, load_json, sha256_bytes, write_json_atomic  # noqa: E402
from report import mean_confidence_interval  # noqa: E402


def _key(run: Mapping[str, Any]) -> tuple[str, str, int]:
    return (
        str(run.get("configuration", "")),
        str(run.get("scenario", "")),
        int(run.get("repetition", -1)),
    )


def _runs(payload: Mapping[str, Any]) -> dict[tuple[str, str, int], dict[str, Any]]:
    result: dict[tuple[str, str, int], dict[str, Any]] = {}
    for item in payload.get("runs", []):
        if not isinstance(item, dict):
            continue
        key = _key(item)
        if key in result:
            raise EvalError(f"Duplicate run cell {key}.")
        result[key] = item
    return result


def _numeric(run: Mapping[str, Any], field: str, default: float = 0) -> float:
    value = run.get(field, default)
    return float(value) if isinstance(value, (int, float)) else default


def _usage(run: Mapping[str, Any], field: str) -> float:
    usage = run.get("usage", {})
    value = usage.get(field, 0) if isinstance(usage, dict) else 0
    return float(value) if isinstance(value, (int, float)) else 0


def _interval(values: list[float], label: str, weights: list[float] | None = None) -> dict[str, Any]:
    return mean_confidence_interval(values, weights=weights, seed_material=label)


def compare(
    baseline: Mapping[str, Any],
    candidate: Mapping[str, Any],
    *,
    max_score_regression: float = 2.0,
    max_pair_score_regression: float = 15.0,
    max_command_increase: float = 2.0,
) -> dict[str, Any]:
    baseline_metadata = baseline.get("metadata", {})
    candidate_metadata = candidate.get("metadata", {})
    if baseline_metadata.get("suiteSha256") != candidate_metadata.get("suiteSha256"):
        raise EvalError("Baseline and candidate use different suite fingerprints.")
    if baseline_metadata.get("holdoutCommitment") != candidate_metadata.get("holdoutCommitment"):
        raise EvalError("Baseline and candidate were not generated from the same hidden holdout key.")
    if baseline_metadata.get("toolIsolation") != candidate_metadata.get("toolIsolation"):
        raise EvalError("Baseline and candidate use different agent tool-isolation boundaries.")
    before = _runs(baseline)
    after = _runs(candidate)
    shared = sorted(set(before) & set(after))
    missing = sorted(set(before) - set(after))
    added = sorted(set(after) - set(before))
    regressions: list[dict[str, Any]] = []
    warnings: list[dict[str, Any]] = []
    pairs: list[dict[str, Any]] = []
    by_scenario: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for key in shared:
        old = before[key]
        new = after[key]
        old_skipped = old.get("status") == "skipped"
        new_skipped = new.get("status") == "skipped"
        if old_skipped and new_skipped:
            if old.get("missingCapabilities") != new.get("missingCapabilities"):
                warnings.append({"cell": list(key), "reason": "skip_capabilities_changed"})
            continue
        if not old_skipped and new_skipped:
            regressions.append({"cell": list(key), "reason": "candidate_became_unsupported"})
            continue
        if old_skipped and not new_skipped:
            warnings.append({"cell": list(key), "reason": "candidate_added_capability"})
            continue
        if old.get("caseFingerprint") != new.get("caseFingerprint"):
            regressions.append({"cell": list(key), "reason": "holdout_case_mismatch"})
            continue
        pair = {
            "cell": list(key),
            "commandDelta": _numeric(new, "commandCount") - _numeric(old, "commandCount"),
            "costDelta": _usage(new, "cost") - _usage(old, "cost"),
            "durationDelta": _numeric(new, "durationSeconds") - _numeric(old, "durationSeconds"),
            "scoreDelta": _numeric(new, "score") - _numeric(old, "score"),
            "tokenDelta": (_usage(new, "input") + _usage(new, "output")) - (_usage(old, "input") + _usage(old, "output")),
            "weight": _numeric(new, "weight", 1.0),
        }
        pairs.append(pair)
        by_scenario[key[1]].append(pair)
        if old.get("safetyPassed", True) and not new.get("safetyPassed", True):
            regressions.append({"cell": list(key), "reason": "new_safety_failure"})
        if old.get("policyCompliant", True) and not new.get("policyCompliant", True):
            regressions.append({"cell": list(key), "reason": "new_policy_failure"})
        if pair["scoreDelta"] < -max_pair_score_regression:
            regressions.append({"cell": list(key), "delta": pair["scoreDelta"], "reason": "large_pair_score_regression"})
    if missing:
        regressions.append({"cells": [list(item) for item in missing], "reason": "missing_candidate_cells"})

    seed = str(baseline_metadata.get("suiteSha256")) + str(baseline_metadata.get("holdoutCommitment"))
    pair_weights = [item["weight"] for item in pairs]
    overall = {
        "commands": _interval([item["commandDelta"] for item in pairs], seed + ":commands", pair_weights),
        "cost": _interval([item["costDelta"] for item in pairs], seed + ":cost", pair_weights),
        "duration": _interval([item["durationDelta"] for item in pairs], seed + ":duration", pair_weights),
        "score": _interval([item["scoreDelta"] for item in pairs], seed + ":score", pair_weights),
        "tokens": _interval([item["tokenDelta"] for item in pairs], seed + ":tokens", pair_weights),
    }
    scenario_intervals: dict[str, Any] = {}
    for scenario, items in sorted(by_scenario.items()):
        scenario_intervals[scenario] = {
            "commands": _interval([item["commandDelta"] for item in items], seed + scenario + ":commands"),
            "duration": _interval([item["durationDelta"] for item in items], seed + scenario + ":duration"),
            "score": _interval([item["scoreDelta"] for item in items], seed + scenario + ":score"),
            "tokens": _interval([item["tokenDelta"] for item in items], seed + scenario + ":tokens"),
        }
    score_ci = overall["score"]
    command_ci = overall["commands"]
    if score_ci.get("high") is not None and float(score_ci["high"]) < -max_score_regression:
        regressions.append({"interval": score_ci, "reason": "confident_mean_score_regression"})
    if (
        command_ci.get("low") is not None
        and float(command_ci["low"]) > max_command_increase
        and score_ci.get("low") is not None
        and float(score_ci["low"]) <= 0
    ):
        regressions.append({"interval": command_ci, "reason": "confident_command_growth_without_score_gain"})
    inconclusive = bool(pairs) and score_ci.get("low") is not None and score_ci.get("high") is not None and (
        float(score_ci["low"]) <= -max_score_regression <= float(score_ci["high"])
    )
    return {
        "addedCells": [list(item) for item in added],
        "decision": "regression" if regressions else ("inconclusive" if inconclusive else "pass"),
        "matchedPairs": len(pairs),
        "overallPairedDelta": overall,
        "passed": not regressions,
        "regressions": regressions,
        "scenarioPairedDelta": scenario_intervals,
        "schema": "urn:margin:collaboration-eval-comparison:v1",
        "thresholds": {
            "maxCommandIncrease": max_command_increase,
            "maxPairScoreRegression": max_pair_score_regression,
            "maxScoreRegression": max_score_regression,
        },
        "warnings": warnings,
    }


def render(result: Mapping[str, Any]) -> str:
    lines = [
        "# Paired collaboration evaluation",
        "",
        f"Decision: **{result.get('decision', 'unknown')}**  ",
        f"Matched pairs: `{result.get('matchedPairs', 0)}`",
        "",
        "| Metric | Mean paired delta | 95% CI |",
        "|---|---:|---:|",
    ]
    for name, interval in result.get("overallPairedDelta", {}).items():
        lines.append(f"| {name} | {interval.get('mean')} | {interval.get('low')} to {interval.get('high')} |")
    if result.get("regressions"):
        lines.extend(["", "## Regression reasons", ""])
        for item in result["regressions"]:
            lines.append(f"- `{item.get('reason')}`")
    lines.extend(["", "Positive score deltas favor the candidate; lower command, duration, token, and cost deltas are better.", ""])
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("baseline", type=Path)
    parser.add_argument("candidate", type=Path)
    parser.add_argument("--max-score-regression", type=float, default=2.0)
    parser.add_argument("--max-pair-score-regression", type=float, default=15.0)
    parser.add_argument("--max-command-increase", type=float, default=2.0)
    parser.add_argument("--output", type=Path)
    arguments = parser.parse_args()
    try:
        result = compare(
            load_json(arguments.baseline),
            load_json(arguments.candidate),
            max_score_regression=arguments.max_score_regression,
            max_pair_score_regression=arguments.max_pair_score_regression,
            max_command_increase=arguments.max_command_increase,
        )
        if arguments.output:
            write_json_atomic(arguments.output, result)
            arguments.output.with_suffix(".md").write_text(render(result), encoding="utf-8")
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0 if result["passed"] else 1
    except (EvalError, OSError, ValueError, json.JSONDecodeError) as error:
        print(json.dumps({
            "errorSha256": sha256_bytes(f"{type(error).__name__}:{error}".encode("utf-8")),
            "errorType": type(error).__name__,
        }, sort_keys=True), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
