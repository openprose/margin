from __future__ import annotations

import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path

from marginbench.controls import control_profile, require_implemented_profile
from marginbench.cli import main
from marginbench.plain_reference import run_plain_reference_episode
from marginbench.scenarios import SCENARIO_IDS, generate_episode
from marginbench.schema import canonical_json
from marginbench.validation import validate_bytes


KEY = b"marginbench-plain-reference-feasibility-key"
PROFILE = "role-separated-plain-markdown-v1"


class PlainReferenceTests(unittest.TestCase):
    def test_all_nine_workflows_pass_the_implemented_neutral_state_checks(self) -> None:
        for scenario in SCENARIO_IDS:
            for repetition in range(5):
                with self.subTest(scenario=scenario, repetition=repetition):
                    episode = generate_episode(scenario, KEY, repetition)
                    with tempfile.TemporaryDirectory(prefix="marginbench-plain-reference-") as temporary:
                        assessment = run_plain_reference_episode(
                            episode,
                            Path(temporary) / "workspace",
                        )
                    self.assertTrue(all(assessment["checks"].values()), assessment)
                    self.assertEqual(assessment["dimensions"], {
                        "outcome": 100.0,
                        "integrity": 100.0,
                        "attribution": 100.0,
                        "continuity": 100.0,
                        "recovery": 100.0,
                    })
                    self.assertTrue(assessment["sourcePreserved"])
                    self.assertTrue(assessment["safetyPassed"])
                    self.assertEqual(
                        assessment["notEvaluated"],
                        ["efficiency"],
                    )
                    self.assertTrue(validate_bytes(canonical_json(assessment))["valid"])

    def test_plain_control_is_unlocked_only_after_its_independent_gates(self) -> None:
        profile = control_profile(PROFILE)
        self.assertEqual(profile["toolSurface"], ["workspace"])
        self.assertEqual(profile["status"], "implemented")
        self.assertEqual(profile["blockingGates"], [])
        self.assertEqual(require_implemented_profile(PROFILE), profile)

    def test_cli_receipt_is_explicitly_no_model_and_partial(self) -> None:
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            status = main([
                "neutral-feasibility",
                "--scenario", "parallel_shards",
                "--repetitions", "2",
            ])
        receipt = json.loads(output.getvalue())
        self.assertEqual(status, 0)
        self.assertFalse(receipt["paidModelsInvoked"])
        self.assertTrue(receipt["controlRunnable"])
        self.assertTrue(receipt["implementedChecksPassed"])
        self.assertEqual(receipt["assessmentCount"], 2)
        self.assertEqual(receipt["notEvaluated"], ["efficiency"])
        self.assertTrue(validate_bytes(canonical_json(receipt))["valid"])


if __name__ == "__main__":
    unittest.main()
