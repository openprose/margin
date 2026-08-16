#!/usr/bin/env python3
"""Aggregate and render Margin CLI eval run sets."""

from __future__ import annotations

import argparse
import json
import statistics
import sys
from collections import defaultdict
from pathlib import Path
from typing import Any


def mean(values: list[float]) -> float:
    return statistics.fmean(values) if values else 0.0


def weighted_score(runs: list[dict[str, Any]], field: str) -> float:
    numerator = sum(float(run.get(field, 0)) * float(run.get("weight", 1.0)) for run in runs)
    denominator = sum(float(run.get("weight", 1.0)) for run in runs)
    return numerator / denominator if denominator else 0.0


def aggregate(payload: dict[str, Any]) -> dict[str, Any]:
    runs = [run for run in payload.get("runs", []) if isinstance(run, dict)]
    by_model: dict[str, list[dict[str, Any]]] = defaultdict(list)
    by_scenario: dict[str, list[dict[str, Any]]] = defaultdict(list)
    by_cell: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for run in runs:
        by_model[str(run.get("model", "unknown"))].append(run)
        by_scenario[str(run.get("scenario", "unknown"))].append(run)
        cell_key = f"{run.get('model', 'unknown')} :: {run.get('scenario', 'unknown')}"
        by_cell[cell_key].append(run)

    def summarize(group: list[dict[str, Any]]) -> dict[str, Any]:
        return {
            "commandMean": round(mean([float(run.get("commandCount", 0)) for run in group]), 3),
            "cost": round(sum(float(run.get("usage", {}).get("cost", 0.0)) for run in group), 6),
            "durationMeanSeconds": round(mean([float(run.get("durationSeconds", 0)) for run in group]), 3),
            "finalScore": round(weighted_score(group, "finalScore"), 3),
            "finalScoreMaximum": max([float(run.get("finalScore", 0)) for run in group], default=0.0),
            "finalScoreMinimum": min([float(run.get("finalScore", 0)) for run in group], default=0.0),
            "firstPassScore": round(weighted_score(group, "firstPassScore"), 3),
            "firstPassScoreMaximum": max([float(run.get("firstPassScore", 0)) for run in group], default=0.0),
            "firstPassScoreMinimum": min([float(run.get("firstPassScore", 0)) for run in group], default=0.0),
            "policyComplianceRate": round(mean([1.0 if run.get("policyCompliant", True) else 0.0 for run in group]), 4),
            "repairMean": round(mean([float(run.get("repairAttempts", 0)) for run in group]), 3),
            "runs": len(group),
            "successRate": round(mean([1.0 if run.get("finalScore") == 100 else 0.0 for run in group]), 4),
            "timedOut": sum(1 for run in group if run.get("timedOut")),
            "tokens": sum(int(run.get("usage", {}).get("input", 0)) + int(run.get("usage", {}).get("output", 0)) for run in group),
        }

    dimensions: dict[str, dict[str, float]] = defaultdict(
        lambda: {"finalEarned": 0.0, "finalPossible": 0.0, "firstEarned": 0.0, "firstPossible": 0.0}
    )
    for run in runs:
        weight = float(run.get("weight", 1.0))
        for field, earned_key, possible_key in (
            ("dimensions", "finalEarned", "finalPossible"),
            ("firstPassDimensions", "firstEarned", "firstPossible"),
        ):
            dimension_values = run.get(field, {})
            if field == "firstPassDimensions" and not run.get("policyCompliant", True):
                dimension_values = dict(dimension_values)
                final_safety = run.get("dimensions", {}).get("safety")
                if isinstance(final_safety, dict):
                    dimension_values["safety"] = final_safety
            for name, values in dimension_values.items():
                if not isinstance(values, dict):
                    continue
                dimensions[name][earned_key] += float(values.get("earned", 0)) * weight
                dimensions[name][possible_key] += float(values.get("possible", 0)) * weight
    dimension_summary: dict[str, dict[str, float]] = {}
    for name, values in sorted(dimensions.items()):
        dimension_summary[name] = {
            "finalPercent": round(100 * values["finalEarned"] / values["finalPossible"], 3)
            if values["finalPossible"] else 0.0,
            "firstPassPercent": round(100 * values["firstEarned"] / values["firstPossible"], 3)
            if values["firstPossible"] else 0.0,
        }

    return {
        "cells": {name: summarize(group) for name, group in sorted(by_cell.items())},
        "dimensions": dimension_summary,
        "models": {name: summarize(group) for name, group in sorted(by_model.items())},
        "overall": summarize(runs),
        "scenarios": {name: summarize(group) for name, group in sorted(by_scenario.items())},
    }


