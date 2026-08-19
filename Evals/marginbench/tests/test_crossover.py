from __future__ import annotations

import json
import tempfile
import unittest
from dataclasses import replace
from pathlib import Path

from marginbench.binary import resolve_margin_binary
from marginbench.challenges import DEMAND_AXES, challenge_catalog, challenge_profile
from marginbench.crossover import (
    CONTINUING_PROFILE,
    ROLE_SEPARATED_PROFILE,
    CrossoverMeasurement,
    analyze_crossover,
    build_crossover_plan,
    load_crossover_evidence,
    load_crossover_evidence_set,
    load_crossover_measurements,
    reference_experiment_contract,
)
from marginbench.entropy import PUBLIC_DEVELOPMENT_KEY
from marginbench.runner import ReferenceDriver, run_episode
from marginbench.scenarios import SCENARIO_IDS, generate_episode
from marginbench.schema import canonical_json
from marginbench.validation import validate_bytes


PACKAGE_ROOT = Path(__file__).resolve().parents[1]
REPOSITORY_ROOT = PACKAGE_ROOT.parent.parent
LOCAL_BINARY = REPOSITORY_ROOT / "build" / "margin"


def available_binary() -> Path | None:
    if LOCAL_BINARY.is_file():
        return LOCAL_BINARY
    try:
        return resolve_margin_binary()
    except ValueError:
        return None


def measurement(
    repetition: int,
    profile: str,
    *,
    duration_ms: float,
    score: float = 100.0,
    candidate: str = "crossover-test",
    margin_sha256: str = "0" * 64,
) -> CrossoverMeasurement:
    fingerprint = generate_episode(
        "parallel_shards",
        PUBLIC_DEVELOPMENT_KEY,
        repetition,
    ).fingerprint
    return CrossoverMeasurement(
        episode_id=f"parallel_shards:{repetition}:{fingerprint[:12]}",
        scenario="parallel_shards",
        repetition=repetition,
        fingerprint=fingerprint,
        candidate_id=candidate,
        control_profile=profile,
        score=score,
        duration_ms=duration_ms,
        command_count=6,
        invalid_command_count=0,
        safety_passed=True,
        source_preserved=True,
        margin_sha256=margin_sha256,
        dimensions={
            "outcome": score,
            "integrity": 100.0,
            "protocol": 100.0,
            "recovery": 100.0,
            "efficiency": 100.0,
        },
        checks={
            "all_expected_annotations": score == 100.0,
            "source_expected": True,
            "valid_documents": True,
        },
    )


