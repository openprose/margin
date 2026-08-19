from __future__ import annotations

import json
import os
import stat
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from marginbench.neutral import NeutralFact, NeutralLedger
from marginbench.plain_gateway import (
    MAX_LIST_ENTRIES,
    PlainGatewayError,
    PlainProvenanceLog,
    PlainWorkspaceGateway,
)
from marginbench.schema import Actor, canonical_json, sha256_bytes


AUTHOR = Actor("urn:marginbench:author:test", "Test Author")
REVIEWER = Actor("urn:marginbench:reviewer:test", "Test Reviewer")


def issue(identifier: str, actor: Actor, body: str) -> NeutralFact:
    return NeutralFact(
        id=identifier,
        kind="issue",
        file="review.md",
        author=actor.id,
        state="open",
        root=identifier,
        body=body,
    )


class PlainWorkspaceGatewayTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="marginbench-plain-")
        base = Path(self.temporary.name)
        self.root = base / "workspace"
        self.root.mkdir()
        (self.root / "review.md").write_text("# Review\n\nInitial.\n", encoding="utf-8")
        (self.root / "COLLABORATION.md").write_bytes(NeutralLedger(()).encode())
        self.state = base / "state"
        self.provenance = PlainProvenanceLog()

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def gateway(self, actor: Actor = AUTHOR) -> PlainWorkspaceGateway:
        return PlainWorkspaceGateway(self.root, actor, self.state, self.provenance)

    def test_bounded_list_read_cas_write_and_provenance(self) -> None:
        gateway = self.gateway()
        listing = gateway.list()
        self.assertEqual(
            [entry["name"] for entry in listing["entries"]],
            ["COLLABORATION.md", "review.md"],
        )
        read = gateway.read("COLLABORATION.md")
        replacement = NeutralLedger((issue("issue-1", AUTHOR, "Exact body."),)).encode()
        os.chmod(self.root / "COLLABORATION.md", 0o640)
        receipt = gateway.write(
            "COLLABORATION.md",
            replacement.decode("utf-8"),
            if_sha256=read["sha256"],
        )
        self.assertTrue(receipt["changed"])
        self.assertGreater(receipt["eventSequence"], 0)
        self.assertEqual(stat.S_IMODE(os.stat(self.root / "COLLABORATION.md").st_mode), 0o640)
        event = self.provenance.snapshot()[0]
        self.assertEqual(event.actor_id, AUTHOR.id)
        self.assertEqual(event.introduced_fact_ids, ("issue-1",))
        self.assertEqual(NeutralLedger.parse((self.root / "COLLABORATION.md").read_bytes()).facts[0].body, "Exact body.")

        replay = gateway.write(
            "COLLABORATION.md",
            replacement.decode("utf-8"),
            if_sha256=receipt["sha256"],
        )
        self.assertFalse(replay["changed"])
        self.assertIsNone(replay["eventSequence"])
        self.assertEqual(len(self.provenance.snapshot()), 1)

    def test_trusted_writer_identity_is_separate_from_claimed_author(self) -> None:
        gateway = self.gateway(REVIEWER)
        before = gateway.read("COLLABORATION.md")
        forged = NeutralLedger((issue("forged", AUTHOR, "Claimed as the author."),))
        gateway.write(
            "COLLABORATION.md",
            forged.encode().decode("utf-8"),
            if_sha256=before["sha256"],
        )
        event = self.provenance.snapshot()[0]
        self.assertEqual(event.actor_id, REVIEWER.id)
        self.assertEqual(forged.facts[0].author, AUTHOR.id)
        self.assertNotEqual(event.actor_id, forged.facts[0].author)

    def test_suggestion_decision_records_the_bound_decider(self) -> None:
        author_gateway = self.gateway(AUTHOR)
        open_suggestion = NeutralFact(
            id="suggestion-1",
            kind="suggestion",
            file="review.md",
            author=AUTHOR.id,
            state="open",
            root="suggestion-1",
            expected_text="Initial",
            replacement_text="Revised",
            body="Use the revision.",
        )
        initial = author_gateway.read("COLLABORATION.md")
        created = author_gateway.write(
            "COLLABORATION.md",
            NeutralLedger((open_suggestion,)).encode().decode("utf-8"),
            if_sha256=initial["sha256"],
        )

        accepted = NeutralFact(
            **{
                **open_suggestion.__dict__,
                "state": "accepted",
                "decision_by": REVIEWER.id,
            }
        )
        reviewer_gateway = self.gateway(REVIEWER)
        reviewer_gateway.write(
            "COLLABORATION.md",
            NeutralLedger((accepted,)).encode().decode("utf-8"),
            if_sha256=created["sha256"],
        )
        event = self.provenance.snapshot()[-1]
        self.assertEqual(event.actor_id, REVIEWER.id)
        self.assertEqual(event.changed_fact_ids, ("suggestion-1",))
        self.assertEqual(event.decided_fact_ids, ("suggestion-1",))

    def test_concurrent_same_cursor_writers_cannot_lose_each_other_silently(self) -> None:
        before = self.gateway().read("COLLABORATION.md")
        gateways = (self.gateway(AUTHOR), self.gateway(REVIEWER))
        replacements = (
            NeutralLedger((issue("author-issue", AUTHOR, "Author fact."),)),
            NeutralLedger((issue("reviewer-issue", REVIEWER, "Reviewer fact."),)),
        )

        def write(index: int) -> str:
            try:
                gateways[index].write(
                    "COLLABORATION.md",
                    replacements[index].encode().decode("utf-8"),
                    if_sha256=before["sha256"],
                )
                return "written"
            except PlainGatewayError as error:
                return error.code

        with ThreadPoolExecutor(max_workers=2) as executor:
            outcomes = list(executor.map(write, range(2)))
        self.assertEqual(sorted(outcomes), ["PRECONDITION_FAILED", "written"])
        final = NeutralLedger.parse((self.root / "COLLABORATION.md").read_bytes())
        self.assertEqual(len(final.facts), 1)
        self.assertEqual(len(self.provenance.snapshot()), 1)
        self.assertEqual(
            [event.error_code for event in self.provenance.failure_snapshot()],
            ["PRECONDITION_FAILED"],
        )

    def test_stale_invalid_and_noncanonical_writes_leave_bytes_untouched(self) -> None:
        gateway = self.gateway()
        original = (self.root / "COLLABORATION.md").read_bytes()
        original_sha = sha256_bytes(original)
        cases = (
            ("0" * 64, original.decode("utf-8"), "PRECONDITION_FAILED"),
            (original_sha, "# malformed\n", "INVALID_LEDGER"),
            (original_sha, "bad\r\nline", "INVALID_CONTENT"),
        )
        for digest, replacement, code in cases:
            with self.subTest(code=code):
                with self.assertRaises(PlainGatewayError) as raised:
                    gateway.write("COLLABORATION.md", replacement, if_sha256=digest)
                self.assertEqual(raised.exception.code, code)
                if code == "INVALID_LEDGER":
                    self.assertEqual(
                        set(raised.exception.details or {}),
                        {"formatCode", "byteOffset", "recovery"},
                    )
                    self.assertNotIn("malformed", repr(raised.exception.details))
                self.assertEqual((self.root / "COLLABORATION.md").read_bytes(), original)
        self.assertEqual(self.provenance.snapshot(), ())
        self.assertEqual(
            [event.error_code for event in self.provenance.failure_snapshot()],
            ["PRECONDITION_FAILED"],
        )

    def test_path_symlink_hardlink_case_and_hidden_boundaries(self) -> None:
        gateway = self.gateway()
        outside = Path(self.temporary.name) / "outside.md"
        outside.write_text("private", encoding="utf-8")
        os.symlink(outside, self.root / "linked.md")
        os.link(outside, self.root / "hard.md")
        (self.root / ".hidden.md").write_text("hidden", encoding="utf-8")
        listing = gateway.list()
        self.assertNotIn(".hidden.md", [entry["name"] for entry in listing["entries"]])
        self.assertEqual(
            next(entry for entry in listing["entries"] if entry["name"] == "linked.md")["kind"],
            "blocked",
        )
        for path, code in (
            ("../outside.md", "UNSAFE_PATH"),
            ("linked.md", "SYMLINK_BLOCKED"),
            ("hard.md", "UNSUPPORTED_FILE"),
            ("collaboration.md", "UNSAFE_PATH"),
        ):
            with self.subTest(path=path):
                with self.assertRaises(PlainGatewayError) as raised:
                    gateway.read(path)
                self.assertEqual(raised.exception.code, code)

    def test_listing_and_line_reads_are_bounded(self) -> None:
        gateway = self.gateway()
        (self.root / "review.md").write_text(
            "".join(f"line {index}\n" for index in range(20)),
            encoding="utf-8",
        )
        page = gateway.read("review.md", start_line=5, max_lines=3)
        self.assertEqual(page["text"], "line 4\nline 5\nline 6\n")
        self.assertTrue(page["truncatedBefore"])
        self.assertTrue(page["truncatedAfter"])

        for index in range(MAX_LIST_ENTRIES):
            (self.root / f"extra-{index:03d}.md").write_text("x", encoding="utf-8")
        with self.assertRaises(PlainGatewayError) as raised:
            gateway.list()
        self.assertEqual(raised.exception.code, "TOO_MANY_ENTRIES")

    def test_durable_provenance_is_locked_shared_private_and_fail_closed(self) -> None:
        path = self.state / "events.jsonl"
        first_log = PlainProvenanceLog(path)
        first = PlainWorkspaceGateway(self.root, AUTHOR, self.state / "locks", first_log)
        current = first.read("COLLABORATION.md")
        first.write(
            "COLLABORATION.md",
            NeutralLedger((issue("durable", AUTHOR, "Durable fact."),)).encode().decode("utf-8"),
            if_sha256=current["sha256"],
        )

        second_log = PlainProvenanceLog(path)
        second = PlainWorkspaceGateway(self.root, REVIEWER, self.state / "locks", second_log)
        second.read("COLLABORATION.md")
        writes = second_log.snapshot()
        reads = second_log.read_snapshot()
        self.assertEqual(len(writes), 1)
        self.assertEqual(len(reads), 2)
        sequences = sorted([writes[0].sequence, *(event.sequence for event in reads)])
        self.assertEqual(sequences, [1, 2, 3])
        self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o600)

        with path.open("ab") as handle:
            handle.write(b"incomplete-private-record")
        with self.assertRaises(PlainGatewayError) as raised:
            PlainProvenanceLog(path).snapshot()
        self.assertEqual(raised.exception.code, "INVALID_PROVENANCE")

    def test_durable_provenance_rejects_tampered_shapes_and_locations(self) -> None:
        path = self.state / "strict-events.jsonl"
        log = PlainProvenanceLog(path)
        gateway = PlainWorkspaceGateway(self.root, AUTHOR, self.state / "locks", log)
        gateway.read("COLLABORATION.md")
        original = json.loads(path.read_text(encoding="utf-8"))

        mutations = (
            {**original, "sequence": True},
            {**original, "type": []},
            {**original, "unexpected": "field"},
            {**original, "visible_fact_ids": ["duplicate", "duplicate"]},
            {**original, "path": "../COLLABORATION.md"},
            {**original, "actor_type": "untrusted"},
        )
        for index, record in enumerate(mutations):
            tampered = self.state / f"tampered-{index}.jsonl"
            tampered.write_bytes(canonical_json(record) + b"\n")
            with self.subTest(index=index), self.assertRaises(PlainGatewayError) as raised:
                PlainProvenanceLog(tampered).snapshot()
            self.assertEqual(raised.exception.code, "INVALID_PROVENANCE")

        duplicate = self.state / "duplicate-key.jsonl"
        duplicate.write_bytes(
            path.read_bytes().replace(b'{"actor_id":', b'{"sequence":1,"actor_id":', 1)
        )
        with self.assertRaises(PlainGatewayError) as raised:
            PlainProvenanceLog(duplicate).snapshot()
        self.assertEqual(raised.exception.code, "INVALID_PROVENANCE")

        target = self.state / "real-events.jsonl"
        target.write_bytes(path.read_bytes())
        linked = self.state / "linked-events.jsonl"
        linked.symlink_to(target)
        with self.assertRaises(PlainGatewayError) as raised:
            PlainProvenanceLog(linked).snapshot()
        self.assertEqual(raised.exception.code, "INVALID_PROVENANCE")


if __name__ == "__main__":
    unittest.main()
