from __future__ import annotations

import copy
import json
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

from marginbench.controls import planned_topology
from marginbench.budget_proxy import InferenceBudgetGate, InferenceBudgetPolicy
from marginbench.efficiency import build_efficiency_report
from marginbench.entropy import PUBLIC_DEVELOPMENT_KEY
from marginbench.scenarios import generate_episode
from marginbench.schema import canonical_json
from marginbench.validation import validate_bytes
from prime_pilot import (
    _neutral_execution_summary,
    _neutral_run_manifest,
    _summarize_neutral_traces,
)


PACKAGE_ROOT = Path(__file__).resolve().parents[1]
ROLE_RUN = (
    PACKAGE_ROOT / "results" / "crossover" / "v17" / "cells"
    / "0001-parallel-shards-role-5cdfb0a164.run.json"
)


def assessment() -> dict[str, object]:
    episode = generate_episode("parallel_shards", PUBLIC_DEVELOPMENT_KEY, 0)
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
    topology = planned_topology(
        "role-separated-plain-markdown-v1",
        [role.seat for role in episode.roles],
    )
    return {
        "episodeID": episode.public_id,
        "implementedChecksPassed": True,
        "safetyPassed": True,
        "sourcePreserved": True,
        "durationMs": 123.5,
        "checks": checks,
        "dimensions": {
            "outcome": 100,
            "integrity": 100,
            "attribution": 100,
            "continuity": 100,
            "recovery": 100,
        },
        "efficiencyObservations": {
            "toolCallCount": 8,
            "failedToolCallCount": 1,
            "requestByteCount": 1200,
            "responseByteCount": 3400,
            "toolDurationMicroseconds": 12500,
            "actionCounts": {
                "guide": 2,
                "list": 0,
                "read": 4,
                "write": 1,
                "invalid": 1,
            },
            "modelCallCount": 6,
            "inputTokenCount": 1000,
            "outputTokenCount": 200,
            "costUSD": None,
            "scalarScore": None,
        },
        "controlProfile": "role-separated-plain-markdown-v1",
        "logicalActors": [
            {
                "seat": role.seat,
                "phase": role.phase,
                "id": role.actor.id,
                "name": role.actor.name,
                "type": role.actor.type,
            }
            for role in episode.roles
        ],
        **topology,
    }


def trace_summary() -> dict[str, object]:
    episode = generate_episode("parallel_shards", PUBLIC_DEVELOPMENT_KEY, 0)
    value = assessment()
    return {
        "traceCount": 2,
        "episodeCount": 1,
        "traceConsistencyPassed": True,
        "episodes": [{
            "episodeID": episode.public_id,
            "scenario": episode.scenario_id,
            "repetition": episode.repetition,
            "fingerprint": episode.fingerprint,
            **value,
            "roleRuns": [
                {
                    "seat": "author",
                    "stopCondition": "agent_completed",
                    "usage": {
                        "modelCalls": 3,
                        "promptTokens": 500,
                        "completionTokens": 100,
                        "cachedInputTokens": 50,
                        "reasoningTokens": 25,
                        "reportedCostUSD": 0.001,
                    },
                },
                {
                    "seat": "reviewer",
                    "stopCondition": "agent_completed",
                    "usage": {
                        "modelCalls": 3,
                        "promptTokens": 500,
                        "completionTokens": 100,
                        "cachedInputTokens": 50,
                        "reasoningTokens": 25,
                        "reportedCostUSD": 0.001,
                    },
                },
            ],
            "usage": {
                "modelCalls": 6,
                "promptTokens": 1000,
                "completionTokens": 200,
                "cachedInputTokens": 100,
                "reasoningTokens": 50,
                "reportedCostUSD": 0.002,
            },
        }],
    }


def arguments() -> SimpleNamespace:
    return SimpleNamespace(
        scenario=["parallel_shards"],
        repetitions=1,
        repetition_id=[],
        max_turns=8,
        temperature=0.0,
        upstream_attempts_per_turn=1,
        input_token_ceiling_per_call=100_000,
        max_tokens_per_call=1_200,
        provider_response_token_allowance=8,
        input_price_per_million=0.03,
        output_price_per_million=0.13,
        billing_overhead_usd_per_call=0.0002,
        control_profile="role-separated-plain-markdown-v1",
        candidate="plain-markdown-control-v1",
        model="marginbench-fake",
        holdout_key_file=None,
        max_concurrent=1,
        max_input_tokens=40_000,
        max_output_tokens=6_000,
        max_total_tokens=16_000,
        rollout_timeout_seconds=120.0,
        wall_timeout_seconds=300.0,
        live_proxy_timeout_seconds=120.0,
        minimum_start_interval_seconds=300.0,
        prior_infrastructure_attempts=0,
        max_cost_usd=2.0,
    )


