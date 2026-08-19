from __future__ import annotations

import argparse
import json
import subprocess
import tempfile
import unittest
from dataclasses import asdict
from pathlib import Path

from crossover_pilot import (
    _child_command,
    _job_paths,
    _validate_job_outputs,
    build_crossover_prime_plan,
    execute_study,
    wait_until_paid_start_allowed,
)
from marginbench.candidates import CandidateManifest
from marginbench.crossover import build_crossover_plan
from marginbench.entropy import PUBLIC_DEVELOPMENT_KEY
from marginbench.prime_study import PrimeStudyError
from marginbench.provenance import implementation_sha256
from marginbench.schema import canonical_json
from marginbench.validation import validate_artifact, validate_bytes


PACKAGE_ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = PACKAGE_ROOT.parent.parent
BINARY = REPOSITORY / "build" / "margin"
EVIDENCE_URL = "https://help.aliyun.com/zh/model-studio/text-generation-model/"


def limits() -> dict[str, object]:
    return {
        "maxTurns": 8,
        "maxInputTokens": 40_000,
        "maxOutputTokens": 6_000,
        "maxTotalTokens": 16_000,
        "inputTokenCeilingPerCall": 1_000_000,
        "inputTokenCeilingSource": EVIDENCE_URL,
        "upstreamAttemptsPerTurn": 3,
        "maxTokensPerCall": 1_800,
        "providerResponseTokenAllowance": 8,
        "maxConcurrent": 1,
        "rolloutTimeoutSeconds": 180.0,
        "wallTimeoutSeconds": 300.0,
        "liveProxyTimeoutSeconds": 120.0,
        "minimumStartIntervalSeconds": 300.0,
        "minimumRequestIntervalSeconds": 6.0,
        "temperature": 0.0,
        "liveProxyMaxRequestBytes": 1_048_576,
        "liveProxyTemplateTokenAllowance": 8_192,
    }


def pricing() -> dict[str, object]:
    return {
        "inputPricePerMillion": 0.03,
        "outputPricePerMillion": 0.13,
        "billingOverheadUSDPerCall": 0.0002,
        "source": EVIDENCE_URL,
    }


