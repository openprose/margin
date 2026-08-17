#!/usr/bin/env python3
"""Run collaboration capability preflight and every model-free protocol oracle."""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

sys.dont_write_bytecode = True
from eval_lib import (  # noqa: E402
    EvalError,
    find_margin_binary,
    holdout_commitment,
    load_suite,
    probe_capabilities,
    read_holdout_key,
    suite_fingerprint,
    utc_now,
    weighted_score,
    write_json_atomic,
)
from protocol import run_protocol_suite  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--margin-bin", type=Path)
    parser.add_argument("--scenario", action="append", default=[])
    parser.add_argument("--holdout-key-file", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument(
        "--require-all-capabilities",
        action="store_true",
        help="Treat capability-gated skips as failures (normally they are reported and allowed).",
    )
    arguments = parser.parse_args()
    try:
        binary = find_margin_binary(arguments.margin_bin)
        if binary is None:
            raise EvalError("Margin CLI binary not found. Build it or pass --margin-bin.")
        scenarios = load_suite(arguments.scenario)
        key = read_holdout_key(arguments.holdout_key_file) if arguments.holdout_key_file else os.urandom(32)
        preflight = probe_capabilities(binary)
        results = run_protocol_suite(scenarios, binary, preflight, key)
        failures = [item["scenario"] for item in results if item["status"] in {"failed", "error"}]
        skipped = [item["scenario"] for item in results if item["status"] == "skipped"]
        help_contract = preflight["helpContract"]
        performance = {
            "helpColdMs": help_contract.get("coldMs"),
            "helpWarmP95BudgetMs": help_contract.get("warmP95BudgetMs"),
            "helpWarmP95Ms": help_contract.get("warmP95Ms"),
            "helpWarmP95WithinBudget": help_contract.get("warmP95WithinBudget") is True,
            "helpStableAcrossEmptyRoots": help_contract.get("deterministicAcrossDirectories") is True,
            "launchPathCollaborationScan": "not_measured_by_cli_harness",
        }
        passed = (
            not failures
            and preflight.get("staticContractPassed") is True
            and (not arguments.require_all_capabilities or not skipped)
        )
        payload = {
            "createdAt": utc_now(),
            "holdoutCommitment": holdout_commitment(key),
            "paidModelsInvoked": False,
            "passed": passed,
            "performanceContract": performance,
            "preflight": preflight,
            "results": results,
            "runnable": len(results) - len(skipped),
            "schema": "urn:margin:collaboration-eval-self-test:v1",
            "skipped": len(skipped),
            "suiteSha256": suite_fingerprint(),
            "weightedRunnableScore": weighted_score(results),
        }
        if arguments.output:
            write_json_atomic(arguments.output, payload)
        print(json.dumps(payload, indent=2, sort_keys=True))
        return 0 if passed else 1
    except (EvalError, OSError, ValueError) as error:
        print(json.dumps({
            "errorSha256": __import__("hashlib").sha256(str(error).encode("utf-8")).hexdigest(),
            "errorType": type(error).__name__,
            "paidModelsInvoked": False,
            "passed": False,
        }, sort_keys=True), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
