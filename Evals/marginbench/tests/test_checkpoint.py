from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from marginbench.checkpoint import CheckpointPromotionError, promote_checkpoint
from marginbench.schema import canonical_json
from marginbench.validation import validate_bytes


def _pair() -> tuple[dict, dict]:
    episode = {
        "scenario": "agent_agent_handoff",
        "fingerprint": "a" * 64,
        "repetition": 1,
        "checks": {"exact": True},
        "dimensions": {"outcome": 100.0},
        "safetyPassed": True,
        "sourcePreserved": True,
    }
    summary = {
        "schema": "urn:marginbench:prime-run-summary:v1",
        "status": "completed",
        "candidate": "candidate",
        "model": "provider/model",
        "wallet": {"observedDebitUSD": 0.001},
        "episodes": [{"episodeID": "episode", **episode}],
    }
    run = {
        "schema": "urn:marginbench:run:v1",
        "status": "completed",
        "candidate": {"id": "candidate"},
        "execution": {"model": "provider/model"},
        "cost": {"observedWalletDebit": 0.001},
        "episodes": [{"id": "episode", **episode}],
    }
    return summary, run


class CheckpointPromotionTests(unittest.TestCase):
    def test_promotion_is_cross_checked_atomic_and_idempotent(self) -> None:
        summary, run = _pair()
        summary_raw = canonical_json(summary) + b"\n"
        run_raw = canonical_json(run) + b"\n"

        def accepted(raw: bytes) -> dict:
            schema = json.loads(raw)["schema"]
            return {"valid": True, "artifactSchema": schema, "errors": []}

        with tempfile.TemporaryDirectory(prefix="marginbench-checkpoint-") as temporary:
            root = Path(temporary)
            raw = root / "raw"
            public = root / "public"
            raw.mkdir()
            public.mkdir()
            (raw / "generated-summary.json").write_bytes(summary_raw)
            (raw / "generated-run.json").write_bytes(run_raw)
            summary_file = public / "summary.json"
            run_file = public / "run.json"
            with patch("marginbench.checkpoint.validate_bytes", side_effect=accepted):
                first = promote_checkpoint(
                    raw,
                    summary_file=summary_file,
                    run_file=run_file,
                )
                second = promote_checkpoint(
                    raw,
                    summary_file=summary_file,
                    run_file=run_file,
                )
            self.assertEqual(first["status"], "promoted")
            self.assertEqual(second["status"], "already-present")
            self.assertEqual(summary_file.read_bytes(), summary_raw)
            self.assertEqual(run_file.read_bytes(), run_raw)
            self.assertTrue(validate_bytes(canonical_json(first))["valid"])

    def test_promotion_rejects_cross_artifact_mismatch_and_existing_other_data(self) -> None:
        summary, run = _pair()
        mismatched = json.loads(json.dumps(run))
        mismatched["candidate"]["id"] = "other"

        def accepted(raw: bytes) -> dict:
            schema = json.loads(raw)["schema"]
            return {"valid": True, "artifactSchema": schema, "errors": []}

        with tempfile.TemporaryDirectory(prefix="marginbench-checkpoint-mismatch-") as temporary:
            root = Path(temporary)
            raw = root / "raw"
            public = root / "public"
            raw.mkdir()
            public.mkdir()
            (raw / "generated-summary.json").write_bytes(canonical_json(summary) + b"\n")
            (raw / "generated-run.json").write_bytes(canonical_json(mismatched) + b"\n")
            with patch("marginbench.checkpoint.validate_bytes", side_effect=accepted):
                with self.assertRaisesRegex(CheckpointPromotionError, "candidate"):
                    promote_checkpoint(
                        raw,
                        summary_file=public / "summary.json",
                        run_file=public / "run.json",
                    )

            (raw / "generated-run.json").write_bytes(canonical_json(run) + b"\n")
            (public / "summary.json").write_text("other", encoding="utf-8")
            with patch("marginbench.checkpoint.validate_bytes", side_effect=accepted):
                with self.assertRaisesRegex(CheckpointPromotionError, "other data"):
                    promote_checkpoint(
                        raw,
                        summary_file=public / "summary.json",
                        run_file=public / "run.json",
                    )


if __name__ == "__main__":
    unittest.main()
