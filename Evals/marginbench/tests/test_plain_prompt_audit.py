from __future__ import annotations

import contextlib
import copy
import io
import json
import unittest
from dataclasses import replace
from unittest.mock import patch

from marginbench.cli import main
from marginbench.entropy import PUBLIC_DEVELOPMENT_KEY
from marginbench.plain_prompt_audit import audit_plain_prompts
from marginbench.plain_prompts import plain_role_task
from marginbench.scenarios import generate_episode
from marginbench.schema import canonical_json
from marginbench.validation import validate_bytes


class PlainPromptAuditTests(unittest.TestCase):
    def test_all_public_workflows_pass_the_independent_five_seed_audit(self) -> None:
        receipt = audit_plain_prompts()
        self.assertTrue(receipt["passed"])
        self.assertFalse(receipt["paidModelsInvoked"])
        self.assertEqual(receipt["scenarioCount"], 9)
        self.assertEqual(receipt["repetitionCount"], 5)
        self.assertEqual(receipt["rolePromptCount"], 85)
        self.assertTrue(all(case["passed"] for case in receipt["cases"]))
        self.assertTrue(validate_bytes(canonical_json(receipt))["valid"])

        rendered = canonical_json(receipt).decode("utf-8")
        episode = generate_episode("distributed_synthesis", PUBLIC_DEVELOPMENT_KEY, 0)
        self.assertNotIn(episode.oracle["reference"]["evidenceA"], rendered)
        self.assertNotIn(episode.oracle["reference"]["evidenceB"], rendered)

    def test_a_projection_wording_drift_requires_explicit_audit_review(self) -> None:
        episode = generate_episode("human_agent_relay", PUBLIC_DEVELOPMENT_KEY, 0)
        original = plain_role_task(episode, episode.roles[0])

        def changed_projection(_episode, _role):
            return replace(original, prompt=original.prompt.replace(
                "Resolve the root",
                "Maybe resolve the root",
            ))

        with patch(
            "marginbench.plain_prompt_audit.plain_role_task",
            side_effect=changed_projection,
        ):
            receipt = audit_plain_prompts(
                scenarios=["human_agent_relay"],
                repetitions=1,
            )
        self.assertFalse(receipt["passed"])
        self.assertFalse(receipt["cases"][0]["checks"]["exactSemanticProjection"])
        self.assertTrue(validate_bytes(canonical_json(receipt))["valid"])

    def test_semantic_and_aggregate_tampering_fail_validation(self) -> None:
        receipt = audit_plain_prompts(
            scenarios=["staged_multifile"],
            repetitions=1,
        )
        mutations = []

        changed_digest = copy.deepcopy(receipt)
        changed_digest["cases"][0]["observedSemanticSha256"] = "0" * 64
        mutations.append(changed_digest)

        changed_count = copy.deepcopy(receipt)
        changed_count["rolePromptCount"] += 1
        mutations.append(changed_count)

        changed_status = copy.deepcopy(receipt)
        changed_status["passed"] = False
        mutations.append(changed_status)

        for mutation in mutations:
            self.assertFalse(validate_bytes(canonical_json(mutation))["valid"])

    def test_cli_emits_a_valid_content_free_receipt(self) -> None:
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            status = main([
                "neutral-prompt-audit",
                "--scenario", "distributed_synthesis",
                "--repetitions", "2",
            ])
        receipt = json.loads(output.getvalue())
        self.assertEqual(status, 0)
        self.assertEqual(receipt["rolePromptCount"], 4)
        self.assertTrue(validate_bytes(canonical_json(receipt))["valid"])


if __name__ == "__main__":
    unittest.main()
