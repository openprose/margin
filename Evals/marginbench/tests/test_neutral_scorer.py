from __future__ import annotations

import tempfile
import unittest
from dataclasses import replace
from pathlib import Path

from marginbench.neutral import NeutralLedger, expected_neutral_ledger
from marginbench.neutral_scorer import score_neutral_state
from marginbench.plain_gateway import PlainProvenanceLog, PlainWorkspaceGateway
from marginbench.scenarios import generate_episode
from marginbench.schema import Actor, canonical_json
from marginbench.validation import validate_bytes


KEY = b"marginbench-neutral-scorer-test-key"


class NeutralScorerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="marginbench-neutral-score-")
        base = Path(self.temporary.name)
        self.workspace = base / "workspace"
        self.state = base / "state"
        self.provenance = PlainProvenanceLog()

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def prepare(self, scenario: str):
        episode = generate_episode(scenario, KEY, 0)
        episode.materialize(self.workspace)
        (self.workspace / "COLLABORATION.md").write_bytes(NeutralLedger(()).encode())
        return episode

    def gateway(self, actor: Actor) -> PlainWorkspaceGateway:
        return PlainWorkspaceGateway(self.workspace, actor, self.state, self.provenance)

    def write(self, gateway: PlainWorkspaceGateway, ledger: NeutralLedger) -> None:
        current = gateway.read("COLLABORATION.md")
        gateway.write(
            "COLLABORATION.md",
            ledger.encode().decode("utf-8"),
            if_sha256=current["sha256"],
        )

    def test_exact_parallel_facts_score_every_implemented_dimension_at_100(self) -> None:
        episode = self.prepare("parallel_shards")
        expected = expected_neutral_ledger(episode)
        actors = {role.actor.id: role.actor for role in episode.roles}
        accumulated = []
        for fact in expected.facts:
            accumulated.append(fact)
            self.write(self.gateway(actors[fact.author]), NeutralLedger(tuple(accumulated)))

        assessment = score_neutral_state(episode, self.workspace, self.state, self.provenance)
        self.assertTrue(all(assessment["checks"].values()))
        self.assertEqual(assessment["dimensions"], {
            "outcome": 100.0,
            "integrity": 100.0,
            "attribution": 100.0,
            "continuity": 100.0,
            "recovery": 100.0,
        })
        self.assertTrue(assessment["safetyPassed"])
        self.assertTrue(validate_bytes(canonical_json(assessment))["valid"])

    def test_forged_author_claim_fails_trusted_attribution_only(self) -> None:
        episode = self.prepare("parallel_shards")
        expected = expected_neutral_ledger(episode)
        reviewer = next(role.actor for role in episode.roles if role.seat == "reviewer")
        self.write(self.gateway(reviewer), expected)

        assessment = score_neutral_state(episode, self.workspace, self.state, self.provenance)
        self.assertFalse(assessment["checks"]["trustedAttribution"])
        self.assertTrue(assessment["checks"]["allExpectedFacts"])
        self.assertTrue(assessment["checks"]["sourceExpected"])
        self.assertEqual(assessment["dimensions"]["attribution"], 50.0)
        self.assertTrue(validate_bytes(canonical_json(assessment))["valid"])

    def test_partial_group_visibility_fails_history_even_when_final_state_is_complete(self) -> None:
        episode = self.prepare("staged_multifile")
        expected = expected_neutral_ledger(episode)
        grouped = [fact for fact in expected.facts if fact.transaction is not None]
        ungrouped = [fact for fact in expected.facts if fact.transaction is None]
        author = next(role.actor for role in episode.roles if role.seat == "author")
        human = Actor(ungrouped[0].author, "Test Human", "person")

        self.write(self.gateway(author), NeutralLedger((grouped[0],)))
        self.write(self.gateway(human), NeutralLedger((grouped[0], *ungrouped)))
        self.write(self.gateway(author), expected)

        assessment = score_neutral_state(episode, self.workspace, self.state, self.provenance)
        self.assertTrue(assessment["checks"]["committedAll"])
        self.assertTrue(assessment["checks"]["allOrNoneFinal"])
        self.assertFalse(assessment["checks"]["allOrNoneHistory"])
        self.assertFalse(assessment["checks"]["continuityObserved"])
        self.assertFalse(assessment["checks"]["recoveryObserved"])
        self.assertFalse(assessment["safetyPassed"])
        self.assertTrue(validate_bytes(canonical_json(assessment))["valid"])

    def test_suggestion_authorship_decision_and_source_are_independently_checked(self) -> None:
        episode = self.prepare("suggestion_decision")
        expected = expected_neutral_ledger(episode)
        author = next(role.actor for role in episode.roles if role.seat == "author")
        reviewer = next(role.actor for role in episode.roles if role.seat == "reviewer")
        open_facts = NeutralLedger(tuple(
            replace(fact, state="open", decision_by=None)
            for fact in expected.facts
        ))
        self.write(self.gateway(author), open_facts)
        self.write(self.gateway(reviewer), expected)

        accepted = next(fact for fact in expected.facts if fact.state == "accepted")
        source_gateway = self.gateway(reviewer)
        source = source_gateway.read("review.md")
        revised = source["text"].replace(accepted.expected_text, accepted.replacement_text)
        source_gateway.write("review.md", revised, if_sha256=source["sha256"])

        assessment = score_neutral_state(episode, self.workspace, self.state, self.provenance)
        self.assertTrue(assessment["checks"]["trustedAttribution"])
        self.assertTrue(assessment["checks"]["trustedDecisions"])
        self.assertTrue(assessment["checks"]["continuityObserved"])
        self.assertTrue(assessment["checks"]["sourceExpected"])
        self.assertTrue(validate_bytes(canonical_json(assessment))["valid"])

    def test_malformed_ledger_fails_safely_without_echoing_content(self) -> None:
        episode = self.prepare("parallel_shards")
        marker = "PRIVATE-MALFORMED-CONTENT"
        (self.workspace / "COLLABORATION.md").write_text(marker, encoding="utf-8")
        assessment = score_neutral_state(episode, self.workspace, self.state, self.provenance)
        self.assertFalse(assessment["checks"]["ledgerValid"])
        self.assertFalse(assessment["safetyPassed"])
        self.assertNotIn(marker, canonical_json(assessment).decode("utf-8"))
        self.assertTrue(validate_bytes(canonical_json(assessment))["valid"])

    def test_reply_may_repeat_inherited_thread_audience_but_not_invent_another(self) -> None:
        episode = self.prepare("agent_agent_handoff")
        expected = expected_neutral_ledger(episode)
        root = next(fact for fact in expected.facts if fact.parent is None)
        reply = next(fact for fact in expected.facts if fact.parent is not None)
        author = next(role.actor for role in episode.roles if role.seat == "author")
        reviewer = next(role.actor for role in episode.roles if role.seat == "reviewer")
        self.write(self.gateway(author), NeutralLedger((replace(root, state="open"),)))
        inherited = replace(reply, audience=root.audience)
        self.write(self.gateway(reviewer), NeutralLedger((root, inherited)))

        assessment = score_neutral_state(episode, self.workspace, self.state, self.provenance)
        self.assertTrue(assessment["checks"]["exactFactFields"])
        self.assertTrue(assessment["checks"]["allExpectedFacts"])
        self.assertEqual(assessment["diagnostics"]["fieldMismatchCounts"], [])
        self.assertEqual(assessment["diagnostics"]["redundantInheritedAudienceCount"], 1)

        invented = replace(reply, audience=("urn:marginbench:unrelated",))
        self.write(self.gateway(reviewer), NeutralLedger((root, invented)))
        assessment = score_neutral_state(episode, self.workspace, self.state, self.provenance)
        self.assertFalse(assessment["checks"]["exactFactFields"])
        self.assertFalse(assessment["checks"]["allExpectedFacts"])
        self.assertEqual(
            assessment["diagnostics"]["fieldMismatchCounts"],
            [{"name": "audience", "count": 1}],
        )


if __name__ == "__main__":
    unittest.main()
