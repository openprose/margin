from __future__ import annotations

import contextlib
import io
import json
import unittest

from marginbench.cli import main
from marginbench.entropy import PUBLIC_DEVELOPMENT_KEY
from marginbench.no_exchange import (
    assess_no_exchange_episode,
    build_no_exchange_feasibility,
    role_specific_neutral_oracles,
)
from marginbench.scenarios import SCENARIO_IDS, generate_episode
from marginbench.schema import canonical_json
from marginbench.validation import validate_bytes


class NoExchangeFeasibilityTests(unittest.TestCase):
    def test_all_frozen_scenarios_have_role_specific_non_vacuous_slices(self) -> None:
        expected = {
            "human_agent_relay": (0, 2, 1),
            "agent_agent_handoff": (1, 2, 0),
            "concurrent_review": (2, 0, 0),
            "suggestion_decision": (2, 3, 0),
            "staged_multifile": (0, 2, 1),
            "directory_handoff": (1, 4, 1),
            "parallel_shards": (2, 0, 0),
            "specialist_audit": (2, 0, 0),
            "distributed_synthesis": (1, 2, 0),
        }
        for scenario, totals in expected.items():
            with self.subTest(scenario=scenario):
                assessment = assess_no_exchange_episode(generate_episode(
                    scenario, PUBLIC_DEVELOPMENT_KEY, 0,
                ))
                self.assertEqual(
                    (
                        assessment["totals"]["independent"],
                        assessment["totals"]["collaborationDependent"],
                        assessment["totals"]["external"],
                    ),
                    totals,
                )
                self.assertIsNone(assessment["overallScore"])

    def test_private_oracles_include_only_independent_authored_creations(self) -> None:
        suggestion = generate_episode(
            "suggestion_decision", PUBLIC_DEVELOPMENT_KEY, 0,
        )
        oracles = role_specific_neutral_oracles(suggestion)
        self.assertEqual(len(oracles["author"].facts), 2)
        self.assertEqual(len(oracles["reviewer"].facts), 0)
        self.assertTrue(all(fact.kind == "suggestion" for fact in oracles["author"].facts))
        self.assertTrue(all(fact.state == "open" for fact in oracles["author"].facts))
        self.assertTrue(all(fact.decision_by is None for fact in oracles["author"].facts))

        staged = role_specific_neutral_oracles(generate_episode(
            "staged_multifile", PUBLIC_DEVELOPMENT_KEY, 0,
        ))
        self.assertTrue(all(not ledger.facts for ledger in staged.values()))

        handoff = role_specific_neutral_oracles(generate_episode(
            "agent_agent_handoff", PUBLIC_DEVELOPMENT_KEY, 0,
        ))
        self.assertEqual(len(handoff["author"].facts), 1)
        self.assertEqual(handoff["author"].facts[0].state, "open")

    def test_public_report_contains_no_content_identifiers_actors_or_paths(self) -> None:
        episodes = [
            generate_episode(scenario, PUBLIC_DEVELOPMENT_KEY, 0)
            for scenario in SCENARIO_IDS
        ]
        report = build_no_exchange_feasibility(episodes)
        encoded = canonical_json(report).decode("utf-8")
        for episode in episodes:
            self.assertNotIn(episode.fingerprint, encoded)
            for path, body in episode.files.items():
                self.assertNotIn(path, encoded)
                self.assertNotIn(body, encoded)
            for role in episode.roles:
                self.assertNotIn(role.actor.id, encoded)
                self.assertNotIn(role.prompt, encoded)
            for fact in episode.oracle.get("annotations", []):
                self.assertNotIn(str(fact["id"]), encoded)
                self.assertNotIn(str(fact["body"]), encoded)
        self.assertFalse(report["controlRunnable"])
        self.assertEqual(report["nextBlockingGate"], "independent-workspace-proof")
        self.assertTrue(validate_bytes(canonical_json(report))["valid"])

    def test_schema_semantics_reject_vacuous_or_inconsistent_aggregation(self) -> None:
        report = build_no_exchange_feasibility([
            generate_episode("parallel_shards", PUBLIC_DEVELOPMENT_KEY, 0),
        ])
        self.assertTrue(validate_bytes(canonical_json(report))["valid"])
        report["totals"]["independent"] += 1
        receipt = validate_bytes(canonical_json(report))
        self.assertFalse(receipt["valid"])
        self.assertTrue(any("totals" in item for item in receipt["errors"]))

    def test_cli_is_model_free_and_keeps_control_gated(self) -> None:
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            status = main([
                "no-exchange-feasibility",
                "--scenario", "parallel_shards",
                "--scenario", "distributed_synthesis",
                "--repetitions", "2",
            ])
        report = json.loads(output.getvalue())
        self.assertEqual(status, 0)
        self.assertFalse(report["paidModelsInvoked"])
        self.assertFalse(report["controlRunnable"])
        self.assertEqual(report["assessmentCount"], 4)
        self.assertEqual(report["aggregation"], "per-role-only-no-overall-score")
        self.assertTrue(validate_bytes(canonical_json(report))["valid"])


if __name__ == "__main__":
    unittest.main()
