from __future__ import annotations

import copy
import json
import os
import subprocess
import sys
import unittest
from pathlib import Path

try:
    import verifiers.v1 as vf  # noqa: F401
except ImportError:  # Core tests intentionally remain usable without Prime extras.
    vf = None

from marginbench.schema import canonical_json
from marginbench.validation import validate_bytes


PACKAGE_ROOT = Path(__file__).resolve().parents[1]


@unittest.skipIf(vf is None, "Verifiers v1 is not installed")
class PlainProductionPreflightTests(unittest.TestCase):
    def test_paid_wrapper_dry_plan_needs_no_margin_binary_and_stays_non_scalar(self) -> None:
        base = [
            sys.executable,
            str(PACKAGE_ROOT / "prime_pilot.py"),
            "--model", "marginbench-fake",
            "--scenario", "parallel_shards",
            "--control-profile", "role-separated-plain-markdown-v1",
            "--candidate", "plain-markdown-control-v1",
            "--input-token-ceiling-per-call", "1000",
            "--input-price-per-million", "0",
            "--output-price-per-million", "0",
            "--max-cost-usd", "0.01",
        ]
        environment = os.environ.copy()
        environment.update({
            "PYTHONDONTWRITEBYTECODE": "1",
            "PYTHONPATH": str(PACKAGE_ROOT),
        })
        completed = subprocess.run(
            base,
            cwd=PACKAGE_ROOT.parent.parent,
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=30,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr.decode())
        plan = json.loads(completed.stdout)
        self.assertEqual(plan["track"], "representation")
        self.assertFalse(plan["marginBinaryUsed"])
        self.assertIn("controlCandidate", plan)
        self.assertNotIn("candidateManifest", plan)
        self.assertNotIn("marginSha256", plan)

        rejected = subprocess.run(
            [*base, "--margin-bin", "/tmp/not-a-margin-binary"],
            cwd=PACKAGE_ROOT.parent.parent,
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=30,
        )
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn(b"must not receive --margin-bin", rejected.stderr)

    def test_real_prime_cli_path_builds_both_official_artifacts_without_payment(self) -> None:
        from marginbench.plain_production_preflight import (
            run_plain_production_preflight,
        )

        receipt = run_plain_production_preflight(
            scenarios=["staged_multifile"],
            repetitions=1,
        )
        self.assertTrue(receipt["passed"], receipt)
        self.assertFalse(receipt["paidModelsInvoked"])
        self.assertTrue(receipt["controlRunnable"])
        self.assertFalse(receipt["marginBinaryUsed"])
        self.assertTrue(receipt["primeEvalInvoked"])
        self.assertEqual(receipt["traceCount"], 2)
        self.assertEqual(receipt["expectedRoleProcessCount"], 2)
        self.assertTrue(receipt["officialSummaryValidated"])
        self.assertTrue(receipt["officialRunValidated"])
        self.assertTrue(validate_bytes(canonical_json(receipt))["valid"])

        changed = copy.deepcopy(receipt)
        changed["traceCount"] += 1
        self.assertFalse(validate_bytes(canonical_json(changed))["valid"])


if __name__ == "__main__":
    unittest.main()
