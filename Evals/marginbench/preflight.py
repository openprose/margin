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
from marginbench.budget_proxy import InferenceBudgetPolicy, InferenceBudgetProxy  # noqa: E402
from marginbench.controls import (  # noqa: E402
    DEFAULT_CONTROL_PROFILE,
    planned_topology,
    require_implemented_profile,
)
from marginbench.entropy import PUBLIC_DEVELOPMENT_KEY  # noqa: E402
from marginbench.keys import read_holdout_key  # noqa: E402
from marginbench.scenarios import AVAILABLE_SCENARIO_IDS, SCENARIO_IDS, generate_episode  # noqa: E402


def _find_scores(value) -> list[float]:
    scores: list[float] = []
    if isinstance(value, dict):
        rewards = value.get("rewards")
        if isinstance(rewards, dict):
            marginbench = rewards.get("marginbench")
            if isinstance(marginbench, dict) and isinstance(marginbench.get("score"), (int, float)):
                scores.append(float(marginbench["score"]))
        for child in value.values():
            scores.extend(_find_scores(child))
    elif isinstance(value, list):
        for child in value:
            scores.extend(_find_scores(child))
    return scores


def _expected_trace_count(
    control_profile: str,
    generation_key: bytes,
    scenarios: tuple[str, ...] = SCENARIO_IDS,
) -> int:
    """Count model traces, which need not equal benchmark episodes."""
    return sum(
        planned_topology(
            control_profile,
            [role.seat for role in generate_episode(scenario, generation_key, 0).roles],
        )["agentProcessCount"]
        for scenario in scenarios
    )


def _subprocess_environment(holdout_key: bytes | None) -> dict[str, str]:
    """Build the trusted eval environment without accepting an ambient holdout."""
    environment = os.environ.copy()
    environment.pop("MARGINBENCH_HOLDOUT_KEY", None)
    environment.update({
        "PYTHONDONTWRITEBYTECODE": "1",
        "PYTHONPATH": str(PACKAGE_ROOT),
    })
    if holdout_key is not None:
        environment["MARGINBENCH_HOLDOUT_KEY"] = holdout_key.decode("ascii")
    return environment


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--margin-bin", required=True)
    parser.add_argument("--holdout-key-file", type=Path)
    parser.add_argument("--control-profile", default=DEFAULT_CONTROL_PROFILE)
    parser.add_argument(
        "--scenario",
        action="append",
        choices=AVAILABLE_SCENARIO_IDS,
        help="scenario to rehearse; repeat to override the frozen nine-scenario default",
    )
    parser.add_argument(
        "--server",
        action="store_true",
        help="exercise Prime's out-of-process environment-server wire path",
    )
    parser.add_argument(
        "--timeout-seconds",
        type=int,
        default=120,
        help="maximum wall time for the local Prime evaluation (default: 120)",
    )
    arguments = parser.parse_args()
    if arguments.timeout_seconds <= 0:
        raise SystemExit("--timeout-seconds must be positive.")
    scenarios = tuple(arguments.scenario or SCENARIO_IDS)
    if len(scenarios) != len(set(scenarios)):
        raise SystemExit("--scenario values must be unique.")
    try:
        require_implemented_profile(arguments.control_profile)
    except ValueError as error:
        raise SystemExit(str(error)) from error
    binary = Path(arguments.margin_bin).expanduser().resolve()
    prime = shutil.which("prime")
    if not prime:
        raise SystemExit("Prime CLI is not installed.")
    v1_eval = Path(prime).resolve().parent / "eval"
    if not v1_eval.is_file():
        raise SystemExit("The Prime Verifiers v1 eval executable is unavailable.")
    if not binary.is_file():
        raise SystemExit(f"Margin executable is unavailable: {binary}")
    holdout_key = None
    holdout_key_id = None
    if arguments.holdout_key_file:
        try:
            holdout_key, holdout_key_id = read_holdout_key(arguments.holdout_key_file)
        except ValueError as error:
            raise SystemExit(str(error)) from error

    with fake_model_server() as (server, handler), InferenceBudgetProxy(
        f"http://127.0.0.1:{server.server_port}/v1",
        "local-preflight-upstream-only",
        InferenceBudgetPolicy(
            allowed_model="marginbench-fake",
            max_request_bytes=1024 * 1024,
            template_token_allowance=8192,
            input_token_ceiling=1_000_000,
            max_output_tokens=1200,
            input_price_per_million=0.03,
            output_price_per_million=0.13,
            billing_overhead_usd_per_call=0.0002,
            max_total_cost_usd=10.0,
        ),
    ) as budget_proxy, tempfile.TemporaryDirectory(prefix="marginbench-v1-preflight-") as output:
        environment = _subprocess_environment(holdout_key)
        environment["MARGINBENCH_PROXY_TOKEN"] = budget_proxy.client_token
        command = [
            str(v1_eval),
            "marginbench",
            "--model", "marginbench-fake",
            "--client.base-url", budget_proxy.base_url,
            "--client.api-key-var", "MARGINBENCH_PROXY_TOKEN",
            "--num-tasks", str(len(scenarios)),
            "--max-concurrent", "1",
            "--push", "false",
            "--rich", "false",
            "--output-dir", output,
            "--env.taskset.scenario-ids", *scenarios,
            "--env.taskset.margin-binary", str(binary),
            "--env.taskset.control-profile", arguments.control_profile,
            "--sampling.max-tokens", "1200",
        ]
        if arguments.server:
            command += [
                "--server", "true",
                "--serve.address", "tcp://127.0.0.1:0",
                "--serve.pool.type", "static",
                "--serve.pool.num-workers", "1",
            ]
        completed = subprocess.run(
            command,
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
            timeout=arguments.timeout_seconds,
        )
        trace_path = Path(output) / "traces.jsonl"
        scores: list[float] = []
        if trace_path.is_file():
            for line in trace_path.read_text(encoding="utf-8").splitlines():
                try:
                    payload = json.loads(line)
                except json.JSONDecodeError:
                    continue
                scores.extend(_find_scores(payload))
        expected_trace_count = _expected_trace_count(
            arguments.control_profile,
            holdout_key or PUBLIC_DEVELOPMENT_KEY,
            scenarios,
        )
        expected_rewards = [1.0] * expected_trace_count
        live_budget = budget_proxy.gate.report()
        passed = (
            completed.returncode == 0
            and scores == expected_rewards
            and handler.request_count >= len(scenarios)
            and live_budget["forwardedRequestCount"] == handler.request_count
            and live_budget["rejectedRequestCount"] == 0
        )
        print(json.dumps({
            "schema": "urn:marginbench:prime-preflight:v1",
            "passed": passed,
            "paidModelsInvoked": False,
            "primeExitCode": completed.returncode,
            "fakeModelCalls": handler.request_count,
            "scenarioCount": len(scenarios),
            "traceRewardCount": len(scores),
            "expectedTraceRewardCount": expected_trace_count,
            "scenarios": list(scenarios),
            "rewards": scores,
            "rawPromptsRetained": False,
            "toolSurface": ["margin"],
            "controlProfile": arguments.control_profile,
            "executionMode": "environment-server" if arguments.server else "in-process",
            "taskSet": "private-holdout-v1" if holdout_key_id else "public-development-v1",
            "holdoutKeyID": holdout_key_id,
            "liveBudget": live_budget,
        }, separators=(",", ":"), sort_keys=True))
        return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