class CrossoverPilotTests(unittest.TestCase):
    def setUp(self) -> None:
        if not BINARY.is_file():
            self.skipTest("Build Margin before running crossover controller tests.")

    def _plan(self, root: Path) -> tuple[dict, Path, Path]:
        manual = root / "manual.txt"
        manual.write_text("Test manual\n", encoding="utf-8")
        candidate = CandidateManifest.create(
            "test-crossover-controller",
            BINARY,
            manual=manual,
            settings={"change": "test"},
        )
        candidate_path = root / "candidate.json"
        candidate_path.write_bytes(canonical_json(asdict(candidate)))
        crossover = build_crossover_plan(
            candidate=candidate.id,
            scenarios=["specialist_audit", "parallel_shards"],
            repetitions=1,
            key=PUBLIC_DEVELOPMENT_KEY,
            development_cases=True,
        )
        crossover_path = root / "crossover-plan.json"
        crossover_path.write_bytes(canonical_json(crossover))
        plan = build_crossover_prime_plan(
            crossover_plan=crossover_path,
            candidate_manifest=candidate_path,
            candidate_binary=BINARY,
            model="qwen/qwen3.7-flash",
            limits=limits(),
            pricing=pricing(),
            live_proxy_cap_per_cell_usd=0.03,
            hard_study_cap_usd=0.12,
            minimum_wallet_reserve_usd=80.0,
            package_root=PACKAGE_ROOT,
            track="team",
        )
        return plan, candidate_path, crossover_path

    @staticmethod
    def _value(command: list[str], name: str) -> str:
        return command[command.index(name) + 1]

    def _fake_child(self, plan: dict):
        def run(command: list[str], **_: object) -> subprocess.CompletedProcess:
            scenario = self._value(command, "--scenario")
            repetition = int(self._value(command, "--repetition-id"))
            profile = self._value(command, "--control-profile")
            job = next(
                value
                for value in plan["jobs"]
                if value["scenario"] == scenario
                and value["repetition"] == repetition
                and value["controlProfile"] == profile
            )
            raw_path = Path(self._value(command, "--output-dir"))
            summary_path = Path(self._value(command, "--summary-file"))
            run_path = Path(self._value(command, "--run-manifest-file"))
            usage = {
                "modelCalls": 0,
                "promptTokens": 0,
                "completionTokens": 0,
                "cachedInputTokens": 0,
                "reasoningTokens": 0,
                "reportedCostUSD": 0.0,
            }
            checks = {
                "all_expected_annotations": True,
                "all_or_none": True,
                "attribution": True,
                "committed_all": True,
                "duplicate_free": True,
                "minimum_annotations": True,
                "no_unexpected_annotations": True,
                "required_commands": True,
                "required_recovery_observed": True,
                "source_expected": True,
                "valid_command_use": True,
                "valid_documents": True,
                "workspace_policy": True,
            }
            dimensions = {
                "efficiency": 100.0,
                "integrity": 100.0,
                "outcome": 100.0,
                "protocol": 100.0,
                "recovery": 100.0,
            }
            duration = 10.0 + job["ordinal"]
            episode = {
                "id": job["episodeID"],
                "scenario": scenario,
                "repetition": repetition,
                "fingerprint": job["fingerprint"],
                "score": 100.0,
                "safetyPassed": True,
                "sourcePreserved": True,
                "commandCount": 3,
                "invalidCommandCount": 0,
                "durationMs": duration,
                "marginSha256": plan["candidate"]["marginSha256"],
                "checks": checks,
                "dimensions": dimensions,
                "usage": usage,
            }
            policy = {
                "allowedModel": plan["model"],
                "maxRequestBytes": plan["limits"]["liveProxyMaxRequestBytes"],
                "templateTokenAllowance": plan["limits"]["liveProxyTemplateTokenAllowance"],
                "inputTokenCeiling": plan["limits"]["inputTokenCeilingPerCall"],
                "maxOutputTokens": plan["limits"]["maxTokensPerCall"],
                "responseTokenAllowance": plan["limits"]["providerResponseTokenAllowance"],
                "inputPricePerMillion": plan["pricing"]["inputPricePerMillion"],
                "outputPricePerMillion": plan["pricing"]["outputPricePerMillion"],
                "billingOverheadUSDPerCall": plan["pricing"]["billingOverheadUSDPerCall"],
                "maxTotalCostUSD": job["liveProxyCapUSD"],
            }
            live_budget = {
                "enabled": True,
                "forwardedRequestCount": 0,
                "grossReservedCostUpperBoundUSD": 0.0,
                "latchedClosed": False,
                "outstandingReservationCount": 0,
                "policy": policy,
                "providerBoundViolationCount": 0,
                "rejectedRequestCount": 0,
                "reportedCompletionTokens": 0,
                "reportedPromptTokens": 0,
                "reportedTokenCostUSD": 0.0,
                "reservedCostUpperBoundUSD": 0.0,
                "settledRequestCount": 0,
            }
            observed = 0.0005
            role_runs = [
                {"seat": seat, "stopCondition": "fake-reference", "usage": usage}
                for seat in job["traceSeats"]
            ]
            summary_episode = {
                **{key: value for key, value in episode.items() if key != "id"},
                "episodeID": job["episodeID"],
                "agentProcessCount": job["agentProcessCount"],
                "controlProfile": profile,
                "logicalActors": [
                    {
                        "id": f"urn:test:{seat}:{job['ordinal']}",
                        "name": seat.title(),
                        "phase": index,
                        "seat": seat,
                        "type": "software",
                    }
                    for index, seat in enumerate(job["roles"])
                ],
                "phasePolicy": job["phasePolicy"],
                "roleRuns": role_runs,
                "traceSeats": job["traceSeats"],
            }
            summary = {
                "schema": "urn:marginbench:prime-run-summary:v1",
                "status": "completed",
                "paidModelsInvoked": True,
                "model": plan["model"],
                "candidate": plan["candidate"]["id"],
                "scenarios": [scenario],
                "repetitions": 1,
                "marginSha256": plan["candidate"]["marginSha256"],
                "durationMs": round(duration),
                "exitCode": 0,
                "wallet": {
                    "before": {"balanceUSD": 200.0, "totalBillings": 0},
                    "after": {"balanceUSD": 199.9995, "totalBillings": 1},
                    "observedDebitUSD": observed,
                },
                "estimatedMaximumCostUSD": job["liveProxyCapUSD"],
                "contractMaximumCostUSD": job["contractMaximumCostUSD"],
                "liveBudgetCapUSD": job["liveProxyCapUSD"],
                "liveBudget": live_budget,
                "infrastructureCodes": [],
                "traceCount": len(role_runs),
                "episodeCount": 1,
                "traceConsistencyPassed": True,
                "episodes": [summary_episode],
                "rawTracesCommitted": False,
            }
            run_manifest = {
                "schema": "urn:marginbench:run:v1",
                "runID": f"fake-crossover-{job['ordinal']}",
                "status": "completed",
                "track": plan["track"],
                "benchmark": {
                    "name": "MarginBench",
                    "version": "0.1.0",
                    "taskSet": plan["taskSet"],
                    "developmentCases": plan["developmentCases"],
                    "implementationSha256": implementation_sha256(PACKAGE_ROOT),
                },
                "candidate": {
                    "id": plan["candidate"]["id"],
                    "marginSha256": plan["candidate"]["marginSha256"],
                    "manualSha256": plan["candidate"]["manualSha256"],
                    "settingsSha256": plan["candidate"]["settingsSha256"],
                },
                "execution": {
                    "adapter": "prime-verifiers-v1",
                    "provider": "Prime Intellect",
                    "model": plan["model"],
                    "harness": "null-with-one-margin-tool",
                    "runtime": "local-subprocess-environment-with-prime-inference",
                    "controlProfile": profile,
                    "agentProcessCount": job["agentProcessCount"],
                    "roles": job["roles"],
                    "traceSeats": job["traceSeats"],
                    "phasePolicy": job["phasePolicy"],
                    "startedAt": "2026-08-19T00:00:00Z",
                    "durationMs": duration,
                    "limits": {
                        "maxConcurrentEpisodes": 1,
                        "maxInputTokens": plan["limits"]["maxInputTokens"],
                        "maxOutputTokens": plan["limits"]["maxOutputTokens"],
                        "maxTotalTokens": plan["limits"]["maxTotalTokens"],
                        "inputTokenCeilingPerCall": plan["limits"]["inputTokenCeilingPerCall"],
                        "upstreamAttemptsPerTurn": plan["limits"]["upstreamAttemptsPerTurn"],
                        "billingOverheadUSDPerCall": plan["pricing"]["billingOverheadUSDPerCall"],
                        "maxTokensPerCall": plan["limits"]["maxTokensPerCall"],
                        "providerResponseTokenAllowance": plan["limits"]["providerResponseTokenAllowance"],
                        "maxTurns": plan["limits"]["maxTurns"],
                        "rolloutTimeoutSeconds": plan["limits"]["rolloutTimeoutSeconds"],
                        "wallTimeoutSeconds": plan["limits"]["wallTimeoutSeconds"],
                        "liveProxyTimeoutSeconds": plan["limits"]["liveProxyTimeoutSeconds"],
                        "minimumStartIntervalSeconds": plan["limits"]["minimumStartIntervalSeconds"],
                        "minimumRequestIntervalSeconds": plan["limits"]["minimumRequestIntervalSeconds"],
                        "temperature": plan["limits"]["temperature"],
                        "liveProxyMaxRequestBytes": plan["limits"]["liveProxyMaxRequestBytes"],
                        "liveProxyTemplateTokenAllowance": plan["limits"]["liveProxyTemplateTokenAllowance"],
                    },
                    "retryPolicy": (
                        "No automatic paid model retries; later attempts are separate "
                        "capped runs after cooldown."
                    ),
                    "priorInfrastructureAttempts": 0,
                },
                "episodes": [episode],
                "cost": {
                    "currency": "USD",
                    "traceReported": 0.0,
                    "observedWalletDebit": observed,
                    "unreconciled": observed,
                    "admissionBound": job["liveProxyCapUSD"],
                    "contractBound": job["contractMaximumCostUSD"],
                    "liveBudgetCap": job["liveProxyCapUSD"],
                    "hardAdmissionCap": job["liveProxyCapUSD"],
                    "liveBudget": live_budget,
                    "boundBasis": {
                        "inputTokenCeilingPerCall": plan["limits"]["inputTokenCeilingPerCall"],
                        "outputTokenCeilingPerCall": (
                            plan["limits"]["maxTokensPerCall"]
                            + plan["limits"]["providerResponseTokenAllowance"]
                        ),
                        "modelCallsPerAgentAtMost": (
                            plan["limits"]["maxTurns"]
                            * len(job["roles"])
                            // job["agentProcessCount"]
                        ),
                        "upstreamAttemptsPerTurnAtMost": plan["limits"]["upstreamAttemptsPerTurn"],
                        "inputPricePerMillion": plan["pricing"]["inputPricePerMillion"],
                        "outputPricePerMillion": plan["pricing"]["outputPricePerMillion"],
                        "billingOverheadUSDPerCall": plan["pricing"]["billingOverheadUSDPerCall"],
                    },
                },
                "privacy": {
                    "rawTracesPublished": False,
                    "credentialsPresent": False,
                    "promptsPublished": False,
                    "holdoutKeyPublished": False,
                },
            }
            raw_path.mkdir(parents=True)
            summary_path.parent.mkdir(parents=True, exist_ok=True)
            summary_path.write_bytes(canonical_json(summary))
            run_path.write_bytes(canonical_json(run_manifest))
            return subprocess.CompletedProcess(command, 0, b"", b"")

        return run

    def test_plan_flattens_each_frozen_profile_order_and_caps_every_cell(self) -> None:
        with tempfile.TemporaryDirectory(prefix="marginbench-crossover-controller-") as temporary:
            plan, _, crossover_path = self._plan(Path(temporary))
            crossover = json.loads(crossover_path.read_bytes())
        expected = []
        for episode in plan["jobs"][::2]:
            self.assertIn(episode["controlProfile"], {
                "role-separated-margin-only-v1",
                "single-agent-margin-v1",
            })
        by_episode: dict[str, list[str]] = {}
        for job in plan["jobs"]:
            by_episode.setdefault(job["episodeID"], []).append(job["controlProfile"])
            self.assertEqual(job["liveProxyCapUSD"], 0.03)
            self.assertGreater(job["contractMaximumCostUSD"], job["liveProxyCapUSD"])
            expected.append(job["ordinal"])
        self.assertEqual(expected, [1, 2, 3, 4])
        self.assertEqual(plan["budget"]["estimatedMaximumCostUSD"], 0.12)
        self.assertEqual(plan["jobCount"], 4)
        self.assertEqual(len(by_episode), 2)
        frozen = {episode["id"]: episode["profileOrder"] for episode in crossover["episodes"]}
        self.assertEqual(by_episode, frozen)
        self.assertTrue(validate_bytes(canonical_json(plan))["valid"])

        tampered = json.loads(canonical_json(plan))
        tampered["jobs"][0]["liveProxyCapUSD"] = 0.02
        self.assertFalse(validate_bytes(canonical_json(tampered))["valid"])

    def test_plan_refuses_an_aggregate_cap_below_the_cell_caps(self) -> None:
        with tempfile.TemporaryDirectory(prefix="marginbench-crossover-cap-") as temporary:
            root = Path(temporary)
            _, candidate_path, crossover_path = self._plan(root)
            with self.assertRaisesRegex(PrimeStudyError, "above the .* hard study cap"):
                build_crossover_prime_plan(
                    crossover_plan=crossover_path,
                    candidate_manifest=candidate_path,
                    candidate_binary=BINARY,
                    model="qwen/qwen3.7-flash",
                    limits=limits(),
                    pricing=pricing(),
                    live_proxy_cap_per_cell_usd=0.03,
                    hard_study_cap_usd=0.119,
                    minimum_wallet_reserve_usd=80.0,
                    package_root=PACKAGE_ROOT,
                    track="team",
                )

    def test_child_command_uses_the_planned_topology_and_disables_child_retries(self) -> None:
        with tempfile.TemporaryDirectory(prefix="marginbench-crossover-command-") as temporary:
            root = Path(temporary)
            plan, candidate_path, _ = self._plan(root)
            job = plan["jobs"][0]
            paths = {
                "raw": root / "raw",
                "summary": root / "summary.json",
                "run": root / "run.json",
                "receipt": root / "receipt.json",
                "attempt": root / "attempt.json",
            }
            command = _child_command(
                plan,
                job,
                paths,
                {
                    "candidateBinary": BINARY,
                    "candidateManifest": candidate_path,
                    "crossoverPlan": root / "crossover-plan.json",
                    "holdoutKey": None,
                },
            )
        self.assertEqual(command[command.index("--control-profile") + 1], job["controlProfile"])
        self.assertEqual(
            command[command.index("--minimum-start-interval-seconds") + 1],
            "300.0",
        )
        self.assertEqual(
            command[command.index("--live-proxy-timeout-seconds") + 1],
            "120.0",
        )
        self.assertEqual(
            command[command.index("--minimum-request-interval-seconds") + 1],
            "6.0",
        )
        self.assertEqual(command[command.index("--live-proxy-cost-cap-usd") + 1], "0.03")
        self.assertIn("--execute", command)
        self.assertNotIn("--holdout-key-file", command)

    def test_completed_cell_must_match_every_frozen_execution_and_cost_field(self) -> None:
        with tempfile.TemporaryDirectory(prefix="marginbench-crossover-contract-") as temporary:
            root = Path(temporary)
            plan, candidate_path, crossover_path = self._plan(root)
            job = plan["jobs"][0]
            paths = _job_paths(root / "work", job)
            command = _child_command(
                plan,
                job,
                paths,
                {
                    "candidateBinary": BINARY,
                    "candidateManifest": candidate_path,
                    "crossoverPlan": crossover_path,
                    "holdoutKey": None,
                },
            )
            self.assertEqual(self._fake_child(plan)(command).returncode, 0)
            self.assertEqual(_validate_job_outputs(plan, job, paths)["jobID"], job["id"])
            pristine_run = json.loads(paths["run"].read_bytes())
            pristine_summary = json.loads(paths["summary"].read_bytes())

            tamper_cases = (
                (
                    "temperature",
                    lambda run, _summary: run["execution"]["limits"].__setitem__(
                        "temperature", 0.5
                    ),
                ),
                (
                    "runtime",
                    lambda run, _summary: run["execution"].__setitem__(
                        "runtime", "another-runtime"
                    ),
                ),
                (
                    "pricing",
                    lambda run, _summary: run["cost"]["boundBasis"].__setitem__(
                        "inputPricePerMillion", 0.04
                    ),
                ),
                (
                    "live-cap-policy",
                    lambda run, summary: (
                        run["cost"]["liveBudget"]["policy"].__setitem__(
                            "maxTotalCostUSD", 0.02
                        ),
                        summary["liveBudget"]["policy"].__setitem__(
                            "maxTotalCostUSD", 0.02
                        ),
                    ),
                ),
                (
                    "summary-topology",
                    lambda _run, summary: summary["episodes"][0].__setitem__(
                        "phasePolicy", "independent-workspaces"
                    ),
                ),
            )
            for label, tamper in tamper_cases:
                with self.subTest(label=label):
                    run = json.loads(canonical_json(pristine_run))
                    summary = json.loads(canonical_json(pristine_summary))
                    tamper(run, summary)
                    paths["run"].write_bytes(canonical_json(run))
                    paths["summary"].write_bytes(canonical_json(summary))
                    with self.assertRaises(PrimeStudyError):
                        _validate_job_outputs(plan, job, paths)

            paths["run"].write_bytes(canonical_json(pristine_run))
            paths["summary"].write_bytes(canonical_json(pristine_summary))
            self.assertEqual(_validate_job_outputs(plan, job, paths)["jobID"], job["id"])

            infrastructure_run = json.loads(canonical_json(pristine_run))
            infrastructure_run["status"] = "infrastructure-error"
            paths["run"].write_bytes(canonical_json(infrastructure_run))
            with self.assertRaisesRegex(PrimeStudyError, "infrastructure-invalid"):
                _validate_job_outputs(plan, job, paths)

    def test_controller_pauses_resumes_builds_report_and_replays_without_spending(self) -> None:
        with tempfile.TemporaryDirectory(prefix="marginbench-crossover-resume-") as temporary:
            root = Path(temporary)
            plan, candidate_path, crossover_path = self._plan(root)
            arguments = argparse.Namespace(
                crossover_plan=crossover_path,
                candidate_manifest=candidate_path,
                candidate_bin=BINARY,
                holdout_key_file=None,
                work_dir=root / "work",
                minimum_start_interval_seconds=0.0,
                max_new_jobs=1,
            )
            calls: list[list[str]] = []
            paced_intervals: list[float] = []
            fake = self._fake_child(plan)

            def child(command: list[str], **kwargs: object) -> subprocess.CompletedProcess:
                calls.append(command)
                return fake(command, **kwargs)

            def wallet_reader(_: Path) -> dict[str, float | int]:
                return {"balanceUSD": 200.0, "totalBillings": 0}

            paused = execute_study(
                arguments,
                plan,
                wallet_reader=wallet_reader,
                child_runner=child,
                start_claimer=lambda *_, **__: None,
                start_pacer=lambda _path, interval: paced_intervals.append(interval),
                prime_resolver=lambda _: "/opt/fake-prime",
            )
            self.assertEqual(paused["status"], "paused")
            self.assertEqual(paused["completedJobs"], 1)
            self.assertEqual(len(calls), 1)

            arguments.max_new_jobs = 1000
            completed = execute_study(
                arguments,
                plan,
                wallet_reader=wallet_reader,
                child_runner=child,
                start_claimer=lambda *_, **__: None,
                start_pacer=lambda _path, interval: paced_intervals.append(interval),
                prime_resolver=lambda _: "/opt/fake-prime",
            )
            self.assertTrue(completed["completed"])
            self.assertEqual(completed["jobCount"], 4)
            self.assertEqual(completed["observedWalletDebitUSD"], 0.002)
            self.assertEqual(len(calls), 4)
            self.assertEqual(paced_intervals, [300.0] * 4)
            self.assertFalse(completed["sampleSizeSufficient"])
            self.assertEqual(completed["directionalConclusion"], "insufficient-data")
            self.assertTrue(validate_bytes(canonical_json(completed))["valid"])
            self.assertTrue(validate_artifact(arguments.work_dir / "crossover-report.json")["valid"])
            for command, job in zip(calls, plan["jobs"], strict=True):
                self.assertEqual(
                    self._value(command, "--control-profile"),
                    job["controlProfile"],
                )

            replay = execute_study(
                arguments,
                plan,
                wallet_reader=lambda _: self.fail("completed replay must not read the wallet"),
                child_runner=lambda *_args, **_kwargs: self.fail(
                    "completed replay must not start a child"
                ),
                start_claimer=lambda *_, **__: self.fail(
                    "completed replay must not claim another paid start"
                ),
                start_pacer=lambda *_, **__: self.fail(
                    "completed replay must not pace another paid start"
                ),
            )
            self.assertEqual(replay["report"]["sha256"], completed["report"]["sha256"])
            self.assertEqual(len(calls), 4)

    def test_inter_cell_pacer_waits_for_the_remaining_interval(self) -> None:
        with tempfile.TemporaryDirectory(prefix="marginbench-crossover-pacer-") as temporary:
            marker = Path(temporary) / "last-paid-start"
            marker.write_text("100.000000\n", encoding="ascii")
            now = [110.0]
            sleeps: list[float] = []

            def sleep(seconds: float) -> None:
                sleeps.append(seconds)
                now[0] += seconds

            wait_until_paid_start_allowed(
                marker,
                300.0,
                clock=lambda: now[0],
                sleeper=sleep,
            )
        self.assertEqual(sleeps, [290.0])


if __name__ == "__main__":
    unittest.main()
