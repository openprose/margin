#!/usr/bin/env python3
"""Run every CLI eval oracle without invoking a language model."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

sys.dont_write_bytecode = True
from eval_lib import (  # noqa: E402
    EVAL_DIR,
    EvalError,
    actor_environment,
    find_margin_binary,
    load_json,
    load_suite,
    prepare_case,
    sha256_file,
    substitute_document,
)
from score import score_case  # noqa: E402


def runtime_arguments(values: list[Any], document: Path, content_sha: str) -> list[str]:
    substituted = substitute_document(values, document)
    return [content_sha if value == "$CONTENT_SHA" else value for value in substituted]


def execute_oracle(case_dir: Path, scenario: Any, binary: Path) -> list[dict[str, Any]]:
    document = case_dir / "workspace" / "review.md"
    command_log = case_dir / "command-log.jsonl"
    oracle = load_json(scenario.oracle)
    steps = oracle.get("steps", []) if isinstance(oracle, dict) else []
    environment = actor_environment({
        "id": "urn:margin:eval:oracle",
        "name": "Eval Oracle",
        "type": "software",
    })
    environment.update({
        "MARGIN_EVAL_COMMAND_LOG": str(command_log),
        "MARGIN_EVAL_DOCUMENT_REALPATH": str(document.resolve()),
        "MARGIN_EVAL_HEADLESS": "1",
        "MARGIN_EVAL_REAL_BIN": str(binary),
    })
    content_sha = "sha256:" + sha256_file(scenario.fixture)
    records: list[dict[str, Any]] = []
    for index, step in enumerate(steps):
        if not isinstance(step, dict) or not isinstance(step.get("argv"), list):
            raise EvalError(f"Oracle step {index} for {scenario.id} is malformed.")
        argv = runtime_arguments(step["argv"], document, content_sha)
        completed = subprocess.run(
            [sys.executable, str(EVAL_DIR / "proxy.py"), *argv],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=environment,
            check=False,
            timeout=30,
        )
        expected = int(step.get("expectedExit", 0))
        record = {
            "actualExit": completed.returncode,
            "argv": argv,
            "expectedExit": expected,
            "index": index,
        }
        records.append(record)
        if completed.returncode != expected:
            detail = completed.stderr.decode("utf-8", errors="replace")[:1000]
            raise EvalError(
                f"{scenario.id} oracle step {index} returned {completed.returncode}, "
                f"expected {expected}: {detail}"
            )
    (case_dir / "trace.json").write_text(json.dumps({
        "directDocumentReadHashes": [],
        "directDocumentReads": 0,
        "directDocumentWriteHashes": [],
        "directDocumentWrites": 0,
        "harnessAccessHashes": [],
        "harnessAccesses": 0,
        "policyCompliant": True,
        "schema": "urn:margin:cli-eval-trace:v1",
        "sensitiveAccessHashes": [],
        "sensitiveAccesses": 0,
        "toolCalls": 0,
    }, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return records


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--margin-bin", type=Path)
    parser.add_argument("--scenario", action="append", default=[])
    parser.add_argument("--keep", type=Path, help="Keep cases under this directory instead of using temporary storage.")
    arguments = parser.parse_args()
    try:
        binary = find_margin_binary(arguments.margin_bin)
        if binary is None:
            raise EvalError("Margin CLI binary not found. Build it or pass --margin-bin.")
        scenarios = load_suite(arguments.scenario)
        results: list[dict[str, Any]] = []
        owner: tempfile.TemporaryDirectory[str] | None = None
        if arguments.keep:
            root = arguments.keep.resolve()
            root.mkdir(parents=True, exist_ok=True)
        else:
            owner = tempfile.TemporaryDirectory(prefix="margin-cli-eval-self-test-")
            root = Path(owner.name)
        for scenario in scenarios:
            case_dir = root / scenario.id
            case_dir.mkdir(parents=True, exist_ok=False)
            prepare_case(scenario, case_dir, binary)
            steps = execute_oracle(case_dir, scenario, binary)
            result = score_case(case_dir, scenario, binary)
            (case_dir / "score.json").write_text(
                json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8"
            )
            results.append({
                "commandCount": result["commandCount"],
                "failedCheckIDs": result["failedCheckIDs"],
                "oracleSteps": len(steps),
                "scenario": scenario.id,
                "score": result["score"],
            })
        summary = {
            "marginBinary": str(binary),
            "passed": all(item["score"] == 100 for item in results),
            "results": results,
            "schema": "urn:margin:cli-eval-self-test:v1",
        }
        print(json.dumps(summary, indent=2, sort_keys=True))
        if owner is not None:
            owner.cleanup()
        return 0 if summary["passed"] else 1
    except (EvalError, OSError, subprocess.TimeoutExpired) as error:
        print(json.dumps({"error": str(error), "passed": False}, indent=2), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
