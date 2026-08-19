from __future__ import annotations

import contextlib
import copy
import hashlib
import io
import json
import tempfile
import unittest
from pathlib import Path

from marginbench.cli import main
from marginbench.efficiency import build_efficiency_report
from marginbench.schema import canonical_json
from marginbench.validation import validate_bytes


PACKAGE_ROOT = Path(__file__).resolve().parents[1]
V17_CELLS = PACKAGE_ROOT / "results" / "crossover" / "v17" / "cells"
ROLE_RUN = V17_CELLS / "0001-parallel-shards-role-5cdfb0a164.run.json"
CONTINUING_RUN = V17_CELLS / "0002-parallel-shards-continuing-422c21b182.run.json"
EPISODE_ID = "parallel_shards:0:1fe63b51c305"
REPRESENTATION_RESULTS = PACKAGE_ROOT / "results" / "representation" / "v1"
HANDOFF_MARGIN = REPRESENTATION_RESULTS / "handoff-r2-margin-v17.run.json"
HANDOFF_PLAIN = REPRESENTATION_RESULTS / "handoff-r2-plain-v2.run.json"


def neutral_receipt() -> dict[str, object]:
    checks = {
        "allExpectedFacts": True,
        "allOrNoneFinal": True,
        "allOrNoneHistory": True,
        "committedAll": True,
        "continuityObserved": True,
        "duplicateFree": True,
        "exactFactFields": True,
        "ledgerValid": True,
        "noUnexpectedFacts": True,
        "recoveryObserved": True,
        "sourceExpected": True,
        "trustedAttribution": True,
        "trustedDecisions": True,
    }
    return {
        "schema": "urn:marginbench:neutral-served-preflight:v1",
        "passed": True,
        "paidModelsInvoked": False,
        "controlProfile": "role-separated-plain-markdown-v1",
        "controlRunnable": True,
        "marginBinaryUsed": False,
        "toolSurface": ["workspace"],
        "rawPromptsRetained": False,
        "roleTranscriptSharing": "none-between-roles",
        "scenarioCount": 1,
        "repetitionCount": 1,
        "assessmentCount": 1,
        "roleProcessCount": 2,
        "notEvaluated": ["efficiency"],
        "durationMs": 125.0,
        "assessments": [{
            "episodeID": EPISODE_ID,
            "scenario": "parallel_shards",
            "repetition": 0,
            "traceCount": 2,
            "wallTimeMs": 120.0,
            "implementedChecksPassed": True,
            "safetyPassed": True,
            "sourcePreserved": True,
            "checks": checks,
            "dimensions": {
                "outcome": 100,
                "integrity": 100,
                "attribution": 100,
                "continuity": 100,
                "recovery": 100,
            },
            "efficiencyObservations": {
                "toolCallCount": 7,
                "failedToolCallCount": 1,
                "requestByteCount": 1200,
                "responseByteCount": 3400,
                "toolDurationMicroseconds": 12500,
                "actionCounts": {
                    "guide": 1,
                    "list": 1,
                    "read": 2,
                    "write": 2,
                    "invalid": 1,
                },
                "modelCallCount": 0,
                "inputTokenCount": 0,
                "outputTokenCount": 0,
                "costUSD": None,
                "scalarScore": None,
            },
        }],
    }


class EfficiencyReportTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="marginbench-efficiency-")
        self.addCleanup(self.temporary.cleanup)
        self.neutral_path = Path(self.temporary.name) / "neutral.json"
        self.neutral_path.write_bytes(canonical_json(neutral_receipt()))

    def build(self) -> dict[str, object]:
        return build_efficiency_report([
            self.neutral_path,
            ROLE_RUN,
            CONTINUING_RUN,
        ])

    def test_report_preserves_resource_vectors_without_declaring_a_winner(self) -> None:
        report = self.build()
        self.assertTrue(validate_bytes(canonical_json(report))["valid"])
        self.assertFalse(report["scalarRankingPermitted"])
        self.assertEqual(report["observationCount"], 3)
        self.assertEqual(report["episodeCount"], 1)
        self.assertEqual(len(report["sources"]), 3)
        self.assertEqual(report["matchedEpisodes"], [{
            "episodeID": EPISODE_ID,
            "observationCount": 3,
            "allOutcomePassed": True,
            "allSafetyPassed": True,
            "comparisonStatus": "mixed-execution-kind",
            "contractStatus": "not-applicable",
            "contractDifferences": [],
            "contractMissingFields": [],
            "winner": None,
        }])

        neutral = next(
            item for item in report["observations"]
            if item["executionKind"] == "scripted-reference"
        )
        self.assertEqual(neutral["toolRoundTrips"]["failedCount"], 1)
        self.assertEqual(neutral["toolRoundTrips"]["requestBytes"], 1200)
        self.assertEqual(neutral["toolRoundTrips"]["cumulativeToolTimeMs"], 12.5)
        self.assertEqual(neutral["modelUsage"]["calls"], 0)
        self.assertIsNone(neutral["modelUsage"]["reportedCostUSD"])
        self.assertEqual(neutral["missingMeasurements"], ["reported-cost"])

        real = [
            item for item in report["observations"]
            if item["executionKind"] == "real-model"
        ]
        self.assertEqual(len(real), 2)
        for observation in real:
            self.assertGreater(observation["modelUsage"]["calls"], 0)
            self.assertGreater(observation["modelUsage"]["promptTokens"], 0)
            self.assertGreater(observation["modelUsage"]["reportedCostUSD"], 0)
            self.assertIsNone(observation["toolRoundTrips"]["requestBytes"])
            self.assertEqual(observation["missingMeasurements"], [
                "cumulative-tool-time",
                "failed-tool-round-trips",
                "tool-request-bytes",
                "tool-response-bytes",
            ])

    def _write_plain_contract_fixture(
        self,
        *,
        temperature: float | None = 0.0,
        model: str | None = None,
        implementation: str | None = None,
        request_interval: float = 0.0,
    ) -> Path:
        payload = json.loads(HANDOFF_PLAIN.read_text(encoding="utf-8"))
        limits = payload["execution"]["limits"]
        limits.update({
            "wallTimeoutSeconds": 300.0,
            "liveProxyTimeoutSeconds": 120.0,
            "minimumStartIntervalSeconds": 300.0,
            "minimumRequestIntervalSeconds": request_interval,
        })
        if temperature is None:
            limits.pop("temperature", None)
        else:
            limits["temperature"] = temperature
        if model is not None:
            payload["execution"]["model"] = model
        if implementation is not None:
            payload["benchmark"]["implementationSha256"] = implementation
            payload["candidate"]["controlImplementationSha256"] = implementation
        payload["runID"] = hashlib.sha256(canonical_json({
            "candidate": payload["candidate"]["id"],
            "controlImplementationSha256": payload["candidate"][
                "controlImplementationSha256"
            ],
            "episodes": [episode["id"] for episode in payload["episodes"]],
            "model": payload["execution"]["model"],
            "startedAt": payload["execution"]["startedAt"],
        })).hexdigest()[:32]
        path = Path(self.temporary.name) / (
            "plain-contract-" + hashlib.sha256(canonical_json(payload)).hexdigest()[:12]
            + ".json"
        )
        path.write_bytes(canonical_json(payload))
        self.assertTrue(validate_bytes(path.read_bytes())["valid"])
        return path

    def _write_margin_contract_fixture(self) -> Path:
        payload = json.loads(HANDOFF_MARGIN.read_text(encoding="utf-8"))
        payload["execution"]["limits"].update({
            "wallTimeoutSeconds": 300.0,
            "liveProxyTimeoutSeconds": 120.0,
            "minimumStartIntervalSeconds": 300.0,
            "minimumRequestIntervalSeconds": 0.0,
        })
        path = Path(self.temporary.name) / "margin-contract.json"
        path.write_bytes(canonical_json(payload))
        self.assertTrue(validate_bytes(path.read_bytes())["valid"])
        return path

    def test_real_pair_requires_complete_matching_experiment_contract(self) -> None:
        complete = self._write_plain_contract_fixture()
        margin = self._write_margin_contract_fixture()
        matched = build_efficiency_report([margin, complete])["matchedEpisodes"][0]
        self.assertEqual(matched["contractStatus"], "matched")
        self.assertEqual(matched["contractDifferences"], [])
        self.assertEqual(matched["contractMissingFields"], [])

        legacy = build_efficiency_report([HANDOFF_MARGIN, HANDOFF_PLAIN])[
            "matchedEpisodes"
        ][0]
        self.assertEqual(legacy["contractStatus"], "insufficient-metadata")
        self.assertEqual(legacy["contractDifferences"], [])
        self.assertEqual(legacy["contractMissingFields"], [
            "live-proxy-timeout-seconds",
            "minimum-start-interval-seconds",
            "temperature",
            "wall-timeout-seconds",
        ])

    def test_contract_mismatches_are_named_without_exposing_values(self) -> None:
        margin = self._write_margin_contract_fixture()
        cases = (
            (self._write_plain_contract_fixture(temperature=0.5), "temperature"),
            (self._write_plain_contract_fixture(model="different/model"), "model"),
            (self._write_plain_contract_fixture(implementation="0" * 64),
             "benchmark-implementation"),
            (
                self._write_plain_contract_fixture(request_interval=6.0),
                "minimum-request-interval-seconds",
            ),
        )
        for path, expected_field in cases:
            with self.subTest(field=expected_field):
                report = build_efficiency_report([margin, path])
                match = report["matchedEpisodes"][0]
                self.assertEqual(match["contractStatus"], "mismatch")
                self.assertIn(expected_field, match["contractDifferences"])
                rendered = canonical_json(match).decode("utf-8")
                self.assertNotIn("different/model", rendered)

    def test_sources_are_digest_bound_bounded_and_path_free(self) -> None:
        report = self.build()
        neutral_source = next(
            item for item in report["sources"]
            if item["schema"] == "urn:marginbench:neutral-served-preflight:v1"
        )
        raw = self.neutral_path.read_bytes()
        self.assertEqual(neutral_source["sha256"], hashlib.sha256(raw).hexdigest())
        self.assertEqual(neutral_source["byteCount"], len(raw))
        rendered = canonical_json(report).decode("utf-8")
        self.assertNotIn(str(self.neutral_path), rendered)
        with self.assertRaisesRegex(ValueError, "unique artifacts"):
            build_efficiency_report([self.neutral_path, self.neutral_path])

    def test_semantic_tampering_fails_closed(self) -> None:
        report = self.build()
        mutations = []

        changed_group = copy.deepcopy(report)
        changed_group["groups"][0]["totalToolRoundTrips"] += 1
        mutations.append(changed_group)

        changed_match = copy.deepcopy(report)
        changed_match["matchedEpisodes"][0]["comparisonStatus"] = "resource-vector-only"
        mutations.append(changed_match)

        changed_contract = copy.deepcopy(report)
        changed_contract["matchedEpisodes"][0]["contractStatus"] = "matched"
        mutations.append(changed_contract)

        changed_evidence = copy.deepcopy(report)
        evidence = changed_evidence["observations"][0]["comparisonContract"]
        evidence["complete"] = not evidence["complete"]
        mutations.append(changed_evidence)

        changed_missing = copy.deepcopy(report)
        changed_missing["observations"][0]["missingMeasurements"] = []
        mutations.append(changed_missing)

        duplicated_source = copy.deepcopy(report)
        duplicated_source["sources"][1]["sha256"] = duplicated_source["sources"][0]["sha256"]
        mutations.append(duplicated_source)

        scalar_claim = copy.deepcopy(report)
        scalar_claim["scalarRankingPermitted"] = True
        mutations.append(scalar_claim)

        changed_rule = copy.deepcopy(report)
        changed_rule["rules"][0] = "Declare the fastest observation the winner."
        mutations.append(changed_rule)

        for mutation in mutations:
            with self.subTest(mutation=mutations.index(mutation)):
                self.assertFalse(validate_bytes(canonical_json(mutation))["valid"])

    def test_cli_emits_the_same_valid_report(self) -> None:
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            status = main([
                "efficiency-report",
                str(self.neutral_path),
                str(ROLE_RUN),
                str(CONTINUING_RUN),
            ])
        self.assertEqual(status, 0)
        report = json.loads(output.getvalue())
        self.assertEqual(report, self.build())
        self.assertTrue(validate_bytes(canonical_json(report))["valid"])


if __name__ == "__main__":
    unittest.main()
