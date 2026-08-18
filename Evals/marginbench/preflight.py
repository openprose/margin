#!/usr/bin/env python3
"""Zero-cost end-to-end Verifiers v1 preflight through a local fake model."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

sys.dont_write_bytecode = True
PACKAGE_ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(PACKAGE_ROOT))

from marginbench.fake_model import fake_model_server  # noqa: E402
from marginbench.controls import DEFAULT_CONTROL_PROFILE  # noqa: E402
from marginbench.scenarios import SCENARIO_IDS  # noqa: E402


def _find_score(value) -> float | None:
    if isinstance(value, dict):
        rewards = value.get("rewards")
        if isinstance(rewards, dict):
            marginbench = rewards.get("marginbench")
            if isinstance(marginbench, dict) and isinstance(marginbench.get("score"), (int, float)):
                return float(marginbench["score"])
        for child in value.values():
            if (score := _find_score(child)) is not None:
                return score
    elif isinstance(value, list):
        for child in value:
            if (score := _find_score(child)) is not None:
                return score
    return None


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--margin-bin", required=True)
    arguments = parser.parse_args()
    binary = Path(arguments.margin_bin).expanduser().resolve()
    prime = shutil.which("prime")
    if not prime:
        raise SystemExit("Prime CLI is not installed.")
    v1_eval = Path(prime).resolve().parent / "eval"
    if not v1_eval.is_file():
        raise SystemExit("The Prime Verifiers v1 eval executable is unavailable.")
    if not binary.is_file():
        raise SystemExit(f"Margin executable is unavailable: {binary}")

    with fake_model_server() as (server, handler), tempfile.TemporaryDirectory(
        prefix="marginbench-v1-preflight-"
    ) as output:
        environment = os.environ.copy()
        environment.update({
            "MARGINBENCH_FAKE_KEY": "local-non-secret",
            "PYTHONDONTWRITEBYTECODE": "1",
            "PYTHONPATH": str(PACKAGE_ROOT),
        })
        command = [
            str(v1_eval),
            "marginbench",
            "--model", "marginbench-fake",
            "--client.base-url", f"http://127.0.0.1:{server.server_port}/v1",
            "--client.api-key-var", "MARGINBENCH_FAKE_KEY",
            "--num-tasks", str(len(SCENARIO_IDS)),
            "--max-concurrent", "1",
            "--push", "false",
            "--rich", "false",
            "--output-dir", output,
            "--env.taskset.scenario-ids", *SCENARIO_IDS,
            "--env.taskset.margin-binary", str(binary),
            "--env.taskset.control-profile", DEFAULT_CONTROL_PROFILE,
        ]
        completed = subprocess.run(
            command,
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
            timeout=120,
        )
        trace_path = Path(output) / "traces.jsonl"
        scores: list[float] = []
        if trace_path.is_file():
            for line in trace_path.read_text(encoding="utf-8").splitlines():
                try:
                    payload = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if (score := _find_score(payload)) is not None:
                    scores.append(score)
        expected_rewards = [1.0] * len(SCENARIO_IDS)
        passed = (
            completed.returncode == 0
            and scores == expected_rewards
            and handler.request_count >= len(SCENARIO_IDS)
        )
        print(json.dumps({
            "schema": "urn:marginbench:prime-preflight:v1",
            "passed": passed,
            "paidModelsInvoked": False,
            "primeExitCode": completed.returncode,
            "fakeModelCalls": handler.request_count,
            "scenarioCount": len(SCENARIO_IDS),
            "scenarios": list(SCENARIO_IDS),
            "rewards": scores,
            "rawPromptsRetained": False,
            "toolSurface": ["margin"],
            "controlProfile": DEFAULT_CONTROL_PROFILE,
        }, separators=(",", ":"), sort_keys=True))
        return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
