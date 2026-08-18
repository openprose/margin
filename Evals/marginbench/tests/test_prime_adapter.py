from __future__ import annotations

import json
import tempfile
import unittest
from contextlib import AsyncExitStack
from pathlib import Path

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
        from marginbench.prime import MarginBenchTaskset, MarginBenchTasksetConfig
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
        asyncio.run(asyncio.wait_for(probe(), timeout=30))


if __name__ == "__main__":
    unittest.main()
