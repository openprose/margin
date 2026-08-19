from __future__ import annotations

import asyncio
import json
import os
import re
import unittest
from contextlib import AsyncExitStack
from dataclasses import replace
from types import SimpleNamespace
from pathlib import Path
from unittest.mock import patch

try:
    import verifiers.v1 as vf
except ImportError:  # Core tests intentionally remain usable without Prime extras.
    vf = None

from marginbench.entropy import PUBLIC_DEVELOPMENT_KEY
from marginbench.neutral import NeutralFact, NeutralLedger
from marginbench.scenarios import generate_episode
from marginbench.schema import canonical_json
from marginbench.validation import validate_bytes


@unittest.skipIf(vf is None, "Verifiers v1 is not installed")
class PlainPrimeDevelopmentTests(unittest.TestCase):
    def test_served_preflight_receipt_is_schema_valid_bounded_and_runnable(self) -> None:
        from marginbench.plain_prime_preflight import run_plain_served_preflight

        receipt = run_plain_served_preflight(
            scenarios=["human_agent_relay"],
            repetitions=1,
        )
        self.assertTrue(receipt["passed"])
        self.assertFalse(receipt["paidModelsInvoked"])
        self.assertTrue(receipt["controlRunnable"])
        self.assertFalse(receipt["marginBinaryUsed"])
        self.assertEqual(receipt["toolSurface"], ["workspace"])
        self.assertEqual(receipt["assessmentCount"], 1)
        self.assertTrue(validate_bytes(canonical_json(receipt))["valid"])

        tampered = {**receipt, "roleProcessCount": receipt["roleProcessCount"] + 1}
        self.assertFalse(validate_bytes(canonical_json(tampered))["valid"])

    def test_plain_environment_runs_separate_roles_without_margin_or_answers(self) -> None:
        from mcp import ClientSession
        from mcp.client.streamable_http import streamable_http_client
        from marginbench.prime import (
            MarginBenchData,
            MarginBenchEnv,
            MarginBenchEnvConfig,
            MarginBenchTask,
            MarginBenchTasksetConfig,
        )

        episode = generate_episode("agent_agent_handoff", PUBLIC_DEVELOPMENT_KEY, 0)
        reference = episode.oracle["reference"]

        class ScriptedAgent:
            runtime_config = vf.SubprocessConfig()

            def __init__(self) -> None:
                self.prompts: list[str] = []
                self.traces: list[vf.Trace] = []

            async def run(self, task, *, tools):
                prompt = str(task.data.prompt)
                self.prompts.append(prompt)
                async with AsyncExitStack() as stack:
                    server = next(iter(tools.values()))
                    read, write, *_ = await stack.enter_async_context(
                        streamable_http_client(server.url)
                    )
                    session = await stack.enter_async_context(ClientSession(read, write))
                    await session.initialize()

                    async def call(**arguments):
                        result = await session.call_tool("workspace", arguments)
                        self.assert_tool_result(result)
                        return json.loads(result.content[0].text)

                    await call(action="guide", topic="facts")
                    opened = await call(action="read", path="COLLABORATION.md")
                    ledger = NeutralLedger.parse(opened["result"]["text"].encode("utf-8"))
                    actor = re.search(r"trusted actor ID is `([^`]+)`", prompt).group(1)
                    if "Create one handoff fact" in prompt:
                        match = re.search(
                            r"for actor (urn:\S+)\. Use handoff fact id ([0-9a-f-]+),\n"
                            r"request id [0-9a-f-]+, and exactly this body:\n(.+?)\nLeave it open",
                            prompt,
                            re.DOTALL,
                        )
                        next_actor, identifier, body = match.groups()
                        facts = (*ledger.facts, NeutralFact(
                            id=identifier,
                            kind="handoff",
                            file="review.md",
                            author=actor,
                            state="open",
                            root=identifier,
                            body=body.strip(),
                            next_actor=next_actor,
                            audience=(next_actor,),
                        ))
                    else:
                        match = re.search(
                            r"exactly this body:\n(.+?)\nUse reply fact id ([0-9a-f-]+)\.",
                            prompt,
                            re.DOTALL,
                        )
                        body, identifier = match.groups()
                        root = next(fact for fact in ledger.facts if fact.kind == "handoff")
                        facts = (
                            replace(root, state="resolved"),
                            NeutralFact(
                                id=identifier,
                                kind="reply",
                                file=root.file,
                                author=actor,
                                state="resolved",
                                parent=root.id,
                                root=root.id,
                                body=body.strip(),
                            ),
                        )
                    written = await call(
                        action="write",
                        path="COLLABORATION.md",
                        text=NeutralLedger(tuple(facts)).encode().decode("utf-8"),
                        if_sha256=opened["result"]["sha256"],
                    )
                    if not written["ok"]:
                        raise AssertionError("Plain development write failed.")
                    verified = await call(action="read", path="COLLABORATION.md")
                    if verified["result"]["sha256"] != written["result"]["sha256"]:
                        raise AssertionError("Plain development verification digest differed.")

                trace = vf.Trace(
                    task=vf.TraceTask(type="marginbench", data=task.data),
                    agent=vf.AgentInfo(config=vf.AgentConfig(
                        harness=vf.HarnessConfig(id="null"),
                        runtime=vf.SubprocessConfig(),
                        model="plain-scripted",
                    )),
                    is_completed=True,
                    ok=True,
                )
                self.traces.append(trace)
                return trace

            @staticmethod
            def assert_tool_result(result) -> None:
                if result.isError:
                    raise AssertionError("Plain development tool returned an MCP error.")

        author = ScriptedAgent()
        reviewer = ScriptedAgent()
        environment = MarginBenchEnv(MarginBenchEnvConfig(
            taskset=MarginBenchTasksetConfig(
                id="marginbench",
                margin_binary="/definitely/not/a/margin/binary",
                control_profile="role-separated-plain-markdown-v1",
            ),
        ))
        task = MarginBenchTask(
            MarginBenchData(
                idx=0,
                name=episode.public_id,
                description="gated plain development episode",
                prompt="Role prompt is assigned inside the environment.",
                scenario_id=episode.scenario_id,
                repetition=episode.repetition,
                fingerprint=episode.fingerprint,
                control_profile="role-separated-plain-markdown-v1",
            ),
            episode=episode,
        )
        package_root = Path(__file__).resolve().parents[1]
        python_path = os.pathsep.join(
            value
            for value in (str(package_root), os.environ.get("PYTHONPATH", ""))
            if value
        )
        with patch.dict(os.environ, {"PYTHONPATH": python_path}):
            asyncio.run(environment.run(task, SimpleNamespace(author=author, reviewer=reviewer)))

        self.assertEqual(len(author.traces), 1)
        self.assertEqual(len(reviewer.traces), 1)
        self.assertNotIn(reference["replyBody"], author.prompts[0])
        self.assertNotIn(reference["handoffBody"], reviewer.prompts[0])
        for trace in (*author.traces, *reviewer.traces):
            assessment = trace.info["marginbenchNeutralDevelopment"]
            self.assertTrue(assessment["implementedChecksPassed"])
            self.assertTrue(assessment["safetyPassed"])
            self.assertTrue(assessment["controlRunnable"])
            self.assertEqual(assessment["notEvaluated"], ["efficiency"])
            self.assertEqual(assessment["efficiencyObservations"]["toolCallCount"], 8)
            self.assertEqual(assessment["efficiencyObservations"]["failedToolCallCount"], 0)
            self.assertEqual(
                assessment["efficiencyObservations"]["actionCounts"],
                {"guide": 2, "list": 0, "read": 4, "write": 2, "invalid": 0},
            )
            self.assertGreater(assessment["efficiencyObservations"]["requestByteCount"], 0)
            self.assertGreater(assessment["efficiencyObservations"]["responseByteCount"], 0)
            self.assertIsNone(assessment["efficiencyObservations"]["scalarScore"])
            self.assertNotIn("marginbench", trace.rewards)
            self.assertEqual(
                trace.metrics["marginbench-neutral/implemented-checks-passed"],
                1.0,
            )


if __name__ == "__main__":
    unittest.main()
