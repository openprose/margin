from __future__ import annotations

import contextlib
import io
import json
import shutil
import tempfile
import unittest
from pathlib import Path

from marginbench.cli import main
from marginbench.publication import audit_crossover_publication
from marginbench.schema import canonical_json
from marginbench.validation import validate_bytes


PACKAGE_ROOT = Path(__file__).resolve().parents[1]
PUBLICATIONS = PACKAGE_ROOT / "results" / "crossover"


class CrossoverPublicationAuditTests(unittest.TestCase):
    def test_all_tracked_publications_are_complete_and_reproducible(self) -> None:
        expected = {
            "v15": (4, 2),
            "v16": (4, 2),
            "v17": (2, 1),
        }
        for name, (run_count, episode_count) in expected.items():
            with self.subTest(name=name):
                receipt = audit_crossover_publication(PUBLICATIONS / name)
                self.assertTrue(receipt["valid"], receipt["errors"])
                self.assertTrue(receipt["reportReproduced"])
                self.assertEqual(receipt["runCount"], run_count)
                self.assertEqual(receipt["summaryCount"], run_count)
                self.assertEqual(receipt["episodeCount"], episode_count)
                self.assertEqual(receipt["rawArtifactCount"], 0)
                self.assertTrue(validate_bytes(canonical_json(receipt))["valid"])

    def test_report_is_recomputed_from_matching_run_and_summary_cells(self) -> None:
        with tempfile.TemporaryDirectory(prefix="marginbench-publication-") as temporary:
            target = Path(temporary) / "v17"
            shutil.copytree(PUBLICATIONS / "v17", target)
            run_path = next((target / "cells").glob("*.run.json"))
            run = json.loads(run_path.read_text(encoding="utf-8"))
            profile = run["execution"]["controlProfile"]
            summary_path = next(
                path
                for path in (target / "cells").glob("*.summary.json")
                if json.loads(path.read_text(encoding="utf-8"))["episodes"][0]["controlProfile"]
                == profile
            )
            summary = json.loads(summary_path.read_text(encoding="utf-8"))
            run["episodes"][0]["durationMs"] += 1
            summary["episodes"][0]["durationMs"] += 1
            run_path.write_bytes(canonical_json(run))
            summary_path.write_bytes(canonical_json(summary))

            receipt = audit_crossover_publication(target)
            self.assertFalse(receipt["valid"])
            self.assertFalse(receipt["reportReproduced"])
            self.assertIn("REPORT_MISMATCH", {item["code"] for item in receipt["errors"]})
            self.assertTrue(validate_bytes(canonical_json(receipt))["valid"])

    def test_unexpected_raw_artifact_is_rejected_without_reading_it(self) -> None:
        marker = "PRIVATE-CONTENT-MUST-NOT-APPEAR"
        with tempfile.TemporaryDirectory(prefix="marginbench-publication-") as temporary:
            target = Path(temporary) / "v17"
            shutil.copytree(PUBLICATIONS / "v17", target)
            (target / "raw-trace.jsonl").write_text(marker, encoding="utf-8")

            receipt = audit_crossover_publication(target)
            rendered = canonical_json(receipt).decode("utf-8")
            self.assertFalse(receipt["valid"])
            self.assertEqual(receipt["rawArtifactCount"], 1)
            self.assertIn("UNEXPECTED_ARTIFACT", {item["code"] for item in receipt["errors"]})
            self.assertNotIn(marker, rendered)
            self.assertNotIn(str(target), rendered)
            self.assertTrue(validate_bytes(canonical_json(receipt))["valid"])

    def test_candidate_settings_mismatch_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory(prefix="marginbench-publication-") as temporary:
            target = Path(temporary) / "v17"
            shutil.copytree(PUBLICATIONS / "v17", target)
            (target / "candidate-settings.json").write_bytes(canonical_json({"changed": True}))

            receipt = audit_crossover_publication(target)
            self.assertFalse(receipt["valid"])
            self.assertIn("CANDIDATE_MISMATCH", {item["code"] for item in receipt["errors"]})
            self.assertTrue(validate_bytes(canonical_json(receipt))["valid"])

    def test_private_candidate_setting_is_rejected_without_echoing_its_value(self) -> None:
        marker = "pit_PRIVATE-MARKER"
        with tempfile.TemporaryDirectory(prefix="marginbench-publication-") as temporary:
            target = Path(temporary) / "v17"
            shutil.copytree(PUBLICATIONS / "v17", target)
            (target / "candidate-settings.json").write_bytes(
                canonical_json({"apiKey": marker})
            )

            receipt = audit_crossover_publication(target)
            rendered = canonical_json(receipt).decode("utf-8")
            self.assertFalse(receipt["valid"])
            self.assertIn("PRIVATE_SETTINGS", {item["code"] for item in receipt["errors"]})
            self.assertNotIn(marker, rendered)
            self.assertTrue(validate_bytes(canonical_json(receipt))["valid"])

    def test_oversized_directory_produces_a_bounded_valid_receipt(self) -> None:
        marker = "PRIVATE-EXTRA-CONTENT"
        with tempfile.TemporaryDirectory(prefix="marginbench-publication-") as temporary:
            target = Path(temporary) / "v17"
            shutil.copytree(PUBLICATIONS / "v17", target)
            for index in range(130):
                (target / f"extra-{index:03d}.json").write_text(marker, encoding="utf-8")

            receipt = audit_crossover_publication(target)
            rendered = canonical_json(receipt).decode("utf-8")
            self.assertFalse(receipt["valid"])
            self.assertIn("TOO_MANY_ARTIFACTS", {item["code"] for item in receipt["errors"]})
            self.assertLessEqual(len(receipt["errors"]), 128)
            self.assertNotIn(marker, rendered)
            self.assertNotIn(str(target), rendered)
            self.assertTrue(validate_bytes(canonical_json(receipt))["valid"])

    def test_cli_returns_success_only_for_a_valid_bundle(self) -> None:
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            status = main(["audit-crossover", str(PUBLICATIONS / "v17")])
        receipt = json.loads(output.getvalue())
        self.assertEqual(status, 0)
        self.assertTrue(receipt["valid"])

        with tempfile.TemporaryDirectory(prefix="marginbench-publication-") as temporary:
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                status = main(["audit-crossover", temporary])
            receipt = json.loads(output.getvalue())
        self.assertEqual(status, 65)
        self.assertFalse(receipt["valid"])


if __name__ == "__main__":
    unittest.main()
