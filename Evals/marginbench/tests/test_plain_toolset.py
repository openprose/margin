from __future__ import annotations

import asyncio
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

from marginbench.neutral import NeutralFact, NeutralLedger
from marginbench.plain_gateway import PlainProvenanceLog
from marginbench.schema import Actor


AUTHOR = Actor("urn:marginbench:plain-tool-author", "Plain Tool Author")
REVIEWER = Actor("urn:marginbench:plain-tool-reviewer", "Plain Tool Reviewer")


@unittest.skipIf(vf is None, "Verifiers v1 is not installed")
class PlainGatewayToolsetTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="marginbench-plain-tool-")
        base = Path(self.temporary.name)
        self.workspace = base / "workspace"
        self.workspace.mkdir()
        (self.workspace / "review.md").write_text("# Review\n\nInitial.\n", encoding="utf-8")
        (self.workspace / "COLLABORATION.md").write_bytes(NeutralLedger(()).encode())
        self.control = base / "control"
        self.control.mkdir(mode=0o700)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def toolset(self, actor: Actor):
        from marginbench.servers.plain_gateway import PlainGatewayConfig, PlainGatewayToolset

        return PlainGatewayToolset(PlainGatewayConfig(
            workspace=str(self.workspace),
            state_directory=str(self.control / "locks"),
            provenance_path=str(self.control / "provenance.jsonl"),
            actor_id=actor.id,
            actor_name=actor.name,
            actor_type=actor.type,
        ))

    def call(self, toolset, **arguments):
        return json.loads(toolset.workspace(**arguments))

    def test_progressive_guides_are_static_bounded_and_do_not_touch_workspace(self) -> None:
        toolset = self.toolset(AUTHOR)
        before = {path.name: path.read_bytes() for path in self.workspace.iterdir()}
        basics = self.call(toolset, action="guide")
        facts = self.call(toolset, action="guide", topic="facts")
        contextual = self.call(
            toolset,
            action="guide",
            topic="facts",
            path="review.md",
        )
        after = {path.name: path.read_bytes() for path in self.workspace.iterdir()}

        self.assertTrue(basics["ok"])
        self.assertEqual(basics["result"]["topics"], ["facts", "suggestions", "staging"])
        self.assertEqual(facts["result"]["format"], "marginbench-neutral-v2")
        self.assertIn("Body JSON", facts["result"]["fieldOrder"])
        self.assertTrue(contextual["ok"])
        self.assertEqual(contextual["result"], facts["result"])
        self.assertLess(len(json.dumps(facts).encode("utf-8")), 16_384)
        self.assertEqual(before, after)
        provenance = self.control / "provenance.jsonl"
        self.assertTrue(provenance.is_file())
        calls = PlainProvenanceLog(provenance).call_snapshot()
        self.assertEqual([event.action for event in calls], ["guide", "guide", "guide"])
        self.assertTrue(all(event.succeeded for event in calls))

    def test_independent_role_tools_share_only_files_and_private_provenance(self) -> None:
        author = self.toolset(AUTHOR)
        opened = self.call(author, action="read", path="COLLABORATION.md")
        fact = NeutralFact(
            id="handoff-1",
            kind="handoff",
            file="review.md",
            author=AUTHOR.id,
            state="open",
            root="handoff-1",
            body="Durable handoff.",
            next_actor=REVIEWER.id,
            audience=(REVIEWER.id,),
        )
        created = self.call(
            author,
            action="write",
            path="COLLABORATION.md",
            text=NeutralLedger((fact,)).encode().decode("utf-8"),
            if_sha256=opened["result"]["sha256"],
        )
        self.assertTrue(created["ok"])

        reviewer = self.toolset(REVIEWER)
        observed = self.call(reviewer, action="read", path="COLLABORATION.md")
        self.assertIn("Durable handoff.", observed["result"]["text"])
        stale = self.call(
            reviewer,
            action="write",
            path="COLLABORATION.md",
            text=NeutralLedger(()).encode().decode("utf-8"),
            if_sha256=opened["result"]["sha256"],
        )
        self.assertFalse(stale["ok"])
        self.assertEqual(stale["error"]["code"], "PRECONDITION_FAILED")
        provenance = PlainProvenanceLog(self.control / "provenance.jsonl")
        calls = provenance.call_snapshot()
        self.assertEqual([event.action for event in calls], ["read", "write", "read", "write"])
        self.assertEqual([event.succeeded for event in calls], [True, True, True, False])
        self.assertEqual(calls[-1].error_code, "PRECONDITION_FAILED")

    def test_usage_and_workspace_escape_errors_are_structured_and_content_free(self) -> None:
        toolset = self.toolset(AUTHOR)
        invalid = self.call(toolset, action="unknown")
        escaped = self.call(toolset, action="read", path="../private.md")
        mixed = self.call(toolset, action="list", text="PRIVATE-CONTENT")
        opened = self.call(toolset, action="read", path="COLLABORATION.md")
        malformed = self.call(
            toolset,
            action="write",
            path="COLLABORATION.md",
            text="# malformed\n",
            if_sha256=opened["result"]["sha256"],
        )

        self.assertEqual(invalid["error"]["code"], "USAGE")
        self.assertEqual(escaped["error"]["code"], "UNSAFE_PATH")
        self.assertEqual(mixed["error"]["code"], "USAGE")
        self.assertEqual(malformed["error"]["code"], "INVALID_LEDGER")
        self.assertEqual(
            set(malformed["error"]["details"]),
            {"formatCode", "byteOffset", "recovery"},
        )
        self.assertNotIn("PRIVATE-CONTENT", json.dumps(mixed))
        self.assertNotIn("malformed", json.dumps(malformed))

    def test_subprocess_server_exposes_only_the_plain_workspace_tool(self) -> None:
        from mcp import ClientSession
        from mcp.client.streamable_http import streamable_http_client
        from verifiers.v1.mcp import serve_shared

        async def probe() -> None:
            toolset = self.toolset(AUTHOR)
            async with serve_shared([toolset], harness_is_local=True) as servers:
                self.assertEqual(set(servers), {""})
                async with AsyncExitStack() as stack:
                    read, write, *_ = await stack.enter_async_context(
                        streamable_http_client(servers[""].url)
                    )
                    session = await stack.enter_async_context(ClientSession(read, write))
                    await session.initialize()
                    tools = await session.list_tools()
                    self.assertEqual([tool.name for tool in tools.tools], ["workspace"])
                    self.assertNotIn("margin", tools.tools[0].description.lower())
                    result = await session.call_tool(
                        "workspace",
                        {"action": "guide", "topic": "basics"},
                    )
                    self.assertFalse(result.isError)
                    self.assertIn('"ok":true', result.content[0].text)

        package_root = Path(__file__).resolve().parents[1]
        python_path = os.pathsep.join(
            value
            for value in (str(package_root), os.environ.get("PYTHONPATH", ""))
            if value
        )
        with patch.dict(os.environ, {"PYTHONPATH": python_path}):
            asyncio.run(asyncio.wait_for(probe(), timeout=30))


if __name__ == "__main__":
    unittest.main()
