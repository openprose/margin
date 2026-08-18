from __future__ import annotations

import argparse
import importlib.util
import json
import subprocess
import tempfile
import unittest
from dataclasses import asdict
from pathlib import Path

from marginbench.binary import resolve_margin_binary
from marginbench.candidates import CandidateManifest
from marginbench.entropy import PUBLIC_DEVELOPMENT_KEY
from marginbench.prime_study import build_prime_study_plan
from marginbench.provenance import implementation_sha256
from marginbench.runner import ReferenceDriver, run_episode
from marginbench.scenarios import generate_episode
from marginbench.schema import canonical_json
from marginbench.scheduling import build_execution_plan
from marginbench.studies import build_study_plan
from marginbench.submission import verify_submission
from marginbench.validation import validate_artifact, validate_bytes
from paired_pilot import execute_study


PACKAGE_ROOT = Path(__file__).resolve().parents[1]
REPOSITORY_CANDIDATE = PACKAGE_ROOT.parent.parent
ROOT = REPOSITORY_CANDIDATE if (REPOSITORY_CANDIDATE / "Package.swift").is_file() else PACKAGE_ROOT
BINARY = ROOT / "build" / "margin"
JSONSCHEMA_AVAILABLE = importlib.util.find_spec("jsonschema") is not None


def available_binary() -> Path | None:
    if BINARY.is_file():
        return BINARY
    try:
        return resolve_margin_binary()
    except ValueError:
        return None


