"""No-model proof that Prime role rollouts do not share private transcripts."""

from __future__ import annotations

import asyncio
import os
import time
from contextlib import contextmanager
from pathlib import Path
from types import SimpleNamespace
from typing import Iterator

import verifiers.v1 as vf

from .entropy import PUBLIC_DEVELOPMENT_KEY
from .plain_fake_model import plain_fake_model_server
from .prime import (
    MarginBenchData,
    MarginBenchEnv,
    MarginBenchEnvConfig,
    MarginBenchTask,
    MarginBenchTasksetConfig,
)
from .scenarios import SCENARIO_IDS, generate_episode
from .schema import canonical_json


PLAIN_ISOLATION_SCHEMA = "urn:marginbench:neutral-isolation-preflight:v1"
PLAIN_PROFILE = "role-separated-plain-markdown-v1"
FAKE_KEY_ENV = "MARGINBENCH_PLAIN_FAKE_API_KEY"


@contextmanager
def _runtime_environment() -> Iterator[None]:
    package_root = Path(__file__).resolve().parent.parent
    previous_python_path = os.environ.get("PYTHONPATH")
    previous_key = os.environ.get(FAKE_KEY_ENV)
    values = [str(package_root)]
    if previous_python_path:
        values.append(previous_python_path)
    os.environ["PYTHONPATH"] = os.pathsep.join(values)
    os.environ[FAKE_KEY_ENV] = "local-no-model-isolation-preflight"
    try:
        yield
    finally:
        if previous_python_path is None:
            os.environ.pop("PYTHONPATH", None)
        else:
            os.environ["PYTHONPATH"] = previous_python_path
        if previous_key is None:
            os.environ.pop(FAKE_KEY_ENV, None)
        else:
            os.environ[FAKE_KEY_ENV] = previous_key


class _RecordingAgent:
    def __init__(self, agent: vf.Agent) -> None:
        self.agent = agent
        self.runtime_config = agent.runtime_config
        self.traces: list[vf.Trace] = []

    async def run(self, task, *, tools):
        trace = await self.agent.run(task, tools=tools)
        self.traces.append(trace)
        return trace


def _agent(base_url: str) -> _RecordingAgent:
    return _RecordingAgent(vf.Agent(vf.AgentConfig(
        harness={"id": "null"},
        runtime=vf.SubprocessConfig(),
        model="marginbench-plain-fake",
        client=vf.EvalClientConfig(
            base_url=base_url,
            api_key_var=FAKE_KEY_ENV,
        ),
        sampling=vf.SamplingConfig(temperature=0, max_tokens=1_200),
        max_turns=24,
        max_input_tokens=64_000,
        max_output_tokens=8_000,
        max_total_tokens=72_000,
    )))


async def _run(scenarios: tuple[str, ...], repetitions: int, key: bytes) -> dict[str, object]:
    started = time.perf_counter()
    with plain_fake_model_server() as (server, handler):
        base_url = f"http://127.0.0.1:{server.server_port}/v1"
        author = _agent(base_url)
        reviewer = _agent(base_url)
        environment = MarginBenchEnv(MarginBenchEnvConfig(
            taskset=MarginBenchTasksetConfig(
                id="marginbench",
                holdout_key_env="MARGINBENCH_PLAIN_ISOLATION_UNUSED",
                margin_binary="/plain-isolation-does-not-use-margin",
                control_profile=PLAIN_PROFILE,
            ),
        ))
        agents = SimpleNamespace(author=author, reviewer=reviewer)
        episodes: list[dict[str, object]] = []
        with _runtime_environment():
            for repetition in range(repetitions):
                for scenario in scenarios:
                    episode = generate_episode(scenario, key, repetition)
                    before = len(author.traces) + len(reviewer.traces)
                    task = MarginBenchTask(
                        MarginBenchData(
                            idx=len(episodes),
                            name=episode.public_id,
                            description="plain transcript-isolation preflight episode",
                            prompt="The trusted environment assigns a role-specific brief.",
                            scenario_id=scenario,
                            repetition=repetition,
                            fingerprint=episode.fingerprint,
                            control_profile=PLAIN_PROFILE,
                        ),
                        episode=episode,
                    )
                    await environment.run(task, agents)
                    traces = [
                        trace
                        for trace in (*author.traces, *reviewer.traces)
                        if trace.info.get("marginbenchNeutralDevelopment", {}).get("episodeID")
                        == episode.public_id
                    ]
                    assessments = [
                        trace.info["marginbenchNeutralDevelopment"] for trace in traces
                    ]
                    expected = len(episode.roles)
                    passed = (
                        len(traces) == expected
                        and before + expected == len(author.traces) + len(reviewer.traces)
                        and all(trace.ok for trace in traces)
                        and all(value["implementedChecksPassed"] for value in assessments)
                        and all(value["safetyPassed"] for value in assessments)
                        and all(value["sourcePreserved"] for value in assessments)
                    )
                    episodes.append({
                        "episodeID": episode.public_id,
                        "scenario": scenario,
                        "repetition": repetition,
                        "roleProcessCount": len(traces),
                        "passed": passed,
                    })

        traces = [*author.traces, *reviewer.traces]
        role_process_count = sum(item["roleProcessCount"] for item in episodes)
        expected_echoes = handler.request_count - len(handler.prompt_digests)
        passed = (
            all(item["passed"] for item in episodes)
            and len(traces) == role_process_count
            and len(handler.prompt_digests) == role_process_count
            and handler.malformed_request_count == 0
            and handler.cross_role_canary_leak_count == 0
            and handler.own_canary_missing_count == 0
            and handler.own_canary_echo_count == expected_echoes
        )
        receipt = {
            "schema": PLAIN_ISOLATION_SCHEMA,
            "passed": passed,
            "paidModelsInvoked": False,
            "controlProfile": PLAIN_PROFILE,
            "controlRunnable": True,
            "marginBinaryUsed": False,
            "modelEndpoint": "loopback-scripted-openai-compatible",
            "executionBoundary": "fresh-subprocess-rollout-per-role",
            "toolSurface": ["workspace"],
            "rawPromptsRetained": False,
            "rawTranscriptsRetained": False,
            "scenarioCount": len(scenarios),
            "repetitionCount": repetitions,
            "episodeCount": len(episodes),
            "roleProcessCount": role_process_count,
            "distinctRolePromptCount": len(handler.prompt_digests),
            "fakeModelRequestCount": handler.request_count,
            "ownCanaryEchoCount": handler.own_canary_echo_count,
            "ownCanaryMissingCount": handler.own_canary_missing_count,
            "crossRoleCanaryLeakCount": handler.cross_role_canary_leak_count,
            "malformedRequestCount": handler.malformed_request_count,
            "durationMs": round((time.perf_counter() - started) * 1_000, 3),
            "episodes": episodes,
        }
    canonical_json(receipt)
    return receipt


def run_plain_isolation_preflight(
    *,
    scenarios: list[str] | tuple[str, ...] = SCENARIO_IDS,
    repetitions: int = 1,
    key: bytes = PUBLIC_DEVELOPMENT_KEY,
) -> dict[str, object]:
    selected = tuple(scenarios)
    if (
        not 1 <= repetitions <= 5
        or not selected
        or len(selected) > len(SCENARIO_IDS)
        or len(selected) != len(set(selected))
        or any(scenario not in SCENARIO_IDS for scenario in selected)
        or not isinstance(key, bytes)
        or len(key) < 16
    ):
        raise ValueError("Plain isolation preflight selection is invalid.")
    return asyncio.run(_run(selected, repetitions, key))
