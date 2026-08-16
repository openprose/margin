#!/usr/bin/env python3
"""Create a portable, privacy-minimized baseline from a merged eval set."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

from eval_lib import sha256_file, utc_now
from report import aggregate, render


RUN_FIELDS = {
    "budget", "commandCount", "dimensions", "durationSeconds", "failedCheckIDs", "finalScore",
    "firstPassDimensions", "firstPassFailedCheckIDs", "firstPassScore", "gateAttempts",
    "model", "policyCompliant", "primeAgentExitCode", "protocolValid", "repairAttempts",
    "repetition", "scenario", "sourcePreserved", "telemetryIntegrity", "thinking", "timedOut", "usage", "weight",
}


def minimize(payload: dict[str, Any], source: Path) -> dict[str, Any]:
    original_metadata = payload.get("metadata", {})
    runs: list[dict[str, Any]] = []
    for run in payload.get("runs", []):
        if not isinstance(run, dict):
            continue
        minimized = {key: value for key, value in run.items() if key in RUN_FIELDS}
        if not minimized.get("policyCompliant", True):
            first_dimensions = dict(minimized.get("firstPassDimensions", {}))
            final_safety = minimized.get("dimensions", {}).get("safety")
            if isinstance(final_safety, dict):
                first_dimensions["safety"] = final_safety
                minimized["firstPassDimensions"] = first_dimensions
        usage = minimized.get("usage")
        if isinstance(usage, dict):
            minimized["usage"] = {
                key: usage[key]
                for key in ("assistantMessages", "cacheRead", "cacheWrite", "cost", "input", "output")
                if key in usage
            }
        runs.append(minimized)
    result: dict[str, Any] = {
        "metadata": {
            "createdAt": utc_now(),
            "experiment": original_metadata.get("experiment", "baseline"),
            "gitRevision": original_metadata.get("gitRevision"),
            "harnessSha256": original_metadata.get("harnessSha256"),
            "marginBinarySha256": original_metadata.get("marginBinarySha256"),
            "marginHelpSha256": original_metadata.get("marginHelpSha256"),
            "primeAgentVersion": original_metadata.get("primeAgentVersion"),
            "repositoryDirty": original_metadata.get("repositoryDirty"),
            "scenarioHashes": original_metadata.get("scenarioHashes", {}),
            "sourceEvalSetSha256": sha256_file(source),
        },
        "runs": runs,
        "schema": "urn:margin:cli-eval-baseline:v1",
    }
    result["aggregate"] = aggregate(result)
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    arguments = parser.parse_args()
    try:
        source = arguments.input.resolve()
        payload = json.loads(source.read_text(encoding="utf-8"))
        result = minimize(payload, source)
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
