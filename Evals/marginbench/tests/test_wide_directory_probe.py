from __future__ import annotations

import json
import unittest
from pathlib import Path

from marginbench.binary import resolve_margin_binary
from marginbench.schema import canonical_json
from marginbench.validation import validate_bytes
from marginbench.wide_directory_probe import ProbeLimits, run_wide_directory_probe


PACKAGE_ROOT = Path(__file__).resolve().parents[1]
REPOSITORY_CANDIDATE = PACKAGE_ROOT.parent.parent
ROOT = REPOSITORY_CANDIDATE if (REPOSITORY_CANDIDATE / "Package.swift").is_file() else PACKAGE_ROOT
BINARY = ROOT / "build" / "margin"


def available_binary() -> Path | None:
    if BINARY.is_file():
        return BINARY
    try:
        return resolve_margin_binary()
    except ValueError:
        return None


class WideDirectoryProbeTests(unittest.TestCase):
    def test_probe_is_counterbalanced_deterministic_source_safe_and_schema_valid(self) -> None:
        binary = available_binary()
        if binary is None:
            self.skipTest("Margin binary unavailable")
        report = run_wide_directory_probe(
            binary,
            binary,
            limits=ProbeLimits(
                files=8,
                contributions_per_file=1,
                warmups=0,
                rounds=4,
            ),
        )
        self.assertTrue(report["passed"])
        self.assertFalse(report["paidModelsInvoked"])
        self.assertTrue(report["method"]["counterbalanced"])
        self.assertEqual(report["fixture"]["totalContributionCount"], 8)
        self.assertEqual(
            report["fixture"]["sha256"],
            "762340d61ed456e9f12b1baf74734f14a3299f3965c9c116c1716efbd8c5c463",
        )
        self.assertEqual(report["comparison"]["candidateMinusBaselineBytes"], 0)
        for arm in report["arms"].values():
            self.assertEqual(arm["sampleCount"], 4)
            self.assertTrue(arm["responseDeterministic"])
            self.assertTrue(arm["responseUsable"])
            self.assertTrue(arm["sourcePreserved"])
            self.assertEqual(arm["responseShape"]["fileCounts"], [4])
            self.assertEqual(arm["responseShape"]["workCounts"], [4])
            self.assertEqual(arm["responseShape"]["truncatedValues"], [True])
            self.assertEqual(
                arm["responseShape"]["omittedFileCountLowerBoundValues"],
                [True],
            )
        receipt = validate_bytes(canonical_json(report))
        self.assertTrue(receipt["valid"], receipt)

    def test_probe_schema_rejects_inconsistent_totals_and_pass_flag(self) -> None:
        schema_path = PACKAGE_ROOT / "schemas" / "v1" / "wide-directory-probe.schema.json"
        self.assertTrue(schema_path.is_file())
        binary = available_binary()
        if binary is None:
            self.skipTest("Margin binary unavailable")
        report = run_wide_directory_probe(
            binary,
            binary,
            limits=ProbeLimits(files=8, contributions_per_file=1, warmups=0, rounds=4),
        )
        tampered = json.loads(canonical_json(report))
        tampered["fixture"]["totalContributionCount"] += 1
        tampered["passed"] = False
        receipt = validate_bytes(canonical_json(tampered))
        self.assertFalse(receipt["valid"])
        self.assertTrue(any("contribution total" in error for error in receipt["errors"]))
        self.assertTrue(any("pass flag" in error for error in receipt["errors"]))

        unusable = json.loads(canonical_json(report))
        unusable["arms"]["candidate"]["responseUsable"] = False
        receipt = validate_bytes(canonical_json(unusable))
        self.assertFalse(receipt["valid"])
        self.assertTrue(any("pass flag" in error for error in receipt["errors"]))

    def test_probe_limits_fail_before_process_launch(self) -> None:
        with self.assertRaisesRegex(ValueError, "files"):
            ProbeLimits(files=7)
        with self.assertRaisesRegex(ValueError, "contributions"):
            ProbeLimits(contributions_per_file=9)
        with self.assertRaisesRegex(ValueError, "rounds"):
            ProbeLimits(rounds=3)


if __name__ == "__main__":
    unittest.main()
