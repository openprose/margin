#!/usr/bin/env python3
"""Aggregate sanitized run metadata and scores into a benchmark leaderboard."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


def load_runs(runs_dir: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for score_path in sorted(runs_dir.glob("*/score.json")):
        run_path = score_path.with_name("run.json")
        if not run_path.exists():
            continue
        try:
            score = json.loads(score_path.read_text(encoding="utf-8"))
            run = json.loads(run_path.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            continue
        rows.append({
            "budget": run.get("budget"),
            "cost": run.get("usage", {}).get("cost"),
            "durationSeconds": run.get("durationSeconds"),
            "inputTokens": run.get("usage", {}).get("input"),
            "model": run.get("model"),
            "outputTokens": run.get("usage", {}).get("output"),
            "primeAgentExitCode": run.get("primeAgentExitCode"),
            "run": score_path.parent.name,
            "score": score.get("score"),
            "sourcePreserved": score.get("sourcePreserved"),
            "timedOut": run.get("timedOut"),
        })
    return rows


def summarize(rows: list[dict[str, Any]]) -> dict[str, Any]:
    scored = [row for row in rows if isinstance(row.get("score"), (int, float))]
    measured_costs = [row["cost"] for row in rows if isinstance(row.get("cost"), (int, float))]
    timed_out = [row for row in rows if row.get("timedOut")]
    fastest = min(scored, key=lambda row: row.get("durationSeconds") or float("inf"), default=None)
    least_expensive = min(
        (row for row in scored if isinstance(row.get("cost"), (int, float))),
        key=lambda row: row["cost"],
        default=None,
    )
    return {
        "allSourcePreserved": bool(rows) and all(bool(row.get("sourcePreserved")) for row in rows),
        "fastestModel": fastest.get("model") if fastest else None,
        "leastExpensiveModel": least_expensive.get("model") if least_expensive else None,
        "perfectRuns": sum(row.get("score") == 100 for row in scored),
        "runCount": len(rows),
        "timedOutRuns": len(timed_out),
        "totalMeasuredCost": sum(measured_costs) if measured_costs else None,
    }


def markdown(rows: list[dict[str, Any]]) -> str:
    summary = summarize(rows)
    lines = [
        "# Margin real-agent benchmark",
        "",
    ]
    if rows:
        total_cost = summary["totalMeasuredCost"]
        total_cost_text = f"${total_cost:.4f}" if isinstance(total_cost, (int, float)) else "not reported"
        lines.extend([
            f"{summary['perfectRuns']} of {summary['runCount']} models scored 100/100; "
            f"all source-preservation checks passed: {str(summary['allSourcePreserved']).lower()}.",
            "",
            f"Fastest: `{summary['fastestModel']}`. Lowest measured cost: "
            f"`{summary['leastExpensiveModel']}`. Total measured cost: {total_cost_text}.",
            "",
            "The harness retained command shapes, scores, hashes, timing, and usage only. "
            "It did not persist model output, stderr, sessions, credentials, or environment values.",
            "",
        ])
    lines.extend([
        "| Model | Score | Seconds | Input tokens | Output tokens | Cost | Source preserved |",
        "|---|---:|---:|---:|---:|---:|:---:|",
    ])
    for row in sorted(
        rows,
        key=lambda item: (-(item.get("score") or 0), item.get("durationSeconds") or float("inf")),
    ):
        cost = row.get("cost")
        cost_text = f"${cost:.4f}" if isinstance(cost, (int, float)) else "n/a"
        lines.append(
            f"| {row.get('model')} | {row.get('score')}/100 | {row.get('durationSeconds')} | "
            f"{row.get('inputTokens')} | {row.get('outputTokens')} | {cost_text} | "
            f"{str(bool(row.get('sourcePreserved'))).lower()} |"
        )
    if not rows:
        lines.extend(["", "No paid model runs have been recorded."])
    lines.append("")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runs-dir", type=Path, default=Path(__file__).resolve().parent / "runs")
    parser.add_argument("--json-out", type=Path)
    parser.add_argument("--markdown-out", type=Path)
    arguments = parser.parse_args()
    rows = load_runs(arguments.runs_dir)
    payload = {
        "runs": rows,
        "schema": "urn:margin:agent-benchmark-report:v1",
        "summary": summarize(rows),
    }
    rendered = markdown(rows)
    if arguments.json_out:
        arguments.json_out.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    if arguments.markdown_out:
        arguments.markdown_out.write_text(rendered, encoding="utf-8")
    print(rendered)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
