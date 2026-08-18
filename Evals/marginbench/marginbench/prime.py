"""Prime Intellect Verifiers v1 adapter for the provider-neutral benchmark."""

from __future__ import annotations

import asyncio
import hashlib
import os
import tempfile
import time
from pathlib import Path

from pydantic import Field
import verifiers.v1 as vf
from verifiers.v1.mcp import serve_shared
from verifiers.v1.runtimes import runtime_is_local

from .binary import resolve_margin_binary
from .controls import DEFAULT_CONTROL_PROFILE, require_implemented_profile
from .entropy import PUBLIC_DEVELOPMENT_KEY
from .runner import apply_harness_event
from .scenarios import SCENARIO_IDS, generate_episode
from .schema import EpisodeDefinition, RoleTask
from .scorer import score_episode
from .servers.gateway import MarginGatewayConfig, MarginGatewayToolset


def _generation_key(environment_name: str) -> bytes:
    value = os.environ.get(environment_name)
    if value is None:
        return PUBLIC_DEVELOPMENT_KEY
    encoded = value.encode("utf-8")
    if len(encoded) < 16:
        raise ValueError(f"{environment_name} must contain at least 16 bytes.")
    return hashlib.sha256(encoded).digest()


class MarginBenchData(vf.TaskData):
    scenario_id: str
    repetition: int
    fingerprint: str
    control_profile: str


class MarginBenchTask(vf.Task[MarginBenchData, vf.State, vf.TaskConfig]):
    def __init__(
        self,
        data: MarginBenchData,
        config: vf.TaskConfig | None = None,
        *,
        episode: EpisodeDefinition,
    ) -> None:
        super().__init__(data, config)
        self.episode = episode

    def for_role(self, role: RoleTask) -> "MarginBenchTask":
        return MarginBenchTask(
            self.data.model_copy(update={
                "name": f"{self.episode.public_id}:{role.seat}",
                "description": f"MarginBench {role.workflow} role {role.seat}",
                "prompt": role.prompt,
                "system_prompt": None,
            }),
            self.config,
            episode=self.episode,
        )


class MarginBenchTasksetConfig(vf.TasksetConfig):
    scenario_ids: list[str] = Field(default_factory=lambda: list(SCENARIO_IDS))
    repetitions: int = Field(1, ge=1, le=100)
    holdout_key_env: str = "MARGINBENCH_HOLDOUT_KEY"
    margin_binary: str = ""
    control_profile: str = DEFAULT_CONTROL_PROFILE


class MarginBenchTaskset(vf.Taskset[MarginBenchTask, MarginBenchTasksetConfig]):
    def load(self):
        require_implemented_profile(self.config.control_profile)
        key = _generation_key(self.config.holdout_key_env)
        index = 0
        for repetition in range(self.config.repetitions):
            for scenario_id in self.config.scenario_ids:
                if scenario_id not in SCENARIO_IDS:
                    raise ValueError(f"Unknown MarginBench scenario: {scenario_id}")
                episode = generate_episode(scenario_id, key, repetition)
                yield MarginBenchTask(
                    MarginBenchData(
                        idx=index,
                        name=episode.public_id,
                        description=f"{scenario_id} collaboration episode",
                        prompt="MarginBench assigns a role-specific brief at episode start.",
                        scenario_id=scenario_id,
                        repetition=repetition,
                        fingerprint=episode.fingerprint,
                        control_profile=self.config.control_profile,
                    ),
                    self.config.task,
                    episode=episode,
                )
                index += 1


_NULL_AGENT = vf.AgentConfig(
    harness=vf.HarnessConfig(id="null"),
    runtime=vf.SubprocessConfig(),
    max_turns=24,
    max_output_tokens=8_000,
    max_total_tokens=64_000,
)


class MarginBenchEnvConfig(vf.EnvConfig):
    author: vf.AgentConfig = _NULL_AGENT
    reviewer: vf.AgentConfig = _NULL_AGENT
    max_concurrent_agents: int | None = 2
    gateway_timeout_seconds: float = Field(30.0, gt=0, le=120)
    gateway_max_output_bytes: int = Field(1_048_576, gt=0, le=4_194_304)


class MarginBenchEnv(vf.Env[MarginBenchEnvConfig]):
    async def run(self, task: vf.Task, agents: vf.Agents) -> None:
        if not isinstance(task, MarginBenchTask):
            raise TypeError(f"MarginBenchEnv requires MarginBenchTask, got {type(task).__name__}.")
        binary = resolve_margin_binary(self.taskset.config.margin_binary)
        started = time.perf_counter()
        with tempfile.TemporaryDirectory(prefix="marginbench-v1-") as temporary:
            root = Path(temporary)
            workspace = root / "workspace"
            control = root / "control"
            event_log = control / "events.jsonl"
            state_root = control / "state"
            task.episode.materialize(workspace)
            traces: list[vf.Trace] = []

            async def apply_events(phase: int, timing: str) -> None:
                for event in task.episode.events:
                    if event.phase == phase and event.timing == timing:
                        await asyncio.to_thread(
                            apply_harness_event,
                            event,
                            binary,
                            workspace,
                            event_log,
                            state_root,
                            self._policy(),
                        )

            async def run_role(role: RoleTask) -> None:
                agent = getattr(agents, role.seat)
                toolset = MarginGatewayToolset(MarginGatewayConfig(
                    margin_binary=str(binary),
                    workspace=str(workspace),
                    event_log=str(event_log),
                    state_home=str(state_root / "shared"),
                    role=role.seat,
                    actor_id=role.actor.id,
                    actor_name=role.actor.name,
                    actor_type=role.actor.type,
                    timeout_seconds=self.config.gateway_timeout_seconds,
                    max_output_bytes=self.config.gateway_max_output_bytes,
                ))
                async with serve_shared(
                    [toolset],
                    harness_is_local=runtime_is_local(agent.runtime_config),
                ) as tools:
                    trace = await agent.run(task.for_role(role), tools=tools)
                    traces.append(trace)

            phases = sorted({role.phase for role in task.episode.roles})
            for phase in phases:
                await apply_events(phase, "before")
                phase_roles = [role for role in task.episode.roles if role.phase == phase]
                if len(phase_roles) == 1:
                    await run_role(phase_roles[0])
                else:
                    await asyncio.gather(*(run_role(role) for role in phase_roles))
                await apply_events(phase, "after")

            elapsed = (time.perf_counter() - started) * 1000
            result = await asyncio.to_thread(
                score_episode,
                task.episode,
                workspace,
                binary,
                event_log,
                candidate_id="prime-v1",
                duration_ms=elapsed,
            )
            public_result = {
                "episodeID": result.episode_id,
                "score": result.score,
                "safetyPassed": result.safety_passed,
                "commandCount": result.command_count,
                "invalidCommandCount": result.invalid_command_count,
                "dimensions": result.dimensions,
                "checks": result.checks,
                "marginSha256": result.margin_sha256,
            }
            for trace in traces:
                trace.record_reward("marginbench", result.score / 100.0)
                for name, value in result.dimensions.items():
                    trace.record_metric(f"marginbench/{name}", value / 100.0)
                for name, value in result.checks.items():
                    trace.record_metric(f"marginbench/check/{name}", float(value))
                trace.info["marginbench"] = public_result

    def _policy(self):
        from .gateway import ToolPolicy

        return ToolPolicy(
            timeout_seconds=self.config.gateway_timeout_seconds,
            max_output_bytes=self.config.gateway_max_output_bytes,
        )
