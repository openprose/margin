from __future__ import annotations

import json
import unittest
from pathlib import Path

from marginbench.binary import resolve_margin_binary
from marginbench.contention_matrix import (
    ContentionMatrixLimits,
    run_contention_matrix,
)
from marginbench.schema import canonical_json
from marginbench.validation import validate_bytes


PACKAGE_ROOT = Path(__file__).resolve().parents[1]
REPOSITORY_CANDIDATE = PACKAGE_ROOT.parent.parent
ROOT = (
    REPOSITORY_CANDIDATE
    if (REPOSITORY_CANDIDATE / "Package.swift").is_file()
    else PACKAGE_ROOT
)
BINARY = ROOT / "build" / "margin"


def available_binary() -> Path | None:
    if BINARY.is_file():
        return BINARY
    try:
        return resolve_margin_binary()
    except ValueError:
        return None


class ContentionMatrixTests(unittest.TestCase):
    def test_real_cli_matrix_covers_operation_meaning_and_validates(self) -> None:
        binary = available_binary()
        if binary is None:
            self.skipTest("Margin binary unavailable")
        report = run_contention_matrix(
            binary,
            binary,
            limits=ContentionMatrixLimits(
                repetitions=1,
                group_sizes=(2,),
                recovery_rounds=3,
            ),
        )
        self.assertTrue(report["passed"])
        self.assertFalse(report["paidModelsInvoked"])
        self.assertEqual(report["fixture"]["caseCountPerArm"], 5)
        self.assertEqual(
            report["fixture"]["caseSetSha256"],
            "dd728214dc3da6fd20cec745eb8ef97425f8a8918bfa0e77aa0b3db8f2098206",
        )
        self.assertFalse(report["method"]["rawArgumentsRetained"])
        self.assertFalse(report["method"]["pathsBodiesAndIdentifiersRetained"])
        for arm in report["arms"].values():
            self.assertTrue(arm["passed"])
            self.assertEqual(arm["episodeCount"], 5)
            cases = {item["family"]: item for item in arm["cases"]}
            self.assertEqual(cases["typed-add"]["finalSuccessCount"], 2)
            self.assertEqual(cases["suggestion-add"]["finalSuccessCount"], 2)
            self.assertEqual(cases["suggestion-reject"]["finalSuccessCount"], 2)
            self.assertEqual(cases["suggestion-accept"]["finalSuccessCount"], 1)
            self.assertGreaterEqual(cases["handoff-add"]["finalSuccessCount"], 1)
            self.assertTrue(arm["safetyPassed"])
            self.assertTrue(arm["completionPassed"])
            self.assertTrue(all(all(item["checks"].values()) for item in arm["cases"]))
        receipt = validate_bytes(canonical_json(report))
        self.assertTrue(receipt["valid"], receipt)

    def test_validator_rejects_inconsistent_case_and_comparison_totals(self) -> None:
        binary = available_binary()
        if binary is None:
            self.skipTest("Margin binary unavailable")
        report = run_contention_matrix(
            binary,
            binary,
            limits=ContentionMatrixLimits(repetitions=1, group_sizes=(2,)),
        )
        tampered = json.loads(canonical_json(report))
        tampered_case = tampered["arms"]["candidate"]["cases"][0]
        tampered_case["finalSuccessCount"] -= 1
        tampered["comparison"][0]["candidateMinusBaselineMutationCalls"] += 1
        tampered["comparison"][0]["candidateMinusBaselineMedianDurationMs"] += 1
        tampered_case["agentVisibleCallCount"] += 1
        tampered_case["checks"]["completionPassed"] = False
        tampered_case["checks"]["noUnexpectedFailures"] = False
        tampered["fixture"]["caseSetSha256"] = "0" * 64
        tampered["passed"] = False
        receipt = validate_bytes(canonical_json(tampered))
        self.assertFalse(receipt["valid"])
        self.assertTrue(any("histogram total" in error for error in receipt["errors"]))
        self.assertTrue(any("comparison delta" in error for error in receipt["errors"]))
        self.assertTrue(any("visible-call total" in error for error in receipt["errors"]))
        self.assertTrue(any("case completion flag" in error for error in receipt["errors"]))
        self.assertTrue(any("unexpected-failure flag" in error for error in receipt["errors"]))
        self.assertTrue(any("case digest" in error for error in receipt["errors"]))
        self.assertTrue(any("pass flag" in error for error in receipt["errors"]))

    def test_baseline_safety_is_required_even_when_completion_is_descriptive(self) -> None:
        binary = available_binary()
        if binary is None:
            self.skipTest("Margin binary unavailable")
        report = run_contention_matrix(
            binary,
            binary,
            limits=ContentionMatrixLimits(repetitions=1, group_sizes=(2,)),
        )
        altered = json.loads(canonical_json(report))
        altered["arms"]["baseline"]["cases"][0]["checks"][
            "graphIntegrityPassed"
        ] = False
        altered["arms"]["baseline"]["safetyPassed"] = False
        altered["arms"]["baseline"]["passed"] = False
        altered["passed"] = False

        receipt = validate_bytes(canonical_json(altered))
        self.assertTrue(receipt["valid"], receipt)
        self.assertFalse(altered["passed"])

    def test_limits_fail_before_process_launch(self) -> None:
        with self.assertRaisesRegex(ValueError, "repetitions"):
            ContentionMatrixLimits(repetitions=0)
        with self.assertRaisesRegex(ValueError, "unique and increasing"):
            ContentionMatrixLimits(group_sizes=(4, 2))
        with self.assertRaisesRegex(ValueError, "between 2 and 32"):
            ContentionMatrixLimits(group_sizes=(2, 33))
        with self.assertRaisesRegex(ValueError, "recovery rounds"):
            ContentionMatrixLimits(recovery_rounds=9)


if __name__ == "__main__":
    unittest.main()
