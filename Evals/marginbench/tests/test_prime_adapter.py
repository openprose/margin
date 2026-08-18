from __future__ import annotations

import json
import os
import tempfile
import unittest
from contextlib import AsyncExitStack
from pathlib import Path
from unittest.mock import patch

try:
    import verifiers.v1 as vf
except ImportError:  # Core tests intentionally remain usable without Prime extras.
    vf = None

from marginbench.binary import resolve_margin_binary


PACKAGE_ROOT = Path(__file__).resolve().parents[1]
REPOSITORY_CANDIDATE = PACKAGE_ROOT.parent.parent
ROOT = REPOSITORY_CANDIDATE if (REPOSITORY_CANDIDATE / "Package.swift").is_file() else PACKAGE_ROOT
BINARY = ROOT / "build" / "margin"


def available_binary() -> Path | None:
    if BINARY.is_file():
        return BINARY
    try:
        return resolve_margin_binary()
    except ValueError:
        return None


@unittest.skipIf(vf is None, "Verifiers v1 is not installed")
class PrimeAdapterTests(unittest.TestCase):
    def setUp(self) -> None:
        self.binary = available_binary()
        if self.binary is None:
            self.skipTest(f"Build Margin first or install a packaged Linux artifact: {BINARY}")

    def test_plugin_exports_one_taskset_and_one_environment(self) -> None:
        from marginbench import MarginBenchEnv, MarginBenchTaskset
        from verifiers.v1.utils.loaders import environment_class, taskset_class

        self.assertIs(taskset_class("marginbench"), MarginBenchTaskset)
        self.assertIs(environment_class("marginbench"), MarginBenchEnv)

    def test_taskset_carries_no_oracle_in_wire_data(self) -> None:
        from marginbench.entropy import PUBLIC_DEVELOPMENT_KEY
        from marginbench.prime import (
            MarginBenchData,
            MarginBenchEnv,
            MarginBenchEnvConfig,
            MarginBenchTask,
            MarginBenchTaskset,
            MarginBenchTasksetConfig,
        )
        from marginbench.scenarios import generate_episode

        taskset = MarginBenchTaskset(MarginBenchTasksetConfig(id="marginbench", repetitions=1))
        task = next(iter(taskset))
        wire = task.data.model_dump_json()
        self.assertNotIn("oracle", wire)
        self.assertNotIn("files", wire)
        self.assertNotIn(next(iter(task.episode.files.values())), wire)
        self.assertEqual(task.data.control_profile, "role-separated-margin-only-v1")
        self.assertEqual(
            task.episode.fingerprint,
            generate_episode("human_agent_relay", PUBLIC_DEVELOPMENT_KEY, 0).fingerprint,
        )
        role_task = task.for_role(task.episode.roles[0])
        self.assertFalse(hasattr(role_task, "episode"))
        role_wire = role_task.data.model_dump_json()
        self.assertNotIn("oracle", role_wire)
        self.assertNotIn(next(iter(task.episode.files.values())), role_wire)

        rebuilt = MarginBenchTask(MarginBenchData.model_validate_json(wire), task.config)
        self.assertIsNone(rebuilt.episode)
        rebuilt.episode = taskset.episode_for(rebuilt.data)
        self.assertEqual(rebuilt.episode, task.episode)
        self.assertFalse(hasattr(rebuilt.for_role(rebuilt.episode.roles[0]), "episode"))
        tampered = rebuilt.data.model_copy(update={"fingerprint": "0" * 64})
        with self.assertRaisesRegex(ValueError, "fingerprint"):
            taskset.episode_for(tampered)

        served_environment = MarginBenchEnv(MarginBenchEnvConfig(
            taskset=MarginBenchTasksetConfig(id="marginbench", margin_binary=str(self.binary)),
        ))
        served_task = MarginBenchTask(MarginBenchData.model_validate_json(wire), task.config)
        self.assertEqual(served_environment._trusted_episode(served_task), task.episode)

    def test_taskset_selects_exact_private_repetitions_without_leaking_key(self) -> None:
        from marginbench.prime import MarginBenchTaskset, MarginBenchTasksetConfig
        from marginbench.scenarios import generate_episode

        environment_name = "MARGINBENCH_TEST_HOLDOUT_KEY"
        secret = "0123456789abcdef" * 4
        config = MarginBenchTasksetConfig(
            id="marginbench",
            scenario_ids=["human_agent_relay"],
            repetitions=1,
            repetition_ids=[3, 1],
            holdout_key_env=environment_name,
        )
        with patch.dict(os.environ, {environment_name: secret}):
            taskset = MarginBenchTaskset(config)
            tasks = list(taskset)
            self.assertNotIn(environment_name, os.environ)
            repeated = list(taskset)
        self.assertEqual([task.data.repetition for task in tasks], [3, 1])
        self.assertEqual(
            [task.episode.fingerprint for task in tasks],
            [
                generate_episode("human_agent_relay", secret.encode("utf-8"), repetition).fingerprint
                for repetition in (3, 1)
            ],
        )
        self.assertEqual(
            [task.episode.fingerprint for task in repeated],
            [task.episode.fingerprint for task in tasks],
        )

        invalid = MarginBenchTaskset(MarginBenchTasksetConfig(
            id="marginbench",
            repetition_ids=[2, 2],
        ))
        with self.assertRaisesRegex(ValueError, "unique values"):
            list(invalid)

    def test_prime_server_rebuilds_private_episode_only_inside_trusted_environment(self) -> None:
        from marginbench.prime import MarginBenchEnvConfig, MarginBenchTaskset, MarginBenchTasksetConfig
        from verifiers.v1.serve.server import EnvServer

        taskset_config = MarginBenchTasksetConfig(
            id="marginbench",
            scenario_ids=["directory_handoff"],
            margin_binary=str(self.binary),
        )
        source = next(iter(MarginBenchTaskset(taskset_config)))
        server = EnvServer(
            MarginBenchEnvConfig(taskset=taskset_config),
            address="tcp://127.0.0.1:0",
        )
        try:
            rebuilt = server._build_task(source.data.model_dump(mode="json"))
            self.assertIsNone(rebuilt.episode)
            trusted = server.env._trusted_episode(rebuilt)
            self.assertEqual(trusted.fingerprint, source.episode.fingerprint)
            self.assertFalse(hasattr(rebuilt.for_role(trusted.roles[0]), "episode"))
        finally:
            server.frontend.close()
            server.ctx.term()

    def test_mcp_tool_adapter_runs_the_real_confined_gateway(self) -> None:
        from marginbench.servers.gateway import MarginGatewayConfig, MarginGatewayToolset

        with tempfile.TemporaryDirectory(prefix="marginbench-prime-tool-test-") as temporary:
            root = Path(temporary)
            workspace = root / "workspace"
            workspace.mkdir()
            toolset = MarginGatewayToolset(MarginGatewayConfig(
                margin_binary=str(self.binary),
                workspace=str(workspace),
                event_log=str(root / "events.jsonl"),
                state_home=str(root / "state"),
                role="author",
                actor_id="urn:test:prime-author",
                actor_name="Prime Author",
            ))
            payload = json.loads(toolset.margin(["version"]))
            self.assertTrue(payload["ok"])
            blocked = json.loads(toolset.margin(["read", "/etc/passwd", "--json"]))
            self.assertEqual(blocked["errorCode"], "MARGINBENCH_WORKSPACE_ESCAPE")

            (workspace / "review.md").write_text("# Review\n", encoding="utf-8")
            initialized = json.loads(toolset.margin(["workspace", "init", "."]))
            self.assertTrue(initialized["ok"])
            plan = {
                "schema": "urn:margin:stage-intent:v1",
                "version": 1,
                "operations": [{
                    "kind": "contribution",
                    "path": "review.md",
                    "contributionKind": "issue",
                    "contributionID": "urn:test:structured-stdin",
                    "body": "Structured stdin remains portable.",
                    "issueState": "open",
                }],
            }
            staged = json.loads(toolset.margin([
                "stage", "create", ".", "--operations-file", "-",
                "--stage-id", "urn:test:stage:structured-stdin",
                "--request-id", "urn:test:request:structured-stdin",
            ], stdin=plan))
            self.assertTrue(staged["ok"])

    def test_mcp_server_starts_and_exposes_only_margin(self) -> None:
        import asyncio
        from mcp import ClientSession
        from mcp.client.streamable_http import streamable_http_client
        from verifiers.v1.mcp import serve_shared
        from marginbench.servers.gateway import MarginGatewayConfig, MarginGatewayToolset

        async def probe() -> None:
            with tempfile.TemporaryDirectory(prefix="marginbench-prime-server-test-") as temporary:
                root = Path(temporary)
                workspace = root / "workspace"
                workspace.mkdir()
                toolset = MarginGatewayToolset(MarginGatewayConfig(
                    margin_binary=str(self.binary),
                    workspace=str(workspace),
                    event_log=str(root / "events.jsonl"),
                    state_home=str(root / "state"),
                    role="reviewer",
                    actor_id="urn:test:prime-reviewer",
                    actor_name="Prime Reviewer",
                ))
                async with serve_shared([toolset], harness_is_local=True) as servers:
                    self.assertEqual(set(servers), {""})
                    async with AsyncExitStack() as stack:
                        read, write, *_ = await stack.enter_async_context(
                            streamable_http_client(servers[""].url)
                        )
                        session = await stack.enter_async_context(ClientSession(read, write))
                        await session.initialize()
                        tools = await session.list_tools()
                        self.assertEqual([tool.name for tool in tools.tools], ["margin"])
                        self.assertIn("suggest add|list|accept|reject", tools.tools[0].description)
                        self.assertIn("receipt's `nextActions`", tools.tools[0].description)
                        result = await session.call_tool("margin", {"arguments": ["version"]})
                        self.assertFalse(result.isError)
                        self.assertIn('"ok":true', result.content[0].text)

        # Prime's upstream server launcher allows a long provisioning window for
        # remote runtimes. This is a local contract test, so fail promptly and
        # leave a useful test failure instead of waiting for that remote timeout.
        # The subprocess runtime changes its working directory. Resolve a
        # source-checkout PYTHONPATH before launch so the server does not depend
        # on the caller having used an absolute path (installed wheels need no
        # adjustment).
        python_path = os.pathsep.join(
            value
            for value in (str(PACKAGE_ROOT.resolve()), os.environ.get("PYTHONPATH", ""))
            if value
        )
        with patch.dict(os.environ, {"PYTHONPATH": python_path}):
            asyncio.run(asyncio.wait_for(probe(), timeout=30))


if __name__ == "__main__":
    unittest.main()
