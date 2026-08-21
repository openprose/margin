from __future__ import annotations

import asyncio
import json
import tempfile
import unittest
from contextlib import AsyncExitStack
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

try:
    import verifiers.v1 as vf
except ImportError:
    vf = None

from marginbench.entropy import PUBLIC_DEVELOPMENT_KEY
from marginbench.no_exchange import NO_EXCHANGE_PROFILE, role_specific_neutral_oracles
from marginbench.no_exchange_runner import (
    encode_no_exchange_response,
    no_exchange_role_task,
    parse_no_exchange_response,
    score_no_exchange_responses,
)
from marginbench.scenarios import SCENARIO_IDS, generate_episode


class NoExchangeResponseTests(unittest.TestCase):
    def test_prompt_removes_main_system_rules_and_response_round_trips(self) -> None:
        episode = generate_episode("concurrent_review", PUBLIC_DEVELOPMENT_KEY, 0)
        role = episode.roles[0]
        projected = no_exchange_role_task(episode, role)
        self.assertIn("deliberately isolated control condition", projected.prompt)
        self.assertIn("Return exactly one JSON object and no prose", projected.prompt)
        self.assertNotIn("You are operating Margin", projected.prompt)
        ledger = role_specific_neutral_oracles(episode)[role.seat]
        self.assertEqual(
            parse_no_exchange_response(encode_no_exchange_response(ledger)),
            ledger,
        )

    def test_parser_rejects_prose_unknown_fields_and_malformed_facts(self) -> None:
        episode = generate_episode("concurrent_review", PUBLIC_DEVELOPMENT_KEY, 0)
        ledger = role_specific_neutral_oracles(episode)[episode.roles[0].seat]
        encoded = encode_no_exchange_response(ledger)
        with self.assertRaisesRegex(ValueError, "JSON object"):
            parse_no_exchange_response("Here is the answer: " + encoded)
        value = json.loads(encoded)
        value["extra"] = True
        with self.assertRaisesRegex(ValueError, "envelope"):
            parse_no_exchange_response(json.dumps(value))
        value.pop("extra")
        value["facts"][0].pop("id")
        with self.assertRaisesRegex(ValueError, "shape"):
            parse_no_exchange_response(json.dumps(value))

    def test_role_scores_are_non_scalar_and_source_sensitive(self) -> None:
        episode = generate_episode("parallel_shards", PUBLIC_DEVELOPMENT_KEY, 0)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            workspaces = {}
            replies = {}
            oracles = role_specific_neutral_oracles(episode)
            for role in episode.roles:
                workspace = root / role.seat
                episode.materialize(workspace)
                workspaces[role.seat] = workspace
                replies[role.seat] = encode_no_exchange_response(oracles[role.seat])
            result = score_no_exchange_responses(episode, replies, workspaces)
            self.assertIsNone(result["overallScore"])
            self.assertTrue(result["sourcePreserved"])
            self.assertEqual(result["passedRoleCount"], result["roleCount"])
            self.assertTrue(all(item["passed"] for item in result["roles"]))
            (workspaces[episode.roles[0].seat] / sorted(episode.files)[0]).write_text(
                "changed", encoding="utf-8",
            )
            changed = score_no_exchange_responses(episode, replies, workspaces)
            self.assertFalse(changed["sourcePreserved"])
            self.assertFalse(changed["roles"][0]["checks"]["initialSourceUnchanged"])

    def test_all_frozen_workflows_project_and_score_exact_independent_answers(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for scenario in SCENARIO_IDS:
                with self.subTest(scenario=scenario):
                    episode = generate_episode(scenario, PUBLIC_DEVELOPMENT_KEY, 0)
                    oracles = role_specific_neutral_oracles(episode)
                    workspaces = {}
                    replies = {}
                    for role in episode.roles:
                        projected = no_exchange_role_task(episode, role)
                        self.assertLessEqual(len(projected.prompt.encode("utf-8")), 48_000)
                        workspace = root / scenario / role.seat
                        episode.materialize(workspace)
                        workspaces[role.seat] = workspace
                        replies[role.seat] = encode_no_exchange_response(oracles[role.seat])
                    result = score_no_exchange_responses(episode, replies, workspaces)
                    self.assertEqual(result["passedRoleCount"], len(episode.roles))


@unittest.skipIf(vf is None, "Verifiers v1 is not installed")
class NoExchangePrimeDevelopmentTests(unittest.TestCase):
    def test_environment_runs_independent_served_rollouts_and_scores_each_role(self) -> None:
        from mcp import ClientSession
        from mcp.client.streamable_http import streamable_http_client
        from marginbench.prime import (
            MarginBenchData,
            MarginBenchEnv,
            MarginBenchEnvConfig,
            MarginBenchTask,
            MarginBenchTasksetConfig,
        )

        episode = generate_episode("concurrent_review", PUBLIC_DEVELOPMENT_KEY, 0)
        oracles = role_specific_neutral_oracles(episode)

        class ScriptedAgent:
            runtime_config = vf.SubprocessConfig()

            def __init__(self, reply: str) -> None:
                self.reply = reply
                self.actions: list[str] = []
                self.trace = None

            async def run(self, task, *, tools):
                async with AsyncExitStack() as stack:
                    server = next(iter(tools.values()))
                    read, write, *_ = await stack.enter_async_context(
                        streamable_http_client(server.url)
                    )
                    session = await stack.enter_async_context(ClientSession(read, write))
                    await session.initialize()
                    advertised = await session.list_tools()
                    self.assert_equal([item.name for item in advertised.tools], ["workspace"])
                    for arguments in (
                        {"action": "guide"},
                        {"action": "read", "path": sorted(episode.files)[0]},
                        {"action": "write"},
                    ):
                        result = await session.call_tool("workspace", arguments)
                        payload = json.loads(result.content[0].text)
                        self.actions.append(str(payload["action"]))
                    self.assert_equal(payload["error"]["code"], "READ_ONLY")
                trace = vf.Trace(
                    task=vf.TraceTask(type="marginbench", data=task.data),
                    agent=vf.AgentInfo(config=vf.AgentConfig(
                        harness=vf.HarnessConfig(id="null"),
                        runtime=vf.SubprocessConfig(),
                        model="no-exchange-scripted",
                    )),
                    nodes=[vf.MessageNode(
                        message=vf.AssistantMessage(content=self.reply),
                        sampled=True,
                    )],
                    is_completed=True,
                    ok=True,
                )
                self.trace = trace
                return trace

            def assert_equal(self, left, right):
                if left != right:
                    raise AssertionError(f"{left!r} != {right!r}")

        agents_by_seat = {
            role.seat: ScriptedAgent(encode_no_exchange_response(oracles[role.seat]))
            for role in episode.roles
        }
        environment = MarginBenchEnv(MarginBenchEnvConfig(
            taskset=MarginBenchTasksetConfig(
                id="marginbench",
                control_profile=NO_EXCHANGE_PROFILE,
            ),
        ))
        task = MarginBenchTask(MarginBenchData(
            idx=0,
            name=episode.public_id,
            description="no-exchange integrated development episode",
            prompt="Trusted environment assigns isolated briefs.",
            scenario_id=episode.scenario_id,
            repetition=episode.repetition,
            fingerprint=episode.fingerprint,
            control_profile=NO_EXCHANGE_PROFILE,
        ), episode=episode)
        package_root = Path(__file__).resolve().parents[1]
        python_path = str(package_root)
        with patch.dict("os.environ", {"PYTHONPATH": python_path}):
            asyncio.run(environment.run(task, SimpleNamespace(**agents_by_seat)))
        for agent in agents_by_seat.values():
            self.assertEqual(agent.actions, ["guide", "read", "write"])
            assessment = agent.trace.info["marginbenchNoExchangeDevelopment"]
            self.assertFalse(assessment["controlRunnable"])
            self.assertIsNone(assessment["overallScore"])
            self.assertEqual(assessment["passedRoleCount"], len(episode.roles))
            self.assertEqual(assessment["separateAgentRolloutCount"], len(episode.roles))
            self.assertEqual(assessment["phasePolicy"], "independent-workspaces")
            self.assertNotIn("marginbench", agent.trace.rewards)


if __name__ == "__main__":
    unittest.main()
