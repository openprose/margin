from __future__ import annotations

import asyncio
import tempfile
import unittest
from pathlib import Path

from marginbench.neutral import NeutralLedger
from marginbench.neutral_scorer import score_neutral_state
from marginbench.plain_gateway import PlainGatewayError, PlainProvenanceLog, PlainWorkspaceGateway
from marginbench.plain_prompts import plain_role_task
from marginbench.plain_reference import apply_plain_harness_event
from marginbench.plain_scripted import run_plain_scripted_role
from marginbench.scenarios import SCENARIO_IDS, generate_episode
from marginbench.schema import Actor


KEY = b"marginbench-plain-scripted-test-key"


class PlainScriptedPolicyTests(unittest.TestCase):
    def test_every_public_role_prompt_completes_without_oracle_access(self) -> None:
        for repetition in range(5):
            for scenario in SCENARIO_IDS:
                with self.subTest(scenario=scenario, repetition=repetition):
                    assessment = asyncio.run(self.run_episode(scenario, repetition))
                    self.assertTrue(all(assessment["checks"].values()), assessment)
                    self.assertTrue(assessment["safetyPassed"])

    async def run_episode(self, scenario: str, repetition: int):
        episode = generate_episode(scenario, KEY, repetition)
        with tempfile.TemporaryDirectory(prefix="marginbench-plain-scripted-") as temporary:
            base = Path(temporary)
            workspace = base / "workspace"
            state = base / "state"
            provenance_path = base / "provenance.jsonl"
            episode.materialize(workspace)
            (workspace / "COLLABORATION.md").write_bytes(NeutralLedger(()).encode())
            if scenario == "staged_multifile":
                (workspace / "STAGE.md").write_text(
                    "# Stage cursor\n\nUninitialized.\n",
                    encoding="utf-8",
                )

            def provenance() -> PlainProvenanceLog:
                return PlainProvenanceLog(provenance_path)

            async def run_role(role) -> None:
                gateway = PlainWorkspaceGateway(workspace, role.actor, state, provenance())

                async def call(**arguments):
                    action = arguments.pop("action")
                    try:
                        if action == "guide":
                            return {"ok": True, "result": {"topic": arguments.get("topic")}}
                        if action == "list":
                            result = gateway.list(arguments.get("path", "."))
                        elif action == "read":
                            result = gateway.read(
                                arguments["path"],
                                start_line=arguments.get("start_line", 1),
                                max_lines=arguments.get("max_lines", 200),
                            )
                        elif action == "write":
                            result = gateway.write(
                                arguments["path"],
                                arguments["text"],
                                if_sha256=arguments["if_sha256"],
                            )
                        else:
                            raise PlainGatewayError("USAGE", "Unsupported test action.")
                        return {"ok": True, "result": result}
                    except PlainGatewayError as error:
                        return {"ok": False, "error": {"code": error.code}}

                await run_plain_scripted_role(plain_role_task(episode, role).prompt, call)

            for phase in sorted({role.phase for role in episode.roles}):
                for event in episode.events:
                    if event.phase == phase and event.timing == "before":
                        actor = Actor(**event.payload["actor"])
                        apply_plain_harness_event(
                            episode,
                            event,
                            PlainWorkspaceGateway(workspace, actor, state, provenance()),
                        )
                roles = [role for role in episode.roles if role.phase == phase]
                await asyncio.gather(*(run_role(role) for role in roles))
                for event in episode.events:
                    if event.phase == phase and event.timing == "after":
                        actor = Actor(**event.payload["actor"])
                        apply_plain_harness_event(
                            episode,
                            event,
                            PlainWorkspaceGateway(workspace, actor, state, provenance()),
                        )
            return score_neutral_state(
                episode,
                workspace,
                state,
                provenance(),
            )


if __name__ == "__main__":
    unittest.main()