@unittest.skipUnless(JSONSCHEMA_AVAILABLE, "jsonschema is not installed")
class PairedPrimeControllerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.binary = available_binary()
        if self.binary is None:
            self.skipTest("Build Margin or install a packaged Linux artifact first.")

    @staticmethod
    def _value(command: list[str], name: str) -> str:
        return command[command.index(name) + 1]

    def _fixture(self, root: Path) -> tuple[argparse.Namespace, dict]:
        baseline = CandidateManifest.create(
            "baseline",
            self.binary,
            settings={"guidance": "old"},
        )
        candidate = CandidateManifest.create(
            "candidate",
            self.binary,
            settings={"guidance": "new"},
        )
        baseline_path = root / "baseline.json"
        candidate_path = root / "candidate.json"
        baseline_path.write_bytes(canonical_json(asdict(baseline)))
        candidate_path.write_bytes(canonical_json(asdict(candidate)))
        study = build_study_plan(
            baseline=baseline.id,
            candidate=candidate.id,
            scenarios=["human_agent_relay"],
            repetitions=1,
            key=PUBLIC_DEVELOPMENT_KEY,
            development_cases=True,
        )
        study_path = root / "study.json"
        execution_path = root / "execution.json"
        study_path.write_bytes(canonical_json(study))
        execution_path.write_bytes(canonical_json(build_execution_plan(study_path)))
        limits = {
            "maxTurns": 2,
            "maxInputTokens": 2_000,
            "maxOutputTokens": 500,
            "maxTotalTokens": 2_500,
            "inputTokenCeilingPerCall": 4_096,
            "inputTokenCeilingSource": "https://example.invalid/model-contract",
            "upstreamAttemptsPerTurn": 1,
            "maxTokensPerCall": 250,
            "maxConcurrent": 1,
            "rolloutTimeoutSeconds": 30.0,
            "wallTimeoutSeconds": 60.0,
            "temperature": 0.0,
        }
        pricing = {
            "inputPricePerMillion": 0.03,
            "outputPricePerMillion": 0.13,
            "billingOverheadUSDPerCall": 0.0002,
            "source": "https://example.invalid/model-pricing",
        }
        plan = build_prime_study_plan(
            study_plan=study_path,
            execution_plan=execution_path,
            baseline_manifest=baseline_path,
            baseline_binary=self.binary,
            candidate_manifest=candidate_path,
            candidate_binary=self.binary,
            model="test/fake-paid-model",
            limits=limits,
            pricing=pricing,
            hard_admission_cap_usd=1.0,
            minimum_wallet_reserve_usd=80.0,
            package_root=PACKAGE_ROOT,
        )
        arguments = argparse.Namespace(
            study_plan=study_path,
            execution_plan=execution_path,
            baseline_manifest=baseline_path,
            baseline_bin=self.binary,
            candidate_manifest=candidate_path,
            candidate_bin=self.binary,
            holdout_key_file=None,
            work_dir=root / "work",
            publication_dir=root / "publication",
            minimum_start_interval_seconds=0.0,
            max_new_jobs=1,
            clock=lambda: 1_000.0,
        )
        return arguments, plan

    def _fake_child(self, plan: dict, root: Path):
        candidates = {plan["baseline"]["id"]: plan["baseline"], plan["candidate"]["id"]: plan["candidate"]}

        def run(command: list[str], **_: object) -> subprocess.CompletedProcess:
            candidate_id = self._value(command, "--candidate")
            scenario = self._value(command, "--scenario")
            repetition = int(self._value(command, "--repetition-id"))
            summary_path = Path(self._value(command, "--summary-file"))
            run_path = Path(self._value(command, "--run-manifest-file"))
            raw_path = Path(self._value(command, "--output-dir"))
            job = next(
                item
                for item in plan["jobs"]
                if item["candidateID"] == candidate_id
                and item["scenario"] == scenario
                and item["repetition"] == repetition
            )
            episode = generate_episode(scenario, PUBLIC_DEVELOPMENT_KEY, repetition)
            workspace = root / f"workspace-{job['ordinal']}"
            result = run_episode(
                episode,
                self.binary,
                workspace,
                ReferenceDriver(),
                candidate_id=candidate_id,
            )
            usage = {
                "modelCalls": 0,
                "promptTokens": 0,
                "completionTokens": 0,
                "cachedInputTokens": 0,
                "reasoningTokens": 0,
                "reportedCostUSD": 0,
            }
            role_runs = [
                {"seat": role, "stopCondition": "fake-reference", "usage": usage}
                for role in job["roles"]
            ]
            summary_episode = {
                "episodeID": result.episode_id,
                "scenario": scenario,
                "repetition": repetition,
                "fingerprint": job["fingerprint"],
                "score": result.score,
                "safetyPassed": result.safety_passed,
                "sourcePreserved": result.source_preserved,
                "commandCount": result.command_count,
                "invalidCommandCount": result.invalid_command_count,
                "durationMs": result.duration_ms,
                "marginSha256": result.margin_sha256,
                "checks": result.checks,
                "dimensions": result.dimensions,
                "usage": usage,
                "roleRuns": role_runs,
            }
            before = 200.0
            observed = 0.0005
            live_budget = {
                "enabled": True,
                "forwardedRequestCount": 1,
                "rejectedRequestCount": 0,
                "reservedCostUpperBoundUSD": plan["pricing"][
                    "billingOverheadUSDPerCall"
                ],
                "reportedPromptTokens": 0,
                "reportedCompletionTokens": 0,
                "reportedTokenCostUSD": 0,
                "policy": {
                    "allowedModel": plan["model"],
                    "maxRequestBytes": plan["limits"]["liveProxyMaxRequestBytes"],
                    "templateTokenAllowance": plan["limits"][
                        "liveProxyTemplateTokenAllowance"
                    ],
                    "inputTokenCeiling": plan["limits"]["inputTokenCeilingPerCall"],
                    "maxOutputTokens": plan["limits"]["maxTokensPerCall"],
                    "inputPricePerMillion": plan["pricing"]["inputPricePerMillion"],
                    "outputPricePerMillion": plan["pricing"]["outputPricePerMillion"],
                    "billingOverheadUSDPerCall": plan["pricing"][
                        "billingOverheadUSDPerCall"
                    ],
                    "maxTotalCostUSD": job["liveProxyCapUSD"],
                },
            }
            summary = {
                "schema": "urn:marginbench:prime-run-summary:v1",
                "status": "completed",
                "paidModelsInvoked": True,
                "model": plan["model"],
                "candidate": candidate_id,
                "scenarios": [scenario],
                "repetitions": 1,
                "marginSha256": candidates[candidate_id]["marginSha256"],
                "durationMs": round(result.duration_ms),
                "exitCode": 0,
                "wallet": {
                    "before": {"balanceUSD": before, "totalBillings": 0},
                    "after": {"balanceUSD": before - observed, "totalBillings": 1},
                    "observedDebitUSD": observed,
                },
                "estimatedMaximumCostUSD": job["estimatedMaximumCostUSD"],
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
            run_episode_value = {
                "id": result.episode_id,
                "scenario": scenario,
                "fingerprint": job["fingerprint"],
                "repetition": repetition,
                "score": result.score,
                "safetyPassed": result.safety_passed,
                "sourcePreserved": result.source_preserved,
                "commandCount": result.command_count,
                "invalidCommandCount": result.invalid_command_count,
                "durationMs": result.duration_ms,
                "marginSha256": result.margin_sha256,
                "checks": result.checks,
                "dimensions": result.dimensions,
                "usage": usage,
            }
            candidate = candidates[candidate_id]
            run_manifest = {
                "schema": "urn:marginbench:run:v1",
                "runID": f"fake-{job['ordinal']}",
                "status": "completed",
                "track": plan["track"],
                "benchmark": {
                    "name": "MarginBench",
                    "version": plan["benchmarkVersion"],
                    "taskSet": plan["taskSet"],
                    "developmentCases": plan["developmentCases"],
                    "implementationSha256": implementation_sha256(PACKAGE_ROOT),
                },
                "candidate": {
                    "id": candidate_id,
                    "marginSha256": candidate["marginSha256"],
                    "manualSha256": candidate["manualSha256"],
                    "settingsSha256": candidate["settingsSha256"],
                },
                "execution": {
                    "adapter": "prime-verifiers-v1",
                    "provider": "Prime Intellect",
                    "model": plan["model"],
                    "harness": "null-with-one-margin-tool",
                    "runtime": "local-subprocess-environment-with-prime-inference",
                    "controlProfile": plan["controlProfile"],
                    "agentProcessCount": len(job["roles"]),
                    "roles": job["roles"],
                    "startedAt": "2026-08-18T00:00:00Z",
                    "durationMs": result.duration_ms,
                    "limits": {
                        "maxConcurrentEpisodes": plan["limits"]["maxConcurrent"],
                        "maxInputTokens": plan["limits"]["maxInputTokens"],
                        "maxOutputTokens": plan["limits"]["maxOutputTokens"],
                        "maxTotalTokens": plan["limits"]["maxTotalTokens"],
                        "inputTokenCeilingPerCall": plan["limits"]["inputTokenCeilingPerCall"],
                        "upstreamAttemptsPerTurn": plan["limits"]["upstreamAttemptsPerTurn"],
                        "billingOverheadUSDPerCall": plan["pricing"]["billingOverheadUSDPerCall"],
                        "maxTokensPerCall": plan["limits"]["maxTokensPerCall"],
                        "maxTurns": plan["limits"]["maxTurns"],
                        "rolloutTimeoutSeconds": plan["limits"]["rolloutTimeoutSeconds"],
                        "temperature": plan["limits"]["temperature"],
                        "liveProxyMaxRequestBytes": plan["limits"][
                            "liveProxyMaxRequestBytes"
                        ],
                        "liveProxyTemplateTokenAllowance": plan["limits"][
                            "liveProxyTemplateTokenAllowance"
                        ],
                    },
                    "retryPolicy": "No automatic paid model retries.",
                    "priorInfrastructureAttempts": 0,
                },
                "episodes": [run_episode_value],
                "cost": {
                    "currency": "USD",
                    "traceReported": 0,
                    "observedWalletDebit": observed,
                    "unreconciled": observed,
                    "admissionBound": job["estimatedMaximumCostUSD"],
                    "contractBound": job["contractMaximumCostUSD"],
                    "liveBudgetCap": job["liveProxyCapUSD"],
                    "hardAdmissionCap": job["estimatedMaximumCostUSD"],
                    "liveBudget": live_budget,
                    "boundBasis": {
                        "inputTokenCeilingPerCall": plan["limits"]["inputTokenCeilingPerCall"],
                        "outputTokenCeilingPerCall": plan["limits"]["maxTokensPerCall"],
                        "modelCallsPerAgentAtMost": plan["limits"]["maxTurns"],
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

    def test_live_proxy_cap_preserves_contract_bound_and_reduces_enforced_study_maximum(self) -> None:
        with tempfile.TemporaryDirectory(prefix="marginbench-paired-live-cap-") as temporary:
            root = Path(temporary)
            arguments, uncapped = self._fixture(root)
            capped = build_prime_study_plan(
                study_plan=arguments.study_plan,
                execution_plan=arguments.execution_plan,
                baseline_manifest=arguments.baseline_manifest,
                baseline_binary=arguments.baseline_bin,
                candidate_manifest=arguments.candidate_manifest,
                candidate_binary=arguments.candidate_bin,
                model=uncapped["model"],
                limits=uncapped["limits"],
                pricing=uncapped["pricing"],
                hard_admission_cap_usd=0.001,
                minimum_wallet_reserve_usd=80.0,
                package_root=PACKAGE_ROOT,
                live_proxy_cap_per_job_usd=0.0004,
            )
            self.assertEqual(capped["budget"]["estimatedMaximumCostUSD"], 0.0008)
            self.assertEqual(
                capped["budget"]["contractMaximumCostUSD"],
                uncapped["budget"]["contractMaximumCostUSD"],
            )
            self.assertGreater(
                capped["budget"]["contractMaximumCostUSD"],
                capped["budget"]["estimatedMaximumCostUSD"],
            )
            self.assertEqual(
                [job["liveProxyCapUSD"] for job in capped["jobs"]],
                [0.0004, 0.0004],
            )
            self.assertTrue(validate_bytes(canonical_json(capped))["valid"])

            tampered = json.loads(canonical_json(capped))
            tampered["jobs"][0]["liveProxyCapUSD"] = 0.0005
            receipt = validate_bytes(canonical_json(tampered))
            self.assertFalse(receipt["valid"])
            self.assertTrue(any("live proxy cap" in error for error in receipt["errors"]))

    def test_controller_pauses_resumes_verifies_and_never_replays_completed_jobs(self) -> None:
        with tempfile.TemporaryDirectory(prefix="marginbench-paired-controller-") as temporary:
            root = Path(temporary)
            arguments, plan = self._fixture(root)
            calls: list[list[str]] = []
            child = self._fake_child(plan, root)

            def recorded(command: list[str], **kwargs: object) -> subprocess.CompletedProcess:
                calls.append(command)
                return child(command, **kwargs)

            def wallet(_: Path) -> dict[str, float | int]:
                return {"balanceUSD": 200.0, "totalBillings": 0}
            paused = execute_study(
                arguments,
                plan,
                wallet_reader=wallet,
                child_runner=recorded,
                start_claimer=lambda *_, **__: None,
                prime_resolver=lambda _: "/opt/fake-prime",
            )
            self.assertEqual(paused["status"], "paused")
            self.assertEqual(paused["completedJobs"], 1)
            self.assertEqual(len(calls), 1)
            self.assertTrue(validate_artifact(arguments.work_dir / "prime-study-plan.json")["valid"])

            arguments.max_new_jobs = 1000
            completed = execute_study(
                arguments,
                plan,
                wallet_reader=wallet,
                child_runner=recorded,
                start_claimer=lambda *_, **__: None,
                prime_resolver=lambda _: "/opt/fake-prime",
            )
            self.assertTrue(completed["verified"])
            self.assertEqual(completed["jobCount"], 2)
            self.assertEqual(len(calls), 2)
            for command, job in zip(calls, plan["jobs"], strict=True):
                self.assertEqual(
                    float(self._value(command, "--live-proxy-cost-cap-usd")),
                    job["liveProxyCapUSD"],
                )
                self.assertEqual(
                    int(self._value(command, "--live-proxy-max-request-bytes")),
                    plan["limits"]["liveProxyMaxRequestBytes"],
                )
            self.assertTrue(validate_bytes(canonical_json(completed))["valid"])
            self.assertTrue(verify_submission(arguments.publication_dir / "submission.json")["valid"])
            diagnostic_path = arguments.publication_dir / "diagnostic.json"
            self.assertTrue(validate_artifact(diagnostic_path)["valid"])
            diagnostic = json.loads(diagnostic_path.read_bytes())
            self.assertEqual(completed["diagnostic"]["topOpportunity"], diagnostic["topOpportunity"])
            self.assertFalse(diagnostic["privacy"]["rawTracesRequired"])
            receipts = sorted((arguments.work_dir / "redacted" / "jobs").glob("*.receipt.json"))
            self.assertEqual(len(receipts), 2)
            self.assertTrue(all(validate_artifact(path)["valid"] for path in receipts))

            replay = execute_study(
                arguments,
                plan,
                wallet_reader=lambda _: self.fail("completed replay must not read the wallet"),
                child_runner=lambda *_args, **_kwargs: self.fail(
                    "completed replay must not start a child"
                ),
                start_claimer=lambda *_, **__: self.fail(
                    "completed replay must not claim a paid start"
                ),
            )
            self.assertEqual(replay["submissionID"], completed["submissionID"])
            self.assertEqual(len(calls), 2)

            diagnostic_path.write_bytes(b"{}")
            with self.assertRaisesRegex(Exception, "artifact is invalid"):
                execute_study(
                    arguments,
                    plan,
                    wallet_reader=lambda _: self.fail("tampered replay must not read the wallet"),
                    child_runner=lambda *_args, **_kwargs: self.fail(
                        "tampered replay must not start a child"
                    ),
                    start_claimer=lambda *_, **__: self.fail(
                        "tampered replay must not claim a paid start"
                    ),
                )

    def test_dry_cli_emits_the_exact_valid_plan_without_creating_work_state(self) -> None:
        with tempfile.TemporaryDirectory(prefix="marginbench-paired-dry-cli-") as temporary:
            root = Path(temporary)
            arguments, expected = self._fixture(root)
            plan_path = root / "saved-plan.json"
            command = [
                str(PACKAGE_ROOT / "paired_pilot.py"),
                "--study-plan", str(arguments.study_plan),
                "--execution-plan", str(arguments.execution_plan),
                "--baseline-manifest", str(arguments.baseline_manifest),
                "--baseline-bin", str(arguments.baseline_bin),
                "--candidate-manifest", str(arguments.candidate_manifest),
                "--candidate-bin", str(arguments.candidate_bin),
                "--model", expected["model"],
                "--max-turns", "2",
                "--max-input-tokens", "2000",
                "--max-output-tokens", "500",
                "--max-total-tokens", "2500",
                "--input-token-ceiling-per-call", "4096",
                "--input-token-ceiling-source", "https://example.invalid/model-contract",
                "--upstream-attempts-per-turn", "1",
                "--max-tokens-per-call", "250",
                "--rollout-timeout-seconds", "30",
                "--wall-timeout-seconds", "60",
                "--input-price-per-million", "0.03",
                "--output-price-per-million", "0.13",
                "--pricing-source", "https://example.invalid/model-pricing",
                "--max-study-cost-usd", "1",
                "--minimum-wallet-reserve-usd", "80",
                "--plan-file", str(plan_path),
            ]
            completed = subprocess.run(
                command,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertEqual(completed.returncode, 0, completed.stderr.decode(errors="replace"))
            self.assertEqual(json.loads(completed.stdout), expected)
            self.assertEqual(json.loads(plan_path.read_bytes()), expected)
            self.assertTrue(validate_artifact(plan_path)["valid"])
            self.assertFalse(arguments.work_dir.exists())

    def test_unreceipted_attempt_marker_prevents_an_automatic_paid_retry(self) -> None:
        with tempfile.TemporaryDirectory(prefix="marginbench-paired-uncertain-") as temporary:
            root = Path(temporary)
            arguments, plan = self._fixture(root)

            def failed(command: list[str], **_: object) -> subprocess.CompletedProcess:
                return subprocess.CompletedProcess(command, 75, b"", b"infrastructure failure")

            def wallet(_: Path) -> dict[str, float | int]:
                return {"balanceUSD": 200.0, "totalBillings": 0}
            with self.assertRaisesRegex(Exception, "No retry was attempted"):
                execute_study(
                    arguments,
                    plan,
                    wallet_reader=wallet,
                    child_runner=failed,
                    start_claimer=lambda *_, **__: None,
                    prime_resolver=lambda _: "/opt/fake-prime",
                )
            with self.assertRaisesRegex(Exception, "will not be retried automatically"):
                execute_study(
                    arguments,
                    plan,
                    wallet_reader=lambda _: self.fail("uncertain replay must stop first"),
                    child_runner=lambda *_args, **_kwargs: self.fail("must not retry"),
                    start_claimer=lambda *_, **__: self.fail("must not claim another start"),
                )


if __name__ == "__main__":
    unittest.main()