class NeutralRunTests(unittest.TestCase):
    def test_trace_aggregation_reads_the_non_scalar_info_channel(self) -> None:
        episode = generate_episode("parallel_shards", PUBLIC_DEVELOPMENT_KEY, 0)
        common = assessment()
        traces = []
        for seat in ("author", "reviewer"):
            traces.append({
                "task": {"data": {
                    "name": f"{episode.public_id}:{seat}",
                    "scenario_id": episode.scenario_id,
                    "repetition": episode.repetition,
                    "fingerprint": episode.fingerprint,
                }},
                "info": {"marginbenchNeutral": common},
                "stop_condition": "agent_completed",
                "calls": [{"usage": {
                    "prompt_tokens": 500,
                    "completion_tokens": 100,
                    "cached_input_tokens": 50,
                    "reasoning_tokens": 25,
                    "cost": 0.001,
                }}],
            })
        with tempfile.TemporaryDirectory(prefix="marginbench-neutral-run-") as temporary:
            root = Path(temporary)
            (root / "traces.jsonl").write_text(
                json.dumps({"traces": traces}) + "\n",
                encoding="utf-8",
            )
            summary = _summarize_neutral_traces(root)
        self.assertTrue(summary["traceConsistencyPassed"])
        self.assertEqual(summary["traceCount"], 2)
        self.assertEqual(summary["episodeCount"], 1)
        self.assertEqual(summary["episodes"][0]["usage"]["modelCalls"], 2)
        self.assertEqual(summary["episodes"][0]["usage"]["reportedCostUSD"], 0.002)

    def test_manifest_is_valid_source_bound_and_has_no_scalar_score(self) -> None:
        manifest = _neutral_run_manifest(
            arguments(),
            trace_summary(),
            status="completed",
            started_at="2026-08-19T07:00:00Z",
            duration_ms=500,
            observed_wallet_debit=0.002,
        )
        receipt = validate_bytes(canonical_json(manifest))
        self.assertTrue(receipt["valid"], receipt["errors"])
        self.assertFalse(manifest["scalarRankingPermitted"])
        self.assertNotIn("score", manifest["episodes"][0])
        self.assertFalse(manifest["execution"]["marginBinaryUsed"])
        self.assertEqual(manifest["execution"]["limits"]["temperature"], 0.0)
        self.assertEqual(manifest["episodes"][0]["toolRoundTrips"]["failedCount"], 1)

        changed = copy.deepcopy(manifest)
        changed["episodes"][0]["dimensions"]["outcome"] = 99
        self.assertFalse(validate_bytes(canonical_json(changed))["valid"])

        changed = copy.deepcopy(manifest)
        changed["candidate"]["controlImplementationSha256"] = "0" * 64
        self.assertFalse(validate_bytes(canonical_json(changed))["valid"])

    def test_real_plain_and_margin_cells_share_a_vector_but_never_a_winner(self) -> None:
        manifest = _neutral_run_manifest(
            arguments(),
            trace_summary(),
            status="completed",
            started_at="2026-08-19T07:00:00Z",
            duration_ms=500,
            observed_wallet_debit=0.002,
        )
        with tempfile.TemporaryDirectory(prefix="marginbench-neutral-vector-") as temporary:
            path = Path(temporary) / "neutral-run.json"
            path.write_bytes(canonical_json(manifest))
            report = build_efficiency_report([path, ROLE_RUN])
        self.assertTrue(validate_bytes(canonical_json(report))["valid"])
        self.assertEqual(report["observationCount"], 2)
        self.assertEqual(report["matchedEpisodes"][0]["comparisonStatus"], "resource-vector-only")
        self.assertIsNone(report["matchedEpisodes"][0]["winner"])
        plain = next(
            item for item in report["observations"]
            if item["controlProfile"] == "role-separated-plain-markdown-v1"
        )
        self.assertEqual(plain["missingMeasurements"], [])
        self.assertEqual(plain["toolRoundTrips"]["requestBytes"], 1200)

    def test_prime_summary_keeps_wallet_budget_and_neutral_results_non_scalar(self) -> None:
        policy = InferenceBudgetPolicy(
            allowed_model="marginbench-fake",
            max_request_bytes=1_048_576,
            template_token_allowance=8_192,
            input_token_ceiling=100_000,
            max_output_tokens=1_200,
            input_price_per_million=0.03,
            output_price_per_million=0.13,
            billing_overhead_usd_per_call=0.0002,
            max_total_cost_usd=2.0,
            response_token_allowance=8,
        )
        live_budget = InferenceBudgetGate(policy).report()
        summary = _neutral_execution_summary(
            arguments(),
            trace_summary(),
            status="completed",
            duration_ms=500,
            exit_code=0,
            wallet_before={"balanceUSD": 10.0, "totalBillings": 2},
            wallet_after={"balanceUSD": 9.998, "totalBillings": 3},
            observed_wallet_debit=0.002,
            estimated_maximum_cost=2.0,
            contract_maximum_cost=3.0,
            live_budget_cap=2.0,
            live_budget=live_budget,
            infrastructure_codes=[],
        )
        receipt = validate_bytes(canonical_json(summary))
        self.assertTrue(receipt["valid"], receipt["errors"])
        self.assertFalse(summary["scalarRankingPermitted"])
        self.assertNotIn("score", summary["episodes"][0])

        changed = copy.deepcopy(summary)
        changed["wallet"]["observedDebitUSD"] = 0.003
        self.assertFalse(validate_bytes(canonical_json(changed))["valid"])


if __name__ == "__main__":
    unittest.main()
