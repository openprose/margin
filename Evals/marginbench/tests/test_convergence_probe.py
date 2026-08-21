from __future__ import annotations

import json
import unittest
from pathlib import Path

from marginbench.binary import resolve_margin_binary
from marginbench.convergence_probe import (
    SuggestionConvergenceLimits,
    run_suggestion_convergence_probe,
)
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


class SuggestionConvergenceProbeTests(unittest.TestCase):
    def test_probe_is_causal_source_safe_and_schema_valid(self) -> None:
        binary = available_binary()
        if binary is None:
            self.skipTest("Margin binary unavailable")
        report = run_suggestion_convergence_probe(
            binary,
            binary,
            limits=SuggestionConvergenceLimits(
                repetitions_per_delay=2,
                delays_ms=(200,),
                poll_interval_ms=50,
                timeout_seconds=2,
            ),
        )
        self.assertTrue(report["passed"])
        self.assertFalse(report["paidModelsInvoked"])
        self.assertEqual(report["fixture"]["sampleCountPerArm"], 2)
        self.assertEqual(
            report["arms"]["candidate"]["convergenceCalls"]["histogram"],
            {"1": 2},
        )
        self.assertGreaterEqual(
            report["arms"]["baseline"]["convergenceCalls"]["min"],
            2,
        )
        self.assertLess(
            report["comparison"]["candidateToBaselineConvergenceCallRatio"],
            1,
        )
        for arm in report["arms"].values():
            self.assertEqual(arm["completedCount"], arm["sampleCount"])
            self.assertTrue(arm["documentValid"])
            self.assertTrue(arm["graphIntegrityPassed"])
            self.assertTrue(arm["sourcePreserved"])
        receipt = validate_bytes(canonical_json(report))
        self.assertTrue(receipt["valid"], receipt)

    def test_probe_schema_rejects_inconsistent_calls_and_pass_flag(self) -> None:
        binary = available_binary()
        if binary is None:
            self.skipTest("Margin binary unavailable")
        report = run_suggestion_convergence_probe(
            binary,
            binary,
            limits=SuggestionConvergenceLimits(
                repetitions_per_delay=2,
                delays_ms=(200,),
                timeout_seconds=2,
            ),
        )
        tampered = json.loads(canonical_json(report))
        tampered["arms"]["candidate"]["convergenceCalls"]["total"] += 1
        tampered["passed"] = False
        receipt = validate_bytes(canonical_json(tampered))
        self.assertFalse(receipt["valid"])
        self.assertTrue(any("call total" in error for error in receipt["errors"]))
        self.assertTrue(any("pass flag" in error for error in receipt["errors"]))

        forged_summary = json.loads(canonical_json(report))
        forged_summary["arms"]["baseline"]["convergenceCalls"]["median"] += 0.5
        receipt = validate_bytes(canonical_json(forged_summary))
        self.assertFalse(receipt["valid"])
        self.assertTrue(any("call summary" in error for error in receipt["errors"]))

        forged_fixture = json.loads(canonical_json(report))
        forged_fixture["fixture"]["caseSetSha256"] = "0" * 64
        receipt = validate_bytes(canonical_json(forged_fixture))
        self.assertFalse(receipt["valid"])
        self.assertTrue(any("case-set digest" in error for error in receipt["errors"]))

    def test_probe_limits_fail_before_process_launch(self) -> None:
        with self.assertRaisesRegex(ValueError, "repetitions"):
            SuggestionConvergenceLimits(repetitions_per_delay=1)
        with self.assertRaisesRegex(ValueError, "delays"):
            SuggestionConvergenceLimits(delays_ms=(200, 200))
        with self.assertRaisesRegex(ValueError, "poll interval"):
            SuggestionConvergenceLimits(poll_interval_ms=1)
        with self.assertRaisesRegex(ValueError, "timeout"):
            SuggestionConvergenceLimits(delays_ms=(2_000,), timeout_seconds=2)


if __name__ == "__main__":
    unittest.main()