def render(payload: dict[str, Any]) -> str:
    summary = payload.get("aggregate") if isinstance(payload.get("aggregate"), dict) else aggregate(payload)
    metadata = payload.get("metadata", {})
    overall = summary["overall"]
    lines = [
        "# Margin CLI agent eval",
        "",
        f"- Experiment: **{metadata.get('experiment', 'unnamed')}**",
        f"- Git revision: `{metadata.get('gitRevision') or 'unknown'}`",
        f"- Runs: **{overall['runs']}**",
        "",
        "## Model results",
        "",
        "| Model | First pass | Final | Success | Repairs | Commands | Seconds | Tokens | Cost | CLI-only |",
        "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for model, item in summary["models"].items():
        lines.append(
            f"| {model} | {item['firstPassScore']:.1f} | {item['finalScore']:.1f} | "
            f"{item['successRate'] * 100:.0f}% | {item['repairMean']:.2f} | {item['commandMean']:.1f} | "
            f"{item['durationMeanSeconds']:.1f} | {item['tokens']} | ${item['cost']:.4f} | "
            f"{item['policyComplianceRate'] * 100:.0f}% |"
        )
    lines.extend([
        "",
        "## Model and scenario cells",
        "",
        "| Model | Scenario | N | First pass | Final | Repairs | Commands | CLI-only |",
        "|---|---|---:|---:|---:|---:|---:|---:|",
    ])
    for cell, item in summary["cells"].items():
        model, scenario = cell.split(" :: ", 1)
        first_range = f"{item['firstPassScore']:.1f} ({item['firstPassScoreMinimum']:.0f}–{item['firstPassScoreMaximum']:.0f})"
        final_range = f"{item['finalScore']:.1f} ({item['finalScoreMinimum']:.0f}–{item['finalScoreMaximum']:.0f})"
        lines.append(
            f"| {model} | {scenario} | {item['runs']} | {first_range} | {final_range} | "
            f"{item['repairMean']:.2f} | {item['commandMean']:.1f} | {item['policyComplianceRate'] * 100:.0f}% |"
        )
    lines.extend([
        "",
        "## Scenario results",
        "",
        "| Scenario | First pass | Final | Success | Repairs | Commands |",
        "|---|---:|---:|---:|---:|---:|",
    ])
    for scenario, item in summary["scenarios"].items():
        lines.append(
            f"| {scenario} | {item['firstPassScore']:.1f} | {item['finalScore']:.1f} | "
            f"{item['successRate'] * 100:.0f}% | {item['repairMean']:.2f} | {item['commandMean']:.1f} |"
        )
    lines.extend([
        "",
        "## Dimension results",
        "",
        "| Dimension | First pass | Final |",
        "|---|---:|---:|",
    ])
    for dimension, item in summary["dimensions"].items():
        lines.append(f"| {dimension} | {item['firstPassPercent']:.1f}% | {item['finalPercent']:.1f}% |")
    lines.extend([
        "",
        "First-pass score is captured before the completion gate supplies diagnostics. Final score includes repairs and safety caps.",
        "Raw model output and comment message arguments are not retained.",
        "",
    ])
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path)
    parser.add_argument("--output", type=Path)
    arguments = parser.parse_args()
    payload = json.loads(arguments.input.read_text(encoding="utf-8"))
    markdown = render(payload)
    if arguments.output:
        arguments.output.write_text(markdown, encoding="utf-8")
    else:
        sys.stdout.write(markdown)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
