from __future__ import annotations

import json
import unittest
from pathlib import Path

from marginbench.binary import resolve_margin_binary
from marginbench.concurrency_probe import ConcurrencyProbeLimits, run_concurrency_probe
from marginbench.schema import canonical_json
from marginbench.validation import validate_bytes


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


class ConcurrencyProbeTests(unittest.TestCase):
    def test_probe_is_model_free_paired_source_safe_and_schema_valid(self) -> None:
        binary = available_binary()
        if binary is None:
            self.skipTest("Margin binary unavailable")
        report = run_concurrency_probe(
            binary,
            binary,
            limits=ConcurrencyProbeLimits(repetitions=4),
        )
        self.assertTrue(report["passed"])
        self.assertFalse(report["paidModelsInvoked"])
        self.assertTrue(report["method"]["pairedSimultaneousStart"])
        self.assertFalse(report["method"]["baselineCollisionRequired"])
        self.assertEqual(report["fixture"]["caseCount"], 4)
        self.assertEqual(
            report["fixture"]["caseSetSha256"],
            "41bd8eea0930f353efa9c3bb05b10453ed9002badf457b6361432f993dc1ed09",
        )
        for arm in report["arms"].values():
            self.assertEqual(arm["episodeCount"], 4)
            self.assertEqual(arm["minimumScore"], 100)
            self.assertTrue(arm["safetyPassed"])
            self.assertTrue(arm["sourcePreserved"])
            self.assertEqual(arm["invalidCommandCount"], 0)
            self.assertEqual(arm["commandCountHistogram"], {"4": 4})
            self.assertEqual(arm["visibleConflictCount"], 0)
        receipt = validate_bytes(canonical_json(report))
        self.assertTrue(receipt["valid"], receipt)

    def test_schema_rejects_inconsistent_histogram_delta_and_pass_flag(self) -> None:
        binary = available_binary()
        if binary is None:
            self.skipTest("Margin binary unavailable")
        report = run_concurrency_probe(
            binary,
            binary,
            limits=ConcurrencyProbeLimits(repetitions=4),
        )
        tampered = json.loads(canonical_json(report))
        tampered["arms"]["candidate"]["commandCountHistogram"] = {"4": 3, "6": 1}
        tampered["arms"]["candidate"]["visibleConflictCount"] = 1
        tampered["comparison"]["candidateMinusBaselineVisibleConflicts"] = 0
        receipt = validate_bytes(canonical_json(tampered))
        self.assertFalse(receipt["valid"])
        self.assertTrue(any("histogram total" in error for error in receipt["errors"]))
        self.assertTrue(any("visible-conflict delta" in error for error in receipt["errors"]))
        self.assertTrue(any("pass flag" in error for error in receipt["errors"]))

        unsafe_baseline = json.loads(canonical_json(report))
        unsafe_baseline["arms"]["baseline"]["safetyPassed"] = False
        receipt = validate_bytes(canonical_json(unsafe_baseline))
        self.assertFalse(receipt["valid"])
        self.assertTrue(any("pass flag" in error for error in receipt["errors"]))

    def test_limits_fail_before_process_launch(self) -> None:
        with self.assertRaisesRegex(ValueError, "repetitions"):
            ConcurrencyProbeLimits(repetitions=3)
        with self.assertRaisesRegex(ValueError, "repetitions"):
            ConcurrencyProbeLimits(repetitions=1_001)


if __name__ == "__main__":
    unittest.main()
