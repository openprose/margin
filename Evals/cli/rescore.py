#!/usr/bin/env python3
"""Regrade retained eval workspaces after deterministic scorer improvements."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

from eval_lib import EvalError, find_margin_binary, git_revision, harness_fingerprint, load_command_log, load_json, load_suite, scenario_fingerprint, utc_now
from report import aggregate, render
from run import adjust_first_pass_for_trace, load_jsonl, repair_cycles, telemetry_integrity
from score import score_case


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--margin-bin", type=Path)
    arguments = parser.parse_args()
    try:
        binary = find_margin_binary(arguments.margin_bin)
        if binary is None:
            raise EvalError("Margin CLI binary not found.")
        input_path = arguments.input.resolve()
        payload = load_json(input_path)
        scenarios = {scenario.id: scenario for scenario in load_suite()}
        updated_runs: list[dict[str, Any]] = []
        for old in payload.get("runs", []):
            if not isinstance(old, dict):
                continue
            scenario_id = str(old.get("scenario"))
            scenario = scenarios.get(scenario_id)
            if scenario is None:
                raise EvalError(f"Unknown retained scenario {scenario_id!r}.")
            run_dir = (input_path.parent / str(old.get("runDir"))).resolve()
            if not (run_dir / "workspace" / "review.md").is_file():
                raise EvalError(f"Retained workspace is missing: {run_dir}")
            history = load_jsonl(run_dir / "gate-history.jsonl")
            commands = load_command_log(run_dir / "command-log.jsonl")
            integrity = telemetry_integrity(history, commands)
            (run_dir / "integrity.json").write_text(json.dumps(integrity, indent=2, sort_keys=True) + "\n", encoding="utf-8")
            score = score_case(run_dir, scenario, binary)
            trace = load_json(run_dir / "trace.json") if (run_dir / "trace.json").is_file() else {}
            first = int(history[0].get("score", score["score"])) if history else int(score["score"])
            first_failed = list(history[0].get("failedCheckIDs", score["failedCheckIDs"])) if history else list(score["failedCheckIDs"])
            first, first_failed = adjust_first_pass_for_trace(first, first_failed, score["checks"], trace, scenario)
            if not integrity["ok"]:
                first = min(first, 30)
                if "telemetry_integrity" not in first_failed:
                    first_failed.append("telemetry_integrity")
            first_dimensions = history[0].get("dimensions", {}) if history else score["dimensions"]
            if history and isinstance(history[0].get("timestamp"), str):
                gate_time = str(history[0]["timestamp"])
                has_later_command = any(
                    isinstance(command.get("timestamp"), str) and str(command["timestamp"]) > gate_time
                    for command in commands
                )
                if not has_later_command:
                    first = int(score["score"])
                    first_failed = list(score["failedCheckIDs"])
                    first_dimensions = score["dimensions"]
            by_id = {item["id"]: item for item in score["checks"]}
            retained_metadata = (
                load_json(run_dir / "run.json") if (run_dir / "run.json").is_file() else {}
            )
            current = dict(old)
            current.update({
                "budget": retained_metadata.get("budget", old.get("budget")),
                "commandCount": score["commandCount"],
                "dimensions": score["dimensions"],
                "failedCheckIDs": score["failedCheckIDs"],
                "finalScore": score["score"],
                "firstPassDimensions": first_dimensions,
                "firstPassFailedCheckIDs": first_failed,
                "firstPassScore": first,
                "gateAttempts": len(history),
                "policyCompliant": bool(trace.get("policyCompliant", True)),
                "protocolValid": bool(by_id.get("protocol_validation", {}).get("passed", True)),
                "repairAttempts": repair_cycles(history, commands),
                "sourcePreserved": bool(score["sourcePreserved"]),
                "telemetryIntegrity": bool(integrity["ok"]),
                "thinking": retained_metadata.get("thinking", old.get("thinking")),
                "weight": scenario.weight,
            })
            updated_runs.append(current)
        metadata = dict(payload.get("metadata", {}))
        metadata.update({
            "rescoredAt": utc_now(),
            "scorerGitRevision": git_revision(),
            "harnessSha256": harness_fingerprint(),
            "scenarioHashes": {scenario_id: scenario_fingerprint(scenarios[scenario_id]) for scenario_id in sorted({run["scenario"] for run in updated_runs})},
        })
        result: dict[str, Any] = {
            "metadata": metadata,
            "runs": updated_runs,
            "schema": "urn:margin:cli-eval-set:v1",
        }
        result["aggregate"] = aggregate(result)
        arguments.output.parent.mkdir(parents=True, exist_ok=True)
        arguments.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        arguments.output.with_suffix(".md").write_text(render(result), encoding="utf-8")
        print(json.dumps({"output": str(arguments.output), "runs": len(updated_runs)}, sort_keys=True))
        return 0
    except (EvalError, OSError, TypeError, ValueError) as error:
        print(str(error), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
