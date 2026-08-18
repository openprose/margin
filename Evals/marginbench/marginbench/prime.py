"""Prime Intellect Verifiers v1 adapter for the provider-neutral benchmark."""

from __future__ import annotations

import asyncio
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
    # Prime's served path materializes client tasks before spawning the trusted
    # environment worker, so the value must remain available for that process to
    # inherit. MarginBenchEnv scrubs it before creating any agent process.
    value = os.environ.get(environment_name)
    if value is None:
        return PUBLIC_DEVELOPMENT_KEY
    encoded = value.encode("utf-8")
    if len(encoded) < 16:
        raise ValueError(f"{environment_name} must contain at least 16 bytes.")
    return encoded


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
        episode: EpisodeDefinition | None = None,
    ) -> None:
        super().__init__(data, config)
        self.episode = episode

    def for_role(self, role: RoleTask) -> vf.Task:
        if self.episode is None:
            raise RuntimeError("Role task requested before the hidden episode was reconstructed.")
        # The environment retains the complete episode for setup and scoring.
        # The agent receives a plain task containing only its public role data;
        # do not depend on a runtime serializing only selected attributes.
        return vf.Task(
            self.data.model_copy(update={
                "name": f"{self.episode.public_id}:{role.seat}",
                "description": f"MarginBench {role.workflow} role {role.seat}",
                "prompt": role.prompt,
                "system_prompt": None,
            }),
            self.config,
        )


class MarginBenchTasksetConfig(vf.TasksetConfig):
    scenario_ids: list[str] = Field(default_factory=lambda: list(SCENARIO_IDS))
    repetitions: int = Field(1, ge=1, le=100)
    repetition_ids: list[int] = Field(default_factory=list)
    holdout_key_env: str = "MARGINBENCH_HOLDOUT_KEY"
    margin_binary: str = ""
    control_profile: str = DEFAULT_CONTROL_PROFILE


class MarginBenchTaskset(vf.Taskset[MarginBenchTask, MarginBenchTasksetConfig]):
    def _generation_key(self) -> bytes:
        if not hasattr(self, "_marginbench_generation_key"):
            self._marginbench_generation_key = _generation_key(self.config.holdout_key_env)
        return self._marginbench_generation_key

    def episode_for(self, data: MarginBenchData) -> EpisodeDefinition:
        """Rebuild a hidden episode inside the trusted environment from wire-safe data."""
        require_implemented_profile(data.control_profile)
        if data.control_profile != self.config.control_profile:
            raise ValueError("Wire task control profile does not match the environment.")
        if data.scenario_id not in SCENARIO_IDS:
            raise ValueError(f"Unknown MarginBench scenario: {data.scenario_id}")
        episode = generate_episode(data.scenario_id, self._generation_key(), data.repetition)
        if data.fingerprint != episode.fingerprint or data.name != episode.public_id:
            raise ValueError("Wire task fingerprint does not match the regenerated episode.")
        return episode

    def scrub_generation_key(self) -> None:
        """Remove the secret from this trusted process before agent runtimes start."""
        value = os.environ.pop(self.config.holdout_key_env, None)
        if value is None:
            return
        encoded = value.encode("utf-8")
        if len(encoded) < 16:
            raise ValueError(f"{self.config.holdout_key_env} must contain at least 16 bytes.")
        cached = getattr(self, "_marginbench_generation_key", None)
        if cached is not None and cached != encoded:
            raise ValueError("Holdout key changed between task generation and environment start.")
        self._marginbench_generation_key = encoded

    def load(self):
        require_implemented_profile(self.config.control_profile)
        key = self._generation_key()
        repetitions = self.config.repetition_ids or list(range(self.config.repetitions))
        if (
            len(repetitions) > 100
            or len(repetitions) != len(set(repetitions))
            or any(value < 0 or value >= 100 for value in repetitions)
        ):
            raise ValueError("MarginBench repetition IDs must be unique values from 0 through 99.")
        index = 0
        for repetition in repetitions:
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
    def _trusted_episode(self, task: MarginBenchTask) -> EpisodeDefinition:
        if task.episode is None:
            task.episode = self.taskset.episode_for(task.data)
        return task.episode

    async def run(self, task: vf.Task, agents: vf.Agents) -> None:
        if not isinstance(task, MarginBenchTask):
            raise TypeError(f"MarginBenchEnv requires MarginBenchTask, got {type(task).__name__}.")
        episode = self._trusted_episode(task)
        self.taskset.scrub_generation_key()
        binary = resolve_margin_binary(self.taskset.config.margin_binary)
        started = time.perf_counter()
        with tempfile.TemporaryDirectory(prefix="marginbench-v1-") as temporary:
            root = Path(temporary)
            workspace = root / "workspace"
            control = root / "control"
            event_log = control / "events.jsonl"
            state_root = control / "state"
            episode.materialize(workspace)
            traces: list[vf.Trace] = []

            async def apply_events(phase: int, timing: str) -> None:
                for event in episode.events:
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

            phases = sorted({role.phase for role in episode.roles})
            for phase in phases:
                await apply_events(phase, "before")
                phase_roles = [role for role in episode.roles if role.phase == phase]
                if len(phase_roles) == 1:
                    await run_role(phase_roles[0])
                else:
                    await asyncio.gather(*(run_role(role) for role in phase_roles))
                await apply_events(phase, "after")

            elapsed = (time.perf_counter() - started) * 1000
            result = await asyncio.to_thread(
                score_episode,
                episode,
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
                "sourcePreserved": result.source_preserved,
                "commandCount": result.command_count,
                "invalidCommandCount": result.invalid_command_count,
                "durationMs": result.duration_ms,
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