class CollaborationCrossoverTests(unittest.TestCase):
    def test_challenge_catalog_covers_every_scenario_and_axis(self) -> None:
        catalog = challenge_catalog()
        receipt = validate_bytes(canonical_json(catalog))
        self.assertTrue(receipt["valid"], receipt)
        self.assertEqual(
            [item["scenario"] for item in catalog["challenges"]],
            list(SCENARIO_IDS),
        )
        self.assertEqual([axis["id"] for axis in catalog["axes"]], list(DEMAND_AXES))
        self.assertEqual(challenge_profile("agent_agent_handoff").hypothesis, "continuing-favored")
        self.assertEqual(challenge_profile("parallel_shards").demand["coupling"], 0)

        tampered = json.loads(canonical_json(catalog))
        tampered["challenges"][0]["demand"]["parallelism"] = 4
        self.assertFalse(validate_bytes(canonical_json(tampered))["valid"])

    def test_every_case_is_deterministic_keyed_and_publicly_redacted(self) -> None:
        alternate = b"marginbench-crossover-alternate-key-v1"
        for scenario in SCENARIO_IDS:
            first = generate_episode(scenario, PUBLIC_DEVELOPMENT_KEY, 2)
            repeated = generate_episode(scenario, PUBLIC_DEVELOPMENT_KEY, 2)
            changed = generate_episode(scenario, alternate, 2)
            self.assertEqual(first, repeated)
            self.assertNotEqual(first.fingerprint, changed.fingerprint)
            public = json.dumps(first.public_manifest(), sort_keys=True)
            self.assertNotIn("oracle", public)
            self.assertNotIn("prompt", public)
            self.assertNotIn("files", public)

    def test_crossover_plan_is_paired_balanced_budgeted_and_valid(self) -> None:
        plan = build_crossover_plan(
            candidate="reference",
            scenarios=list(SCENARIO_IDS),
            repetitions=3,
            key=PUBLIC_DEVELOPMENT_KEY,
            development_cases=True,
        )
        self.assertEqual(plan["episodeCount"], 27)
        self.assertTrue(plan["sampleSizeSufficient"])
        self.assertGreater(
            plan["agentProcessesPerProfile"][ROLE_SEPARATED_PROFILE],
            plan["agentProcessesPerProfile"][CONTINUING_PROFILE],
        )
        self.assertEqual(
            plan["agentProcessesPerProfile"][CONTINUING_PROFILE],
            plan["episodeCount"],
        )
        scheduled_scenarios = [item["scenario"] for item in plan["episodes"]]
        self.assertNotEqual(scheduled_scenarios, sorted(scheduled_scenarios))
        self.assertGreater(len(set(scheduled_scenarios[:9])), 1)
        orders = [tuple(item["profileOrder"]) for item in plan["episodes"]]
        forward = orders.count((ROLE_SEPARATED_PROFILE, CONTINUING_PROFILE))
        reverse = orders.count((CONTINUING_PROFILE, ROLE_SEPARATED_PROFILE))
        self.assertLessEqual(abs(forward - reverse), 1)
        for scenario in SCENARIO_IDS:
            scenario_orders = [
                tuple(item["profileOrder"])
                for item in plan["episodes"]
                if item["scenario"] == scenario
            ]
            self.assertLessEqual(
                abs(
                    scenario_orders.count((ROLE_SEPARATED_PROFILE, CONTINUING_PROFILE))
                    - scenario_orders.count((CONTINUING_PROFILE, ROLE_SEPARATED_PROFILE))
                ),
                1,
            )
        self.assertTrue(validate_bytes(canonical_json(plan))["valid"])

        private_contract = reference_experiment_contract(
            "reference",
            "0" * 64,
            task_set="private-holdout-v1",
            development_cases=False,
        )
        self.assertEqual(private_contract["benchmark"]["taskSet"], "private-holdout-v1")
        with self.assertRaisesRegex(ValueError, "partition"):
            reference_experiment_contract(
                "reference",
                "0" * 64,
                task_set="public-development-v1",
                development_cases=False,
            )

        tampered = json.loads(canonical_json(plan))
        tampered["logicalRoleRunsPerProfile"] += 1
        self.assertFalse(validate_bytes(canonical_json(tampered))["valid"])

        changed_policy = json.loads(canonical_json(plan))
        changed_policy["minimumPairsForDirectionalClaim"] = 2
        changed_policy["rules"]["meaningfulSpeedRatio"] = 1.01
        self.assertFalse(validate_bytes(canonical_json(changed_policy))["valid"])

    def test_analysis_recovers_a_known_speed_crossover_without_blending_quality(self) -> None:
        plan = build_crossover_plan(
            candidate="crossover-test",
            scenarios=["parallel_shards"],
            repetitions=20,
            key=PUBLIC_DEVELOPMENT_KEY,
            development_cases=True,
        )
        separated = [
            measurement(index, ROLE_SEPARATED_PROFILE, duration_ms=50.0)
            for index in range(20)
        ]
        continuing = [
            measurement(index, CONTINUING_PROFILE, duration_ms=100.0)
            for index in range(20)
        ]
        report = analyze_crossover(
            separated,
            continuing,
            analysis_mode="model-free-reference",
            plan=plan,
            experiment_contract=reference_experiment_contract(
                "crossover-test",
                "0" * 64,
            ),
        )
        self.assertEqual(report["overall"]["directionalConclusion"], "role-separated")
        self.assertEqual(report["overall"]["meanScoreDelta"], 0.0)
        self.assertEqual(report["overall"]["meanSpeedRatio"], 2.0)
        self.assertEqual(report["overall"]["leaderCounts"]["role-separated"], 20)
        self.assertEqual(report["overall"]["meanDimensionDeltas"]["outcome"], 0.0)
        self.assertEqual(report["overall"]["meanModelCallsDelta"], 0.0)
        self.assertEqual(report["overall"]["meanCachedInputTokensDelta"], 0.0)
        receipt = validate_bytes(canonical_json(report))
        self.assertTrue(receipt["valid"], receipt)

        tampered = json.loads(canonical_json(report))
        tampered["overall"]["meanSpeedRatio"] = 9.0
        self.assertFalse(validate_bytes(canonical_json(tampered))["valid"])

        wrong_partition = reference_experiment_contract(
            "crossover-test",
            "0" * 64,
            task_set="private-holdout-v1",
            development_cases=False,
        )
        with self.assertRaisesRegex(ValueError, "case partition"):
            analyze_crossover(
                separated,
                continuing,
                analysis_mode="model-free-reference",
                plan=plan,
                experiment_contract=wrong_partition,
            )

    def test_analysis_treats_scenario_specific_diagnostics_as_not_applicable(self) -> None:
        plan = build_crossover_plan(
            candidate="crossover-test",
            scenarios=["parallel_shards"],
            repetitions=2,
            key=PUBLIC_DEVELOPMENT_KEY,
            development_cases=True,
        )
        separated = [
            measurement(index, ROLE_SEPARATED_PROFILE, duration_ms=50.0)
            for index in range(2)
        ]
        continuing = [
            measurement(index, CONTINUING_PROFILE, duration_ms=50.0)
            for index in range(2)
        ]
        separated[0] = replace(
            separated[0],
            checks={**separated[0].checks, "diagnostic_first": False},
        )
        separated[1] = replace(
            separated[1],
            checks={**separated[1].checks, "diagnostic_second": False},
        )
        continuing[0] = replace(
            continuing[0],
            checks={**continuing[0].checks, "diagnostic_first": True},
        )
        continuing[1] = replace(
            continuing[1],
            checks={**continuing[1].checks, "diagnostic_second": True},
        )
        report = analyze_crossover(
            separated,
            continuing,
            analysis_mode="model-free-reference",
            plan=plan,
            experiment_contract=reference_experiment_contract(
                "crossover-test",
                "0" * 64,
            ),
        )
        failed = report["overall"]["roleSeparatedFailedCheckCounts"]
        self.assertEqual(failed["diagnostic_first"], 1)
        self.assertEqual(failed["diagnostic_second"], 1)
        self.assertEqual(report["overall"]["continuingFailedCheckCounts"]["diagnostic_first"], 0)

    def test_small_samples_remain_descriptive_and_pair_mismatch_fails_closed(self) -> None:
        plan = build_crossover_plan(
            candidate="crossover-test",
            scenarios=["parallel_shards"],
            repetitions=3,
            key=PUBLIC_DEVELOPMENT_KEY,
            development_cases=True,
        )
        separated = [
            measurement(index, ROLE_SEPARATED_PROFILE, duration_ms=50.0)
            for index in range(3)
        ]
        continuing = [
            measurement(index, CONTINUING_PROFILE, duration_ms=100.0)
            for index in range(3)
        ]
        report = analyze_crossover(
            separated,
            continuing,
            analysis_mode="measured-model",
            plan=plan,
            experiment_contract={
                **reference_experiment_contract("crossover-test", "0" * 64),
                "mode": "measured-model",
            },
        )
        self.assertEqual(report["overall"]["descriptiveLeader"], "role-separated")
        self.assertEqual(report["overall"]["directionalConclusion"], "insufficient-data")
        mismatched = list(continuing)
        mismatched[0] = measurement(
            0,
            CONTINUING_PROFILE,
            duration_ms=100.0,
            candidate="different-candidate",
        )
        with self.assertRaisesRegex(ValueError, "same candidate"):
            analyze_crossover(
                separated,
                mismatched,
                analysis_mode="measured-model",
                plan=plan,
                experiment_contract={
                    **reference_experiment_contract("crossover-test", "0" * 64),
                    "mode": "measured-model",
                },
            )

    def test_quality_claim_must_clear_the_meaningful_threshold_not_only_zero(self) -> None:
        plan = build_crossover_plan(
            candidate="crossover-test",
            scenarios=["parallel_shards"],
            repetitions=20,
            key=PUBLIC_DEVELOPMENT_KEY,
            development_cases=True,
        )
        separated = [
            measurement(index, ROLE_SEPARATED_PROFILE, duration_ms=100.0)
            for index in range(20)
        ]
        continuing = [
            measurement(
                index,
                CONTINUING_PROFILE,
                duration_ms=100.0,
                score=99.0 if index < 15 else 91.0,
            )
            for index in range(20)
        ]
        report = analyze_crossover(
            separated,
            continuing,
            analysis_mode="model-free-reference",
            plan=plan,
            experiment_contract=reference_experiment_contract(
                "crossover-test",
                "0" * 64,
            ),
        )
        self.assertEqual(report["overall"]["meanScoreDelta"], 3.0)
        self.assertLessEqual(report["overall"]["scoreDelta95CI"][0], 2.0)
        self.assertEqual(report["overall"]["descriptiveLeader"], "role-separated")
        self.assertEqual(report["overall"]["directionalConclusion"], "inconclusive")

    def test_reference_policy_runs_both_topologies_on_the_same_real_case(self) -> None:
        binary = available_binary()
        if binary is None:
            self.skipTest("Build Margin or install the packaged benchmark binary first.")
        episode = generate_episode("parallel_shards", PUBLIC_DEVELOPMENT_KEY, 0)
        results = {}
        for profile in (ROLE_SEPARATED_PROFILE, CONTINUING_PROFILE):
            with tempfile.TemporaryDirectory(prefix="marginbench-crossover-test-") as temporary:
                results[profile] = run_episode(
                    episode,
                    binary,
                    Path(temporary) / "workspace",
                    ReferenceDriver(),
                    candidate_id="reference",
                    control_profile=profile,
                )
            self.assertEqual(results[profile].score, 100.0)
            self.assertTrue(results[profile].safety_passed)
        report = analyze_crossover(
            [CrossoverMeasurement.from_result(
                results[ROLE_SEPARATED_PROFILE],
                scenario=episode.scenario_id,
                repetition=episode.repetition,
                fingerprint=episode.fingerprint,
                control_profile=ROLE_SEPARATED_PROFILE,
            )],
            [CrossoverMeasurement.from_result(
                results[CONTINUING_PROFILE],
                scenario=episode.scenario_id,
                repetition=episode.repetition,
                fingerprint=episode.fingerprint,
                control_profile=CONTINUING_PROFILE,
            )],
            analysis_mode="model-free-reference",
            plan=build_crossover_plan(
                candidate="reference",
                scenarios=["parallel_shards"],
                repetitions=1,
                key=PUBLIC_DEVELOPMENT_KEY,
                development_cases=True,
            ),
            experiment_contract=reference_experiment_contract(
                "reference",
                results[ROLE_SEPARATED_PROFILE].margin_sha256,
            ),
        )
        self.assertTrue(validate_bytes(canonical_json(report))["valid"])

    def test_crossover_loader_rejects_an_infrastructure_error_as_evidence(self) -> None:
        artifact = (
            PACKAGE_ROOT
            / "results"
            / "topology-agent-handoff-continuing-v2-public-r0-run.json"
        )
        self.assertTrue(artifact.is_file())
        with self.assertRaisesRegex(ValueError, "infrastructure-invalid"):
            load_crossover_measurements(artifact)

        recovered = (
            PACKAGE_ROOT
            / "results"
            / "topology-agent-handoff-role-separated-v2-public-r0-run.json"
        )
        with self.assertRaisesRegex(ValueError, "recovered infrastructure"):
            load_crossover_evidence(recovered)

        clean = (
            PACKAGE_ROOT
            / "results"
            / "topology-agent-handoff-role-separated-public-r0-run.json"
        )
        evidence = load_crossover_evidence(clean)
        self.assertEqual(len(evidence.measurements), 1)
        self.assertEqual(evidence.experiment_contract["mode"], "measured-model")
        encoded = json.dumps(evidence.experiment_contract, sort_keys=True)
        self.assertNotIn("controlProfile", encoded)
        self.assertNotIn("agentProcessCount", encoded)
        self.assertNotIn("startedAt", encoded)

        combined = load_crossover_evidence_set([clean])
        self.assertEqual(combined, evidence)
        with self.assertRaisesRegex(ValueError, "duplicate episode IDs"):
            load_crossover_evidence_set([clean, clean])
        with self.assertRaisesRegex(ValueError, "at least one"):
            load_crossover_evidence_set([])

    def test_crossover_loader_allows_scenario_defined_roles(self) -> None:
        clean = (
            PACKAGE_ROOT
            / "results"
            / "topology-agent-handoff-role-separated-public-r0-run.json"
        )
        original = json.loads(clean.read_text(encoding="utf-8"))
        reviewer_only = json.loads(json.dumps(original))
        reviewer_only["execution"]["roles"] = ["reviewer"]
        reviewer_only["execution"]["agentProcessCount"] = 1
        reviewer_only["execution"]["traceSeats"] = ["reviewer"]
        reviewer_only["cost"]["contractBound"] /= 2
        episode = reviewer_only["episodes"][0]
        episode["fingerprint"] = "1" * 64
        episode["id"] = f"{episode['scenario']}:{episode['repetition']}:{'1' * 12}"
        episode["logicalActors"] = [
            actor for actor in episode["logicalActors"] if actor["seat"] == "reviewer"
        ]
        episode["agentProcessCount"] = 1
        episode["traceSeats"] = ["reviewer"]

        with tempfile.TemporaryDirectory() as raw:
            altered = Path(raw) / "reviewer-only.run.json"
            altered.write_bytes(canonical_json(reviewer_only) + b"\n")
            combined = load_crossover_evidence_set([clean, altered])

        self.assertEqual(
            combined.experiment_contract["execution"]["roles"],
            ["author", "reviewer"],
        )
        self.assertEqual(len(combined.measurements), 2)


if __name__ == "__main__":
    unittest.main()
