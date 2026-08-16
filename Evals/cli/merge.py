#!/usr/bin/env python3
"""Merge compatible Margin CLI eval sets into one comparison matrix."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

from eval_lib import sha256_file, utc_now
from report import aggregate, render


def merge(payloads: list[tuple[Path, dict[str, Any]]], experiment: str) -> dict[str, Any]:
    scenario_hashes: dict[str, str] = {}
    runs: list[dict[str, Any]] = []
    seen: set[tuple[str, str, int]] = set()
    revisions: set[str] = set()
    harness_hashes: set[str] = set()
    sources: list[dict[str, Any]] = []
    for path, payload in payloads:
        metadata = payload.get("metadata", {})
        for scenario, digest in metadata.get("scenarioHashes", {}).items():
            previous = scenario_hashes.get(scenario)
            if previous is not None and previous != digest:
                raise ValueError(f"Scenario {scenario} differs between input sets.")
            scenario_hashes[scenario] = digest
        revision = metadata.get("gitRevision")
        if isinstance(revision, str):
            revisions.add(revision)
        harness_hash = metadata.get("harnessSha256")
        if isinstance(harness_hash, str):
            harness_hashes.add(harness_hash)
        sources.append({"path": str(path), "sha256": sha256_file(path)})
        for run in payload.get("runs", []):
            if not isinstance(run, dict):
                continue
            key = (str(run.get("model")), str(run.get("scenario")), int(run.get("repetition", 1)))
            if key in seen:
                raise ValueError(f"Duplicate run cell {key}.")
            seen.add(key)
            copied = dict(run)
            copied["sourceEvalSet"] = str(path)
            runs.append(copied)
    result: dict[str, Any] = {
        "metadata": {
            "createdAt": utc_now(),
            "experiment": experiment,
            "gitRevision": next(iter(revisions)) if len(revisions) == 1 else None,
            "harnessSha256": next(iter(harness_hashes)) if len(harness_hashes) == 1 else None,
            "scenarioHashes": scenario_hashes,
            "sources": sources,
        },
        "runs": runs,
        "schema": "urn:margin:cli-eval-set:v1",
    }
    result["aggregate"] = aggregate(result)
    if len(harness_hashes) > 1:
        raise ValueError("Input sets use different harness fingerprints; rescore them first.")
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("inputs", nargs="+", type=Path)
    parser.add_argument("--experiment", required=True)
    parser.add_argument("--output", required=True, type=Path)
    arguments = parser.parse_args()
    try:
        payloads = [(path.resolve(), json.loads(path.read_text(encoding="utf-8"))) for path in arguments.inputs]
        result = merge(payloads, arguments.experiment)
        arguments.output.parent.mkdir(parents=True, exist_ok=True)
        arguments.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        arguments.output.with_suffix(".md").write_text(render(result), encoding="utf-8")
        print(json.dumps({"output": str(arguments.output), "runs": len(result["runs"])}, sort_keys=True))
        return 0
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(str(error), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
