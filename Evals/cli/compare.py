#!/usr/bin/env python3
"""Compare two eval sets and fail on meaningful usability regressions."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

from report import aggregate


def run_key(run: dict[str, Any]) -> tuple[str, str, int]:
    return (str(run.get("model")), str(run.get("scenario")), int(run.get("repetition", 1)))


def compare(
    baseline: dict[str, Any],
    candidate: dict[str, Any],
    max_score_regression: float,
    max_first_pass_regression: float,
    max_command_increase: float,
) -> dict[str, Any]:
    before = {run_key(run): run for run in baseline.get("runs", []) if isinstance(run, dict)}
    after = {run_key(run): run for run in candidate.get("runs", []) if isinstance(run, dict)}
    shared = sorted(set(before) & set(after))
    missing = [list(key) for key in sorted(set(before) - set(after))]
    added = [list(key) for key in sorted(set(after) - set(before))]
    regressions: list[dict[str, Any]] = []
    deltas: list[dict[str, Any]] = []
    baseline_metadata = baseline.get("metadata", {})
    candidate_metadata = candidate.get("metadata", {})
    if baseline_metadata.get("scenarioHashes") != candidate_metadata.get("scenarioHashes"):
        regressions.append({"reason": "scenario_fingerprint_mismatch"})
    if baseline_metadata.get("harnessSha256") != candidate_metadata.get("harnessSha256"):
        regressions.append({"reason": "harness_fingerprint_mismatch"})
    for key in shared:
        old = before[key]
        new = after[key]
        first_delta = float(new.get("firstPassScore", 0)) - float(old.get("firstPassScore", 0))
        final_delta = float(new.get("finalScore", 0)) - float(old.get("finalScore", 0))
        command_delta = float(new.get("commandCount", 0)) - float(old.get("commandCount", 0))
        item = {
            "commandDelta": command_delta,
            "finalScoreDelta": final_delta,
            "firstPassScoreDelta": first_delta,
            "model": key[0],
            "repetition": key[2],
            "scenario": key[1],
        }
        deltas.append(item)
        if final_delta < -max_score_regression:
            regressions.append({**item, "reason": "final_score"})
        if first_delta < -max_first_pass_regression:
            regressions.append({**item, "reason": "first_pass_score"})
        if command_delta > max_command_increase and float(new.get("finalScore", 0)) <= float(old.get("finalScore", 0)):
            regressions.append({**item, "reason": "command_efficiency"})
        for field in ("sourcePreserved", "protocolValid", "policyCompliant", "telemetryIntegrity"):
            if old.get(field, True) and not new.get(field, True):
                regressions.append({**item, "reason": field})
    if missing:
        regressions.append({"reason": "missing_runs", "runs": missing})
    old_summary = baseline.get("aggregate") or aggregate(baseline)
    new_summary = candidate.get("aggregate") or aggregate(candidate)
    return {
        "addedRuns": added,
        "baselineOverall": old_summary["overall"],
        "candidateOverall": new_summary["overall"],
        "deltas": deltas,
        "matchedRuns": len(shared),
        "passed": not regressions,
        "regressions": regressions,
        "schema": "urn:margin:cli-eval-comparison:v1",
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("baseline", type=Path)
    parser.add_argument("candidate", type=Path)
    parser.add_argument("--max-score-regression", type=float, default=0.0)
    parser.add_argument("--max-first-pass-regression", type=float, default=0.0)
    parser.add_argument("--max-command-increase", type=float, default=2.0)
    parser.add_argument("--output", type=Path)
    arguments = parser.parse_args()
    baseline = json.loads(arguments.baseline.read_text(encoding="utf-8"))
    candidate = json.loads(arguments.candidate.read_text(encoding="utf-8"))
    result = compare(
        baseline,
        candidate,
        arguments.max_score_regression,
        arguments.max_first_pass_regression,
        arguments.max_command_increase,
    )
    encoded = json.dumps(result, indent=2, sort_keys=True) + "\n"
    if arguments.output:
        arguments.output.write_text(encoded, encoding="utf-8")
    else:
        sys.stdout.write(encoded)
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
