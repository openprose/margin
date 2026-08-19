from __future__ import annotations

import unittest

from marginbench.neutral import (
    NEUTRAL_FORMAT,
    NEUTRAL_FACTS_SCHEMA,
    PREAMBLE,
    NeutralFact,
    NeutralFormatError,
    NeutralLedger,
    expected_neutral_ledger,
)
from marginbench.scenarios import SCENARIO_IDS, generate_episode
from marginbench.schema import canonical_json
from marginbench.validation import validate_bytes


def root_fact(identifier: str = "issue-1") -> NeutralFact:
    return NeutralFact(
        id=identifier,
        kind="issue",
        file="notes/review.md",
        quote="literal *Markdown* source",
        author="urn:marginbench:author:one",
        state="open",
        root=identifier,
        audience=("urn:marginbench:reviewer:two",),
        body="Unicode λ🙂\n\n## heading-shaped body\n\n```md\n---\n```",
        extensions=(("X-Visible note", "preserved"),),
    )


class NeutralLedgerTests(unittest.TestCase):
    def test_round_trip_is_canonical_body_safe_and_schema_valid(self) -> None:
        root = root_fact()
        reply = NeutralFact(
            id="reply-1",
            kind="reply",
            file=root.file,
            author="urn:marginbench:reviewer:two",
            state="resolved",
            parent=root.id,
            root=root.id,
            body="Acknowledged exactly.",
        )
        suggestion = NeutralFact(
            id="suggestion-1",
            kind="suggestion",
            file=root.file,
            author="urn:marginbench:author:one",
            state="accepted",
            root="suggestion-1",
            expected_text="old literal",
            replacement_text="new literal",
            decision_by="urn:marginbench:reviewer:two",
            body="Use the exact replacement.",
        )
        ledger = NeutralLedger((suggestion, reply, root))

        encoded = ledger.encode()
        parsed = NeutralLedger.parse(encoded)
        self.assertEqual(parsed.encode(), encoded)
        self.assertEqual([fact.id for fact in parsed.facts], ["issue-1", "reply-1", "suggestion-1"])
        self.assertIn(canonical_json(root.body), encoded)
        projection = parsed.to_dict()
        self.assertEqual(projection["schema"], NEUTRAL_FACTS_SCHEMA)
        self.assertEqual(projection["format"], NEUTRAL_FORMAT)
        self.assertTrue(validate_bytes(canonical_json(projection))["valid"])
        self.assertEqual(NeutralLedger.from_dict(projection), parsed)

    def test_empty_scaffold_is_the_only_canonical_empty_ledger(self) -> None:
        self.assertEqual(NeutralLedger(()).encode(), PREAMBLE)
        self.assertEqual(NeutralLedger.parse(PREAMBLE), NeutralLedger(()))
        with self.assertRaisesRegex(NeutralFormatError, "INVALID_HEADER"):
            NeutralLedger.parse(PREAMBLE + b"\n")

    def test_line_endings_trailing_bytes_and_noncanonical_body_json_fail_closed(self) -> None:
        encoded = NeutralLedger((root_fact(),)).encode()
        canonical_body = canonical_json(root_fact().body)
        escaped_body = canonical_body.replace("λ".encode("utf-8"), b"\\u03bb")
        cases = (
            (encoded.replace(b"\n", b"\r\n", 1), "INVALID_HEADER"),
            (encoded + b"\n", "INVALID_FIELD"),
            (
                encoded.replace(canonical_body, escaped_body),
                "BODY_JSON",
            ),
        )
        for raw, code in cases:
            with self.subTest(code=code):
                with self.assertRaises(NeutralFormatError) as raised:
                    NeutralLedger.parse(raw)
                self.assertEqual(raised.exception.code, code)

    def test_duplicate_unknown_and_noncanonical_fields_are_rejected(self) -> None:
        encoded = NeutralLedger((root_fact(),)).encode()
        duplicate = encoded.replace(b"Kind: issue", b"Kind: issue\nKind: issue")
        unknown = encoded.replace(b"Kind: issue", b"Mystery: issue")
        reordered = encoded.replace(
            b"Kind: issue\nFile: notes/review.md",
            b"File: notes/review.md\nKind: issue",
        )
        for raw, code in (
            (duplicate, "DUPLICATE_FIELD"),
            (unknown, "UNKNOWN_FIELD"),
            (reordered, "NON_CANONICAL"),
        ):
            with self.subTest(code=code):
                with self.assertRaises(NeutralFormatError) as raised:
                    NeutralLedger.parse(raw)
                self.assertEqual(raised.exception.code, code)

    def test_duplicate_ids_cycles_and_invalid_paths_are_rejected(self) -> None:
        root = NeutralFact(
            id="C",
            kind="issue",
            file="review.md",
            author="urn:actor:one",
            state="open",
            root="C",
            body="Root.",
        )
        first = NeutralFact(
            id="A",
            kind="reply",
            file="review.md",
            author="urn:actor:one",
            state="resolved",
            parent="C",
            root="C",
            body="First.",
        )
        second = NeutralFact(
            id="B",
            kind="reply",
            file="review.md",
            author="urn:actor:two",
            state="resolved",
            parent="A",
            root="C",
            body="Second.",
        )
        with self.assertRaisesRegex(ValueError, "duplicate"):
            NeutralLedger((root, root))
        with self.assertRaisesRegex(ValueError, "canonical Markdown path"):
            NeutralFact(
                id="escape",
                kind="issue",
                file="../review.md",
                author="urn:actor:one",
                state="open",
                root="escape",
                body="Blocked.",
            )

        encoded = NeutralLedger((root, first, second)).encode()
        cyclic = encoded.replace(b"Parent: C\nRoot: C", b"Parent: B\nRoot: C", 1)
        with self.assertRaises(NeutralFormatError) as raised:
            NeutralLedger.parse(cyclic)
        self.assertEqual(raised.exception.code, "INVALID_GRAPH")

    def test_suggestion_fields_and_projection_semantics_are_enforced(self) -> None:
        with self.assertRaisesRegex(ValueError, "expected and replacement"):
            NeutralFact(
                id="suggestion",
                kind="suggestion",
                file="review.md",
                author="urn:actor:one",
                state="open",
                root="suggestion",
                body="Incomplete.",
            )
        projection = NeutralLedger((root_fact(),)).to_dict()
        projection["facts"][0]["root"] = "another-root"
        receipt = validate_bytes(canonical_json(projection))
        self.assertFalse(receipt["valid"])
        self.assertTrue(any("root" in error for error in receipt["errors"]))

    def test_every_scenario_oracle_projects_without_losing_exact_facts(self) -> None:
        key = b"marginbench-neutral-public-feasibility-key"
        for scenario in SCENARIO_IDS:
            for repetition in range(5):
                with self.subTest(scenario=scenario, repetition=repetition):
                    episode = generate_episode(scenario, key, repetition)
                    ledger = expected_neutral_ledger(episode)
                    encoded = ledger.encode()
                    self.assertEqual(NeutralLedger.parse(encoded), ledger)
                    self.assertTrue(validate_bytes(canonical_json(ledger.to_dict()))["valid"])
                    self.assertEqual(len(ledger.facts), len(episode.oracle["annotations"]))
                    by_id = {fact.id: fact for fact in ledger.facts}
                    for annotation in episode.oracle["annotations"]:
                        fact = by_id[annotation["id"]]
                        self.assertEqual(fact.file, annotation["path"])
                        self.assertEqual(fact.author, annotation["creatorID"])
                        self.assertEqual(fact.body, annotation["body"])
                        self.assertEqual(
                            fact.kind,
                            "reply" if "parentID" in annotation else annotation["kind"],
                        )

        staged = expected_neutral_ledger(generate_episode("staged_multifile", key, 0))
        grouped = [fact for fact in staged.facts if fact.transaction is not None]
        self.assertEqual(len(grouped), 2)
        self.assertEqual(len({fact.transaction for fact in grouped}), 1)

        suggestions = expected_neutral_ledger(generate_episode("suggestion_decision", key, 0))
        self.assertEqual({fact.state for fact in suggestions.facts}, {"accepted", "rejected"})
        self.assertTrue(all(fact.expected_text and fact.replacement_text for fact in suggestions.facts))
        self.assertTrue(all(fact.decision_by for fact in suggestions.facts))


if __name__ == "__main__":
    unittest.main()
