from __future__ import annotations

import unittest

from marginbench.plain_prompts import plain_prompt_manifest, plain_role_task
from marginbench.scenarios import SCENARIO_IDS, SYSTEM_RULES, generate_episode


KEY = b"marginbench-plain-prompt-test-key"


class PlainPromptTests(unittest.TestCase):
    def test_every_role_has_a_bounded_identity_bound_non_cli_prompt(self) -> None:
        forbidden = (
            "You are collaborating through Margin",
            "`margin`",
            "stage create",
            "comments add",
            "comments reply",
            "comments resolve",
            "handoff list",
            "inbox or handoff view",
        )
        for repetition in range(5):
            for scenario in SCENARIO_IDS:
                episode = generate_episode(scenario, KEY, repetition)
                with self.subTest(scenario=scenario, repetition=repetition):
                    projected = [plain_role_task(episode, role) for role in episode.roles]
                    self.assertEqual(
                        [(role.seat, role.phase, role.actor) for role in projected],
                        [(role.seat, role.phase, role.actor) for role in episode.roles],
                    )
                    for original, role in zip(episode.roles, projected, strict=True):
                        self.assertIn(original.actor.id, role.prompt)
                        self.assertNotIn(SYSTEM_RULES, role.prompt)
                        self.assertLessEqual(len(role.prompt.encode("utf-8")), 32_768)
                        for value in forbidden:
                            self.assertNotIn(value, role.prompt)

    def test_role_private_answers_do_not_cross_prompt_boundaries(self) -> None:
        specialist = generate_episode("specialist_audit", KEY, 0)
        specialist_reference = specialist.oracle["reference"]
        specialist_prompts = {
            role.seat: plain_role_task(specialist, role).prompt
            for role in specialist.roles
        }
        for prompt in specialist_prompts.values():
            self.assertNotIn(specialist_reference["performanceChoice"], prompt)
            self.assertNotIn(specialist_reference["secureChoice"], prompt)

        synthesis = generate_episode("distributed_synthesis", KEY, 0)
        synthesis_reference = synthesis.oracle["reference"]
        synthesis_prompts = {
            role.seat: plain_role_task(synthesis, role).prompt
            for role in synthesis.roles
        }
        self.assertNotIn(synthesis_reference["evidenceB"], synthesis_prompts["author"])
        self.assertNotIn(synthesis_reference["evidenceA"], synthesis_prompts["reviewer"])

    def test_staged_prompts_preserve_authored_inputs_but_not_future_content(self) -> None:
        episode = generate_episode("staged_multifile", KEY, 0)
        reference = episode.oracle["reference"]
        prompts = {
            role.seat: plain_role_task(episode, role).prompt
            for role in episode.roles
        }
        for operation in reference["plan"]["operations"]:
            self.assertIn(operation["contributionID"], prompts["author"])
            self.assertIn(operation["body"], prompts["author"])
            self.assertNotIn(operation["body"], prompts["reviewer"])
        self.assertIn(reference["stageID"], prompts["author"])
        self.assertNotIn(reference["refreshedStageID"], prompts["author"])
        self.assertIn(reference["refreshedStageID"], prompts["reviewer"])
        self.assertNotIn(reference["stageID"], prompts["reviewer"])

    def test_manifest_is_content_free_and_deterministic(self) -> None:
        episode = generate_episode("distributed_synthesis", KEY, 0)
        manifest = plain_prompt_manifest(episode)
        self.assertEqual(manifest, plain_prompt_manifest(episode))
        rendered = str(manifest)
        self.assertEqual(manifest["roleCount"], 2)
        self.assertNotIn(episode.oracle["reference"]["evidenceA"], rendered)
        self.assertNotIn(episode.oracle["reference"]["evidenceB"], rendered)


if __name__ == "__main__":
    unittest.main()
