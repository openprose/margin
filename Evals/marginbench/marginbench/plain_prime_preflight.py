"""Zero-model, all-workflow Prime served preflight for the plain control."""

from __future__ import annotations

import asyncio
import json
import os
import time
from contextlib import AsyncExitStack, contextmanager
from pathlib import Path
from types import SimpleNamespace
from typing import Iterator

import verifiers.v1 as vf
from mcp import ClientSession
from mcp.client.streamable_http import streamable_http_client

from .entropy import PUBLIC_DEVELOPMENT_KEY
from .plain_scripted import run_plain_scripted_role
from .prime import (
    MarginBenchData,
    MarginBenchEnv,
    MarginBenchEnvConfig,
    MarginBenchTask,
    MarginBenchTasksetConfig,
)
from .scenarios import SCENARIO_IDS, generate_episode
from .schema import canonical_json


PLAIN_SERVED_PREFLIGHT_SCHEMA = "urn:marginbench:neutral-served-preflight:v1"
PLAIN_PROFILE = "role-separated-plain-markdown-v1"


@contextmanager
def _source_import_path() -> Iterator[None]:
    """Let subprocess tool servers import a source checkout after changing cwd."""
    package_root = Path(__file__).resolve().parent.parent
    previous = os.environ.get("PYTHONPATH")
    values = [str(package_root)]
    if previous:
        values.append(previous)
    os.environ["PYTHONPATH"] = os.pathsep.join(values)
    try:
        yield
    finally:
        if previous is None:
            os.environ.pop("PYTHONPATH", None)
        else:
            os.environ["PYTHONPATH"] = previous


class PlainScriptedPrimeAgent:
    """A no-oracle reference role that sees only its task and served tool."""

    runtime_config = vf.SubprocessConfig()

    def __init__(self) -> None:
        self.traces: list[vf.Trace] = []
        self.prompt_byte_counts: list[int] = []

    async def run(self, task, *, tools):
        prompt = str(task.data.prompt)
        self.prompt_byte_counts.append(len(prompt.encode("utf-8")))
        async with AsyncExitStack() as stack:
            server = next(iter(tools.values()))
            read, write, *_ = await stack.enter_async_context(
                streamable_http_client(server.url)
            )
            session = await stack.enter_async_context(ClientSession(read, write))
            await session.initialize()
            advertised = await session.list_tools()
            if [tool.name for tool in advertised.tools] != ["workspace"]:
                raise RuntimeError("Plain served role received an unexpected tool surface.")

            async def call(**arguments):
                result = await session.call_tool("workspace", arguments)
                if result.isError or not result.content:
                    raise RuntimeError("Plain served tool returned an MCP transport error.")
                payload = json.loads(result.content[0].text)
                if not isinstance(payload, dict):
                    raise RuntimeError("Plain served tool returned a non-object payload.")
                return payload

            await run_plain_scripted_role(prompt, call)

        trace = vf.Trace(
            task=vf.TraceTask(type="marginbench", data=task.data),
            agent=vf.AgentInfo(config=vf.AgentConfig(
                harness=vf.HarnessConfig(id="null"),
                runtime=vf.SubprocessConfig(),
                model="plain-scripted-no-model",
            )),
            is_completed=True,
            ok=True,
        )
        self.traces.append(trace)
        return trace


async def _run(
    scenarios: tuple[str, ...],
    repetitions: int,
    key: bytes,
) -> dict[str, object]:
    started = time.perf_counter()
    author = PlainScriptedPrimeAgent()
    reviewer = PlainScriptedPrimeAgent()
    environment = MarginBenchEnv(MarginBenchEnvConfig(
        taskset=MarginBenchTasksetConfig(
            id="marginbench",
            holdout_key_env="MARGINBENCH_PLAIN_PREFLIGHT_UNUSED",
            margin_binary="/plain-preflight-does-not-use-margin",
            control_profile=PLAIN_PROFILE,
        ),
    ))
    agents = SimpleNamespace(author=author, reviewer=reviewer)
    assessments: list[dict[str, object]] = []
    with _source_import_path():
        for repetition in range(repetitions):
            for scenario in scenarios:
                episode = generate_episode(scenario, key, repetition)
                before = len(author.traces) + len(reviewer.traces)
                task = MarginBenchTask(
                    MarginBenchData(
                        idx=len(assessments),
                        name=episode.public_id,
                        description="gated plain served preflight episode",
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
                if len(traces) != len(episode.roles) or before + len(traces) != len(author.traces) + len(reviewer.traces):
                    raise RuntimeError("Plain served preflight trace partition is inconsistent.")
                values = [trace.info["marginbenchNeutralDevelopment"] for trace in traces]
                if any(value != values[0] for value in values[1:]):
                    raise RuntimeError("Plain served roles received inconsistent assessments.")
                assessment = values[0]
                assessments.append({
                    "episodeID": episode.public_id,
                    "scenario": scenario,
                    "repetition": repetition,
                    "traceCount": len(traces),
                    "wallTimeMs": assessment["durationMs"],
                    "implementedChecksPassed": assessment["implementedChecksPassed"],
                    "safetyPassed": assessment["safetyPassed"],
                    "sourcePreserved": assessment["sourcePreserved"],
                    "checks": assessment["checks"],
                    "dimensions": assessment["dimensions"],
                    "efficiencyObservations": assessment["efficiencyObservations"],
                })
    passed = all(
        value["implementedChecksPassed"]
        and value["safetyPassed"]
        and value["sourcePreserved"]
        for value in assessments
    )
    return {
        "schema": PLAIN_SERVED_PREFLIGHT_SCHEMA,
        "passed": passed,
        "paidModelsInvoked": False,
        "controlProfile": PLAIN_PROFILE,
        "controlRunnable": True,
        "marginBinaryUsed": False,
        "toolSurface": ["workspace"],
        "rawPromptsRetained": False,
        "roleTranscriptSharing": "none-between-roles",
        "scenarioCount": len(scenarios),
        "repetitionCount": repetitions,
        "assessmentCount": len(assessments),
        "roleProcessCount": len(author.traces) + len(reviewer.traces),
        "notEvaluated": ["efficiency"],
        "durationMs": round((time.perf_counter() - started) * 1_000, 3),
        "assessments": assessments,
    }


def run_plain_served_preflight(
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
        raise ValueError("Plain served preflight selection is invalid.")
    receipt = asyncio.run(_run(selected, repetitions, key))
    # Force serialization now so a caller never discovers an unsupported value
    # only after a long preflight has completed.
    canonical_json(receipt)
    return receipt
