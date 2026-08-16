#!/usr/bin/env python3
"""Autonomous completion gate that records each attempt for first-pass analysis."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.dont_write_bytecode = True
from eval_lib import EvalError, append_jsonl, find_margin_binary, load_suite, utc_now  # noqa: E402
from score import score_case  # noqa: E402


def gate_eligible(check: dict[str, object]) -> bool:
    explicit = check.get("gate")
    if isinstance(explicit, bool):
        return explicit
    kind = check.get("type")
    if kind in {"command_budget", "error_budget", "trace_policy", "source_preserved", "protocol_valid"}:
        return False
    if kind == "command":
        expect = check.get("expect")
        if isinstance(expect, dict) and (expect.get("first") is True or expect.get("atMost") == 0):
            return False
    return kind in {"command", "command_sequence", "comment", "counts"}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--case-dir", required=True, type=Path)
    parser.add_argument("--scenario", required=True)
    parser.add_argument("--margin-bin", required=True, type=Path)
    arguments = parser.parse_args()
    try:
        scenario = load_suite([arguments.scenario])[0]
        binary = find_margin_binary(arguments.margin_bin)
        if binary is None:
            raise EvalError("Margin CLI binary not found.")
        case_dir = arguments.case_dir.resolve()
        result = score_case(case_dir, scenario, binary)
        gate_failed = [
            item["id"] for item in result["checks"]
            if not item["passed"] and gate_eligible(next(check for check in scenario.checks if check["id"] == item["id"]))
        ]
        history_path = case_dir / "gate-history.jsonl"
        existing = 0
        if history_path.exists():
            existing = sum(1 for line in history_path.read_text(encoding="utf-8").splitlines() if line.strip())
        append_jsonl(history_path, {
            "attempt": existing + 1,
            "commandCount": result["commandCount"],
            "dimensions": result["dimensions"],
            "failedCheckIDs": result["failedCheckIDs"],
            "gateFailedCheckIDs": gate_failed,
            "gatePassed": not gate_failed,
            "rawScore": result["rawScore"],
            "schema": "urn:margin:cli-eval-gate:v1",
            "score": result["score"],
            "timestamp": utc_now(),
        })
        if not gate_failed:
            print(json.dumps({
                "ok": True,
                "score": result["score"],
                "note": "Repairable task state is complete; observational penalties remain in the final score.",
            }, sort_keys=True))
            return 0
        failures = [
            {"detail": check["detail"], "id": check["id"]}
            for check in result["checks"] if check["id"] in gate_failed
        ]
        print(json.dumps({
            "failed": failures,
            "instruction": "Use Margin commands to repair the remaining requirements, then finish again.",
            "ok": False,
            "score": result["score"],
        }, sort_keys=True))
        return 1
    except EvalError as error:
        print(json.dumps({"error": str(error), "ok": False}), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
