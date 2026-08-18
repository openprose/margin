"""MarginBench core, with the Prime adapter loaded only when requested."""

from __future__ import annotations

from .gateway import MarginGateway, ToolPolicy
from .scenarios import SCENARIO_IDS, generate_episode
from .schema import EpisodeDefinition, EpisodeResult, RoleTask
from .scorer import score_episode

__all__ = [
    "EpisodeDefinition",
    "EpisodeResult",
    "MarginBenchEnv",
    "MarginBenchEnvConfig",
    "MarginBenchTaskset",
    "MarginBenchTasksetConfig",
    "MarginGateway",
    "RoleTask",
    "SCENARIO_IDS",
    "ToolPolicy",
    "generate_episode",
    "score_episode",
]


def __getattr__(name: str):
    if name in {
        "MarginBenchEnv",
        "MarginBenchEnvConfig",
        "MarginBenchTaskset",
        "MarginBenchTasksetConfig",
    }:
        from .prime import (
            MarginBenchEnv,
            MarginBenchEnvConfig,
            MarginBenchTaskset,
            MarginBenchTasksetConfig,
        )

        return {
            "MarginBenchEnv": MarginBenchEnv,
            "MarginBenchEnvConfig": MarginBenchEnvConfig,
            "MarginBenchTaskset": MarginBenchTaskset,
            "MarginBenchTasksetConfig": MarginBenchTasksetConfig,
        }[name]
    raise AttributeError(name)
