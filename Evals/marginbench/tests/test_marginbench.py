from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

from marginbench.binary import resolve_margin_binary, validate_packaged_binary
from marginbench.candidates import CandidateManifest, load_results, paired_compare
from marginbench.controls import DEFAULT_CONTROL_PROFILE, control_catalog, require_implemented_profile
from marginbench.fake_model import scripted_response
from marginbench.gateway import MarginGateway
from marginbench.keys import create_holdout_key
from marginbench.provenance import implementation_files, implementation_sha256
from marginbench.runner import ReferenceDriver, run_episode
from marginbench.scenarios import SCENARIO_IDS, generate_episode
from marginbench.schema import Actor, CommandEvent, EpisodeResult
from marginbench.scorer import score_episode
from marginbench.studies import build_study_plan
from marginbench.validation import validate_artifact, validate_bytes
from prime_pilot import _run_manifest, _summarize_traces, claim_paid_start, estimate_maximum_cost


PACKAGE_ROOT = Path(__file__).resolve().parents[1]
REPOSITORY_CANDIDATE = PACKAGE_ROOT.parent.parent
ROOT = REPOSITORY_CANDIDATE if (REPOSITORY_CANDIDATE / "Package.swift").is_file() else PACKAGE_ROOT
BINARY = ROOT / "build" / "margin"
KEY = b"marginbench-unit-test-secret-key-v1"
SCHEMA_ROOT = PACKAGE_ROOT / "schemas" / "v1"
JSONSCHEMA_AVAILABLE = importlib.util.find_spec("jsonschema") is not None


def available_binary() -> Path | None:
    if BINARY.is_file():
        return BINARY
    try:
        return resolve_margin_binary()
    except ValueError:
        return None


class IdleDriver:
    def run(self, episode, role, gateway) -> None:
        gateway.call(["version"])


class ReferencePlusSpamDriver:
    def run(self, episode, role, gateway) -> None:
        ReferenceDriver().run(episode, role, gateway)
        gateway.call([
            "comments", "add", "review.md", "-m", "Unrequested extra thread.",
            "--document", "--id", "00000000-0000-4000-8000-00000000feed",
        ])


class ReferencePlusChatterDriver:
    def run(self, episode, role, gateway) -> None:
        ReferenceDriver().run(episode, role, gateway)
        for _ in range(5):
            gateway.call(["version"])


class MarginBenchCoreTests(unittest.TestCase):
    def setUp(self) -> None:
        self.binary = available_binary()
        if self.binary is None:
            self.skipTest(f"Build Margin first or install a packaged Linux artifact: {BINARY}")

    def test_generation_is_deterministic_but_keyed(self) -> None:
        first = generate_episode("agent_agent_handoff", KEY, 7)
        repeated = generate_episode("agent_agent_handoff", KEY, 7)
        changed = generate_episode("agent_agent_handoff", b"another-marginbench-test-key-v1", 7)
        self.assertEqual(first, repeated)
        self.assertNotEqual(first.fingerprint, changed.fingerprint)
        manifest = first.public_manifest()
        self.assertNotIn("oracle", manifest)
        self.assertNotIn("files", manifest)
        self.assertNotIn(first.oracle["reference"]["handoffBody"], json.dumps(manifest))

    def test_result_contract_rejects_nonfinite_unsafe_and_inconsistent_values(self) -> None:
        values = {
            "episode_id": "episode",
            "candidate_id": "candidate",
            "score": 25.0,
            "dimensions": {"outcome": 25.0},
            "checks": {"ok": False},
            "command_count": 0,
            "invalid_command_count": 0,
            "duration_ms": 1.0,
            "safety_passed": False,
            "source_preserved": True,
            "margin_sha256": "0" * 64,
        }
        self.assertEqual(EpisodeResult(**values).score, 25.0)
        with self.assertRaisesRegex(ValueError, "capped at 25"):
            EpisodeResult(**{**values, "score": 25.1})
        with self.assertRaisesRegex(ValueError, "finite"):
            EpisodeResult(**{**values, "score": float("nan")})
        event = CommandEvent(
            role="author",
            command="version",
            exit_code=0,
            duration_ms=1,
            stdin_bytes=0,
            stdout_bytes=1,
            stderr_bytes=0,
        )
        with self.assertRaisesRegex(ValueError, "match command_count"):
            EpisodeResult(**{**values, "command_count": 2, "events": (event,)})
        with self.assertRaisesRegex(ValueError, "nonnegative"):
            CommandEvent(
                role="author",
                command="version",
                exit_code=0,
                duration_ms=-1,
                stdin_bytes=0,
                stdout_bytes=0,
                stderr_bytes=0,
            )

    def test_free_prime_preflight_script_understands_every_role_brief(self) -> None:
        expected_roles = 0
        for scenario in SCENARIO_IDS:
            episode = generate_episode(scenario, KEY, 0)
            for role in episode.roles:
                expected_roles += 1
                invocation = scripted_response([{"role": "user", "content": role.prompt}])
                self.assertIsInstance(invocation, dict)
                self.assertIsInstance(invocation.get("arguments"), list)
                self.assertTrue(invocation["arguments"])
        self.assertEqual(expected_roles, 9)

    def test_prime_summary_aggregates_roles_into_one_schema_valid_episode(self) -> None:
        result = {
            "episodeID": "agent_agent_handoff:0:" + "a" * 12,
            "score": 100.0,
            "safetyPassed": True,
            "commandCount": 7,
            "invalidCommandCount": 0,
            "checks": {"valid_documents": True},
            "dimensions": {"outcome": 100.0},
        }
        traces = []
        for seat, cost in (("author", 0.001), ("reviewer", 0.002)):
            traces.append({
                "task": {"data": {
                    "name": f"agent_agent_handoff:0:{'a' * 12}:{seat}",
                    "scenario_id": "agent_agent_handoff",
                    "repetition": 0,
                    "fingerprint": "a" * 64,
                }},
                "calls": [{"usage": {
                    "prompt_tokens": 100,
                    "completion_tokens": 20,
                    "cached_input_tokens": 10,
                    "reasoning_tokens": 5,
                    "cost": cost,
                }}],
                "info": {"marginbench": result},
                "stop_condition": "agent_completed",
            })
        with tempfile.TemporaryDirectory(prefix="marginbench-summary-test-") as temporary:
            output = Path(temporary)
            (output / "traces.jsonl").write_text(
                json.dumps({"traces": traces}, separators=(",", ":")) + "\n",
                encoding="utf-8",
            )
            summary = _summarize_traces(output)
        self.assertEqual(summary["traceCount"], 2)
        self.assertEqual(summary["episodeCount"], 1)
        self.assertTrue(summary["traceConsistencyPassed"])
        self.assertEqual(summary["episodes"][0]["usage"]["reportedCostUSD"], 0.003)
        self.assertEqual(
            [role["seat"] for role in summary["episodes"][0]["roleRuns"]],
            ["author", "reviewer"],
        )

        arguments = SimpleNamespace(
            candidate="summary-test",
            margin_bin=self.binary,
            track="interface",
            model="test/model",
            max_concurrent=1,
            max_input_tokens=1000,
            max_output_tokens=500,
            max_total_tokens=1500,
            input_token_ceiling_per_call=4096,
            upstream_attempts_per_turn=3,
            billing_overhead_usd_per_call=0.0002,
            max_tokens_per_call=250,
            max_turns=4,
            rollout_timeout_seconds=30.0,
            temperature=0.0,
            prior_infrastructure_attempts=0,
            scenario=["agent_agent_handoff"],
            repetitions=1,
            input_price_per_million=0.03,
            output_price_per_million=0.13,
            max_cost_usd=1.0,
            control_profile=DEFAULT_CONTROL_PROFILE,
        )
        manifest = _run_manifest(
            arguments,
            summary,
            status="completed",
            started_at="2026-08-18T00:00:00Z",
            duration_ms=123,
            observed_wallet_debit=0.003,
        )
        self.assertEqual(len(manifest["episodes"]), 1)
        self.assertEqual(manifest["execution"]["roles"], ["author", "reviewer"])
        self.assertEqual(manifest["execution"]["agentProcessCount"], 2)
        self.assertEqual(manifest["execution"]["controlProfile"], DEFAULT_CONTROL_PROFILE)
        self.assertEqual(len(manifest["benchmark"]["implementationSha256"]), 64)
        self.assertEqual(manifest["cost"]["admissionBound"], 0.008529)
        self.assertLessEqual(
            manifest["cost"]["admissionBound"],
            manifest["cost"]["hardAdmissionCap"],
        )
        partial = json.loads(json.dumps(summary))
        partial["episodes"][0]["roleRuns"] = partial["episodes"][0]["roleRuns"][:1]
        partial_manifest = _run_manifest(
            arguments,
            partial,
            status="infrastructure_error",
            started_at="2026-08-18T00:00:00Z",
            duration_ms=123,
            observed_wallet_debit=0.003,
        )
        self.assertEqual(partial_manifest["execution"]["agentProcessCount"], 2)
        try:
            from jsonschema import Draft202012Validator
        except ImportError:
            return
        schema = json.loads((SCHEMA_ROOT / "run-manifest.schema.json").read_text(encoding="utf-8"))
        Draft202012Validator(schema).validate(manifest)

    def test_implementation_digest_is_stable_and_excludes_generated_or_private_data(self) -> None:
        files = implementation_files(PACKAGE_ROOT)
        relative = [path.relative_to(PACKAGE_ROOT).as_posix() for path in files]
        self.assertEqual(relative, sorted(relative))
        self.assertIn("marginbench/scorer.py", relative)
        self.assertIn("schemas/v1/result.schema.json", relative)
        self.assertNotIn("results/EXPERIMENTS.json", relative)
        self.assertFalse(any("runs/" in path or "/bin/" in path for path in relative))
        first = implementation_sha256(PACKAGE_ROOT)
        second = implementation_sha256(PACKAGE_ROOT)
        self.assertEqual(first, second)
        self.assertRegex(first, "^[0-9a-f]{64}$")

    def test_versioned_public_schemas_are_valid_and_match_generated_manifest(self) -> None:
        schemas = {}
        for path in sorted(SCHEMA_ROOT.glob("*.schema.json")):
            payload = json.loads(path.read_text(encoding="utf-8"))
            self.assertEqual(payload["$schema"], "https://json-schema.org/draft/2020-12/schema")
            self.assertNotIn(payload["$id"], schemas)
            schemas[payload["$id"]] = payload
        self.assertEqual(len(schemas), 16)

        try:
            from jsonschema import Draft202012Validator
        except ImportError:
            return
        for payload in schemas.values():
            Draft202012Validator.check_schema(payload)
        public = json.loads((SCHEMA_ROOT / "public-manifest.schema.json").read_text(encoding="utf-8"))
        manifest = generate_episode("human_agent_relay", KEY, 0).public_manifest()
        Draft202012Validator(public).validate(manifest)
        samples = (
            ("binary-manifest.schema.json", PACKAGE_ROOT / "BINARY_MANIFEST.json"),
            (
                "candidate.schema.json",
                PACKAGE_ROOT / "results" / "candidates" / "read-alias-status-and-next-action-v2.json",
            ),
            ("run-manifest.schema.json", PACKAGE_ROOT / "results" / "PRIME_GATE1_CANDIDATE2.json"),
            (
                "runtime-probe.schema.json",
                PACKAGE_ROOT / "results" / "PRIME_REMOTE_RUNTIME_PROBE.json",
            ),
            (
                "experiment-ledger.schema.json",
                PACKAGE_ROOT / "results" / "EXPERIMENT_LEDGER.json",
            ),
        )
        for schema_name, sample_path in samples:
            sample = json.loads(sample_path.read_text(encoding="utf-8"))
            Draft202012Validator(
                json.loads((SCHEMA_ROOT / schema_name).read_text(encoding="utf-8"))
            ).validate(sample)

    def test_study_plan_is_private_safe_counterbalanced_and_promotion_sized(self) -> None:
        plan = build_study_plan(
            baseline="baseline",
            candidate="candidate-v2",
            scenarios=list(SCENARIO_IDS),
            repetitions=4,
            key=KEY,
            development_cases=False,
        )
        repeated = build_study_plan(
            baseline="baseline",
            candidate="candidate-v2",
            scenarios=list(SCENARIO_IDS),
            repetitions=4,
            key=KEY,
            development_cases=False,
        )
        self.assertEqual(plan, repeated)
        self.assertEqual(plan["episodeCount"], 20)
        self.assertEqual(plan["controlProfile"], DEFAULT_CONTROL_PROFILE)
        self.assertTrue(plan["sampleSizeSufficient"])
        self.assertEqual(plan["totalRoleRuns"], plan["roleRunsPerCandidate"] * 2)
        orders = [tuple(item["candidateOrder"]) for item in plan["episodes"]]
        self.assertEqual(orders.count(("baseline", "candidate-v2")), 10)
        self.assertEqual(orders.count(("candidate-v2", "baseline")), 10)
        encoded = json.dumps(plan)
        self.assertNotIn("oracle", encoded)
        self.assertNotIn("prompt", encoded)
        try:
            from jsonschema import Draft202012Validator
        except ImportError:
            return
        schema = json.loads((SCHEMA_ROOT / "study-plan.schema.json").read_text(encoding="utf-8"))
        Draft202012Validator(schema).validate(plan)

    def test_control_catalog_gates_unfair_or_unsafe_ablations(self) -> None:
        catalog = control_catalog()
        self.assertEqual(catalog["default"], DEFAULT_CONTROL_PROFILE)
        implemented = [item for item in catalog["profiles"] if item["status"] == "implemented"]
        self.assertEqual([item["id"] for item in implemented], [DEFAULT_CONTROL_PROFILE])
        self.assertEqual(implemented[0]["toolSurface"], ["margin"])
        self.assertFalse(implemented[0]["shellAccess"])
        shell = next(item for item in catalog["profiles"] if item["shellAccess"])
        self.assertEqual(shell["status"], "specified-not-runnable")
        self.assertIn("remote-sandbox", shell["isolationRequirement"])
        self.assertEqual(require_implemented_profile(DEFAULT_CONTROL_PROFILE), implemented[0])
        with self.assertRaisesRegex(ValueError, "not safely runnable"):
            require_implemented_profile("single-agent-margin-v1")
        episode = generate_episode("human_agent_relay", KEY, 0)
        self.assertEqual(episode.public_manifest()["controls"], [DEFAULT_CONTROL_PROFILE])
        try:
            from jsonschema import Draft202012Validator
        except ImportError:
            return
        schema = json.loads((SCHEMA_ROOT / "control-catalog.schema.json").read_text(encoding="utf-8"))
        Draft202012Validator(schema).validate(catalog)

    def test_holdout_key_creation_is_private_exclusive_and_never_echoes_secret(self) -> None:
        with tempfile.TemporaryDirectory(prefix="marginbench-key-test-") as temporary:
            path = Path(temporary) / "holdout.key"
            receipt = create_holdout_key(path)
            secret = path.read_text(encoding="ascii").strip()
            self.assertRegex(secret, "^[0-9a-f]{64}$")
            self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)
            self.assertFalse(receipt["secretPrinted"])
            self.assertNotIn(secret, json.dumps(receipt))
            original = path.read_bytes()
            with self.assertRaisesRegex(ValueError, "Refusing to replace"):
                create_holdout_key(path)
            self.assertEqual(path.read_bytes(), original)
            linked = Path(temporary) / "linked.key"
            target = Path(temporary) / "target.key"
            linked.symlink_to(target)
            with self.assertRaisesRegex(ValueError, "Refusing to replace"):
                create_holdout_key(linked)
            self.assertFalse(target.exists())

    def test_paid_plan_costs_every_role_and_stays_conservative(self) -> None:
        one_role = estimate_maximum_cost(
            ["human_agent_relay"], 1, 12, 3, 65_536, 2_400, 0.03, 0.13, 0.0002
        )
        two_roles = estimate_maximum_cost(
            ["agent_agent_handoff"], 1, 12, 3, 65_536, 2_400, 0.03, 0.13, 0.0002
        )
        self.assertEqual(one_role, 0.089211)
        self.assertEqual(two_roles, 0.178422)
        observed_stage_cost = 0.0044
        self.assertGreater(two_roles, observed_stage_cost)

    def test_paid_start_gate_serializes_and_enforces_cooldown(self) -> None:
        with tempfile.TemporaryDirectory(prefix="marginbench-paid-gate-") as temporary:
            marker = Path(temporary) / "last-start"
            claim_paid_start(marker, now=1_000.0, minimum_interval_seconds=300.0)
            with self.assertRaisesRegex(RuntimeError, "200 seconds remaining"):
                claim_paid_start(marker, now=1_100.0, minimum_interval_seconds=300.0)
            claim_paid_start(marker, now=1_300.0, minimum_interval_seconds=300.0)

    def test_gateway_blocks_escape_gui_and_identity_override_without_raw_log(self) -> None:
        with tempfile.TemporaryDirectory(prefix="marginbench-gateway-test-") as temporary:
            root = Path(temporary)
            workspace = root / "workspace"
            workspace.mkdir()
            (workspace / "note.md").write_text("# Note\n", encoding="utf-8")
            log = root / "events.jsonl"
            gateway = MarginGateway(
                self.binary,
                workspace,
                Actor("urn:test:actor", "Test Actor"),
                "author",
                event_log=log,
            )
            self.assertEqual(gateway.call(["../../escape"]).error_code, "MARGINBENCH_COMMAND_BLOCKED")
            self.assertEqual(
                gateway.call(["submit"]).error_code,
                "MARGINBENCH_COMMAND_BLOCKED",
                "A plausible but nonexistent command must not fall through to Margin's GUI path.",
            )
            self.assertEqual(gateway.call(["read", "/etc/passwd", "--json"]).error_code, "MARGINBENCH_WORKSPACE_ESCAPE")
            self.assertEqual(
                gateway.call(["comments", "list", "note.md", "--actor-id", "urn:spoof"]).error_code,
                "MARGINBENCH_IDENTITY_BOUND",
            )
            outside = root / "outside.md"
            outside.write_text("private\n", encoding="utf-8")
            (workspace / "linked.md").symlink_to(outside)
            self.assertEqual(
                gateway.call(["read", "linked.md", "--json"]).error_code,
                "MARGINBENCH_WORKSPACE_ESCAPE",
            )
            prose_with_path_syntax = gateway.call([
                "comments", "add", "note.md", "-m",
                "Compare ../prior.md with /etc/passwd as literal untrusted prose.",
                "--document", "--id", "7880b31c-04cf-4dcc-9d2d-4a51218e2540",
            ])
            self.assertTrue(prose_with_path_syntax.ok)
            prose_with_identity_syntax = gateway.call([
                "comments", "add", "note.md", "-m", "--actor-id=urn:literal-prose",
                "--document", "--id", "f15c53ec-f862-4b96-9059-cf6cf384479c",
            ])
            self.assertTrue(prose_with_identity_syntax.ok)
            self.assertEqual(
                gateway.call([
                    "comments", "add", "note.md", "--message-file", "../outside.md",
                    "--document", "--id", "fbfbe7c1-ae07-42ea-868f-4503ad8c7888",
                ]).error_code,
                "MARGINBENCH_WORKSPACE_ESCAPE",
            )
            secret_body = "do-not-retain-this-body-8f5e"
            response = gateway.call([
                "comments", "add", "note.md", "-m", secret_body,
                "--document", "--id", "4ff7ed11-5899-4ed2-a282-4e0362f43cba",
            ])
            self.assertTrue(response.ok)
            self.assertNotIn(secret_body, log.read_text(encoding="utf-8"))
            context = gateway.call(["context", "note.md", "--json"])
            self.assertTrue(context.ok)
            available = (context.json or {}).get("result", {}).get("availableActions", [])
            self.assertGreater(len(available), 5)
            for command in available:
                with self.subTest(available_action=command):
                    self.assertTrue(
                        gateway.call([*command.split(), "--help"]).ok,
                        f"Context advertised a non-command action: {command}",
                    )

    def test_reference_policy_scores_every_scenario_at_100(self) -> None:
        for index, scenario in enumerate(SCENARIO_IDS):
            with self.subTest(scenario=scenario):
                episode = generate_episode(scenario, KEY, index)
                with tempfile.TemporaryDirectory(prefix="marginbench-reference-test-") as temporary:
                    result = run_episode(
                        episode,
                        self.binary,
                        Path(temporary) / "workspace",
                        ReferenceDriver(),
                    )
                self.assertEqual(result.score, 100.0)
                self.assertTrue(result.safety_passed)
                self.assertTrue(all(result.checks.values()))

    def test_scripted_human_setup_is_not_counted_as_agent_work(self) -> None:
        episode = generate_episode("human_agent_relay", KEY, 0)
        with tempfile.TemporaryDirectory(prefix="marginbench-role-count-test-") as temporary:
            result = run_episode(
                episode,
                self.binary,
                Path(temporary) / "workspace",
                ReferenceDriver(),
            )
        self.assertEqual(result.command_count, 6)
        self.assertEqual(result.invalid_command_count, 0)

    def test_incomplete_agent_does_not_receive_vacuous_credit(self) -> None:
        episode = generate_episode("staged_multifile", KEY, 0)
        with tempfile.TemporaryDirectory(prefix="marginbench-idle-test-") as temporary:
            result = run_episode(
                episode,
                self.binary,
                Path(temporary) / "workspace",
                IdleDriver(),
            )
        self.assertLess(result.score, 60.0)
        self.assertFalse(result.checks["all_expected_annotations"])
        self.assertFalse(result.checks["required_commands"])
        self.assertFalse(result.checks["committed_all"])

    def test_post_run_corruption_triggers_safety_cap(self) -> None:
        episode = generate_episode("human_agent_relay", KEY, 0)
        with tempfile.TemporaryDirectory(prefix="marginbench-corruption-test-") as temporary:
            root = Path(temporary)
            workspace = root / "workspace"
            result = run_episode(episode, self.binary, workspace, ReferenceDriver())
            self.assertEqual(result.score, 100.0)
            (workspace / "review.md").write_text("corrupted\n", encoding="utf-8")
            rescored = score_episode(
                episode,
                workspace,
                self.binary,
                root / ".marginbench-control" / "events.jsonl",
            )
            self.assertLessEqual(rescored.score, 25.0)
            self.assertFalse(rescored.safety_passed)

    def test_unrequested_extra_contribution_cannot_receive_exact_outcome_credit(self) -> None:
        episode = generate_episode("human_agent_relay", KEY, 0)
        with tempfile.TemporaryDirectory(prefix="marginbench-spam-test-") as temporary:
            result = run_episode(
                episode,
                self.binary,
                Path(temporary) / "workspace",
                ReferencePlusSpamDriver(),
            )
        self.assertFalse(result.checks["no_unexpected_annotations"])
        self.assertLess(result.score, 100.0)
        self.assertTrue(result.safety_passed)

    def test_command_efficiency_rewards_a_bounded_solution_before_the_hard_limit(self) -> None:
        episode = generate_episode("human_agent_relay", KEY, 0)
        with tempfile.TemporaryDirectory(prefix="marginbench-efficiency-test-") as temporary:
            result = run_episode(
                episode,
                self.binary,
                Path(temporary) / "workspace",
                ReferencePlusChatterDriver(),
            )
        self.assertTrue(result.checks["all_expected_annotations"])
        self.assertEqual(result.invalid_command_count, 0)
        self.assertLess(result.dimensions["efficiency"], 100.0)
        self.assertGreater(result.dimensions["efficiency"], 0.0)
        self.assertLess(result.score, 100.0)

    def test_paired_comparison_requires_identical_cases_and_safety_parity(self) -> None:
        def result(
            identifier: str,
            score: float,
            candidate_id: str,
            safe: bool = True,
        ) -> EpisodeResult:
            return EpisodeResult(
                episode_id=identifier,
                candidate_id=candidate_id,
                score=score,
                dimensions={"outcome": score},
                checks={"ok": safe},
                command_count=1,
                invalid_command_count=0,
                duration_ms=1,
                safety_passed=safe,
                source_preserved=safe,
                margin_sha256="0" * 64,
            )

        baseline = [result("a", 40, "baseline"), result("b", 50, "baseline")]
        candidate = [result("a", 60, "candidate"), result("b", 70, "candidate")]
        comparison = paired_compare(baseline, candidate, bootstrap_samples=1_000)
        self.assertEqual(comparison["baselineCandidateID"], "baseline")
        self.assertEqual(comparison["candidateID"], "candidate")
        self.assertEqual(comparison["meanScoreDelta"], 20.0)
        self.assertFalse(comparison["sampleSizeSufficient"])
        self.assertFalse(comparison["promotable"])
        repeated_baseline = [result(f"case-{index}", 40, "baseline") for index in range(20)]
        repeated_candidate = [result(f"case-{index}", 60, "candidate") for index in range(20)]
        repeated = paired_compare(repeated_baseline, repeated_candidate, bootstrap_samples=1_000)
        self.assertTrue(repeated["sampleSizeSufficient"])
        self.assertTrue(repeated["promotable"])
        unsafe = [result("a", 25, "candidate", False), result("b", 70, "candidate")]
        self.assertFalse(paired_compare(baseline, unsafe, bootstrap_samples=100)["promotable"])
        with self.assertRaises(ValueError):
            paired_compare(baseline, [result("a", 60, "candidate")])
        with self.assertRaisesRegex(ValueError, "duplicate episode IDs"):
            paired_compare(
                [result("a", 40, "baseline"), result("a", 50, "baseline")],
                candidate,
            )
        with self.assertRaisesRegex(ValueError, "distinct candidate IDs"):
            paired_compare(baseline, [result("a", 60, "baseline"), result("b", 70, "baseline")])

    def test_candidate_manifest_freezes_binary_manual_and_canonical_settings(self) -> None:
        repository_manual = ROOT / "Sources" / "MarginCLI" / "MarginManual.swift"
        manual = repository_manual if repository_manual.is_file() else PACKAGE_ROOT / "README.md"
        first = CandidateManifest.create(
            "read-receipts-v1",
            self.binary,
            manual=manual,
            settings={"tool": "margin", "maxTurns": 12},
        )
        repeated = CandidateManifest.create(
            "read-receipts-v1",
            self.binary,
            manual=manual,
            settings={"maxTurns": 12, "tool": "margin"},
        )
        self.assertEqual(first, repeated)
        self.assertEqual(first.digest(), repeated.digest())
        self.assertEqual(len(first.margin_sha256), 64)
        self.assertEqual(len(first.manual_sha256 or ""), 64)
        with self.assertRaises(ValueError):
            CandidateManifest(
                id="broken",
                margin_sha256="0" * 64,
                manual_sha256=None,
                settings_sha256="0" * 64,
                settings={"different": True},
            )

    def test_packaged_linux_binary_matches_the_tracked_manifest(self) -> None:
        package_bin = PACKAGE_ROOT / "marginbench" / "bin"
        binary = package_bin / "margin-linux-x86_64"
        if not binary.is_file():
            self.skipTest("Build the Linux release artifact to verify its digest.")
        data = validate_packaged_binary(binary, package_bin)
        manifest = json.loads((PACKAGE_ROOT / "BINARY_MANIFEST.json").read_text(encoding="utf-8"))
        artifact = next(item for item in manifest["artifacts"] if item["architecture"] == "x86_64")
        self.assertEqual(len(data), artifact["bytes"])

    @unittest.skipUnless(JSONSCHEMA_AVAILABLE, "jsonschema is not installed")
    def test_public_artifact_validation_is_bounded_schema_backed_and_semantic(self) -> None:
        plan = build_study_plan(
            baseline="baseline",
            candidate="candidate-v2",
            scenarios=list(SCENARIO_IDS),
            repetitions=4,
            key=KEY,
            development_cases=False,
        )
        valid = validate_bytes(json.dumps(plan).encode("utf-8"))
        self.assertTrue(valid["valid"])
        self.assertEqual(valid["artifactSchema"], "urn:marginbench:study-plan:v1")
        self.assertRegex(valid["sha256"], "^[0-9a-f]{64}$")
        self.assertEqual(valid["errors"], [])
        self.assertTrue(validate_bytes(json.dumps(valid).encode("utf-8"))["valid"])

        plan["episodes"][1]["id"] = plan["episodes"][0]["id"]
        invalid = validate_bytes(json.dumps(plan).encode("utf-8"))
        self.assertFalse(invalid["valid"])
        self.assertEqual(invalid["error"]["code"], "ARTIFACT_INVALID")
        self.assertTrue(any("duplicate episode" in item for item in invalid["errors"]))

        duplicate_key = validate_bytes(b'{"schema":"urn:marginbench:candidate:v1","schema":"again"}')
        self.assertFalse(duplicate_key["valid"])
        self.assertEqual(duplicate_key["error"]["code"], "DUPLICATE_JSON_KEY")
        nonfinite = validate_bytes(b'{"schema":NaN}')
        self.assertFalse(nonfinite["valid"])
        self.assertEqual(nonfinite["error"]["code"], "INVALID_JSON_NUMBER")
        oversized = validate_bytes(b" " * (16 * 1_024 * 1_024 + 1))
        self.assertFalse(oversized["valid"])
        self.assertEqual(oversized["error"]["code"], "ARTIFACT_TOO_LARGE")
        self.assertIsNone(oversized["sha256"])

    @unittest.skipUnless(JSONSCHEMA_AVAILABLE, "jsonschema is not installed")
    def test_run_manifest_validation_recomputes_cost_and_rejects_tampering(self) -> None:
        result = {
            "episodeID": "agent_agent_handoff:0:" + "a" * 12,
            "score": 100.0,
            "safetyPassed": True,
            "commandCount": 7,
            "invalidCommandCount": 0,
            "checks": {"valid_documents": True},
            "dimensions": {"outcome": 100.0},
        }
        traces = []
        for seat, cost in (("author", 0.001), ("reviewer", 0.002)):
            traces.append({
                "task": {"data": {
                    "name": f"agent_agent_handoff:0:{'a' * 12}:{seat}",
                    "scenario_id": "agent_agent_handoff",
                    "repetition": 0,
                    "fingerprint": "a" * 64,
                }},
                "calls": [{"usage": {
                    "prompt_tokens": 100,
                    "completion_tokens": 20,
                    "cached_input_tokens": 10,
                    "reasoning_tokens": 5,
                    "cost": cost,
                }}],
                "info": {"marginbench": result},
                "stop_condition": "agent_completed",
            })
        with tempfile.TemporaryDirectory(prefix="marginbench-validation-test-") as temporary:
            output = Path(temporary)
            (output / "traces.jsonl").write_text(
                json.dumps({"traces": traces}, separators=(",", ":")) + "\n",
                encoding="utf-8",
            )
            summary = _summarize_traces(output)
            arguments = SimpleNamespace(
                candidate="validation-test",
                margin_bin=self.binary,
                track="interface",
                model="test/model",
                max_concurrent=1,
                max_input_tokens=1000,
                max_output_tokens=500,
                max_total_tokens=1500,
                input_token_ceiling_per_call=4096,
                upstream_attempts_per_turn=3,
                billing_overhead_usd_per_call=0.0002,
                max_tokens_per_call=250,
                max_turns=4,
                rollout_timeout_seconds=30.0,
                temperature=0.0,
                prior_infrastructure_attempts=0,
                scenario=["agent_agent_handoff"],
                repetitions=1,
                input_price_per_million=0.03,
                output_price_per_million=0.13,
                max_cost_usd=1.0,
                control_profile=DEFAULT_CONTROL_PROFILE,
            )
            manifest = _run_manifest(
                arguments,
                summary,
                status="completed",
                started_at="2026-08-18T00:00:00Z",
                duration_ms=123,
                observed_wallet_debit=0.003,
            )
            artifact = output / "run.json"
            artifact.write_text(json.dumps(manifest), encoding="utf-8")
            self.assertTrue(validate_artifact(artifact)["valid"])
            manifest["cost"]["admissionBound"] += 0.01
            artifact.write_text(json.dumps(manifest), encoding="utf-8")
            receipt = validate_artifact(artifact)
            self.assertFalse(receipt["valid"])
            self.assertTrue(any("recorded basis" in item for item in receipt["errors"]))
            manifest = _run_manifest(
                arguments,
                summary,
                status="completed",
                started_at="2026-08-18T00:00:00Z",
                duration_ms=123,
                observed_wallet_debit=0.003,
            )
            del manifest["execution"]["agentProcessCount"]
            artifact.write_text(json.dumps(manifest), encoding="utf-8")
            receipt = validate_artifact(artifact)
            self.assertFalse(receipt["valid"])
            self.assertTrue(any("cost bound requires" in item for item in receipt["errors"]))

    @unittest.skipUnless(JSONSCHEMA_AVAILABLE, "jsonschema is not installed")
    def test_tracked_prime_evidence_is_independently_checkable(self) -> None:
        expected_invalid = {
            "EXPERIMENTS.json": "legacy ledger shape reused the v1 identifier",
            "PRIME_GATE2_HANDOFF_V5.json": "duplicate episode ids",
            "PRIME_GATE2_HANDOFF_V6.json": "duplicate episode ids",
            "PRIME_GATE2_STAGED_V10.json": "old cost estimate was exceeded",
        }
        observed_invalid: set[str] = set()
        for artifact in sorted((PACKAGE_ROOT / "results").glob("*.json")):
            receipt = validate_artifact(artifact)
            self.assertNotEqual(receipt["error"].get("code") if receipt["error"] else None, "UNSUPPORTED_SCHEMA")
            if not receipt["valid"]:
                observed_invalid.add(artifact.name)
        self.assertEqual(observed_invalid, set(expected_invalid))

    @unittest.skipUnless(JSONSCHEMA_AVAILABLE, "jsonschema is not installed")
    def test_metadata_validation_recomputes_ledger_binary_and_runtime_claims(self) -> None:
        ledger = json.loads(
            (PACKAGE_ROOT / "results" / "EXPERIMENT_LEDGER.json").read_text(encoding="utf-8")
        )
        ledger["totals"]["modelCalls"] += 1
        receipt = validate_bytes(json.dumps(ledger).encode("utf-8"))
        self.assertFalse(receipt["valid"])
        self.assertTrue(any("model-call total" in item for item in receipt["errors"]))
        ledger = json.loads(
            (PACKAGE_ROOT / "results" / "EXPERIMENT_LEDGER.json").read_text(encoding="utf-8")
        )
        ledger["recordedAt"] = "yesterday"
        receipt = validate_bytes(json.dumps(ledger).encode("utf-8"))
        self.assertFalse(receipt["valid"])
        self.assertTrue(any("date-time" in item for item in receipt["errors"]))

        binary = json.loads((PACKAGE_ROOT / "BINARY_MANIFEST.json").read_text(encoding="utf-8"))
        binary["artifacts"][0]["platform"] = "linux/arm64"
        receipt = validate_bytes(json.dumps(binary).encode("utf-8"))
        self.assertFalse(receipt["valid"])
        self.assertTrue(any("platform does not match" in item for item in receipt["errors"]))

        runtime = json.loads(
            (PACKAGE_ROOT / "results" / "PRIME_REMOTE_RUNTIME_PROBE.json").read_text(
                encoding="utf-8"
            )
        )
        runtime["failureBoundUSD"] = runtime["hardAdmissionCapUSD"] + 0.01
        receipt = validate_bytes(json.dumps(runtime).encode("utf-8"))
        self.assertFalse(receipt["valid"])
        self.assertTrue(any("hard admission cap" in item for item in receipt["errors"]))

    @unittest.skipUnless(JSONSCHEMA_AVAILABLE, "jsonschema is not installed")
    def test_paired_comparison_validation_recomputes_promotion_policy(self) -> None:
        def result(identifier: str, score: float, candidate_id: str) -> EpisodeResult:
            return EpisodeResult(
                episode_id=identifier,
                candidate_id=candidate_id,
                score=score,
                dimensions={},
                checks={},
                command_count=1,
                invalid_command_count=0,
                duration_ms=1,
                safety_passed=True,
                source_preserved=True,
                margin_sha256="0" * 64,
            )

        baseline = [result(f"episode-{index}", 50, "baseline") for index in range(20)]
        candidate = [result(f"episode-{index}", 60, "candidate") for index in range(20)]
        comparison = paired_compare(baseline, candidate)
        self.assertTrue(comparison["promotable"])
        self.assertTrue(validate_bytes(json.dumps(comparison).encode("utf-8"))["valid"])
        comparison["losses"] = 1
        receipt = validate_bytes(json.dumps(comparison).encode("utf-8"))
        self.assertFalse(receipt["valid"])
        self.assertTrue(any("win/tie/loss" in item for item in receipt["errors"]))

    @unittest.skipUnless(JSONSCHEMA_AVAILABLE, "jsonschema is not installed")
    def test_reference_run_validation_checks_result_events_and_pass_flag(self) -> None:
        episode = generate_episode("human_agent_relay", KEY, 0)
        with tempfile.TemporaryDirectory(prefix="marginbench-reference-validation-") as temporary:
            result = run_episode(
                episode,
                self.binary,
                Path(temporary) / "workspace",
                ReferenceDriver(),
            )
        artifact = {
            "schema": "urn:marginbench:reference-run:v1",
            "paidModelsInvoked": False,
            "passed": True,
            "results": [result.to_dict()],
        }
        self.assertTrue(validate_bytes(json.dumps(artifact).encode("utf-8"))["valid"])
        with tempfile.TemporaryDirectory(prefix="marginbench-load-results-") as temporary:
            artifact_path = Path(temporary) / "reference.json"
            artifact_path.write_text(json.dumps(artifact), encoding="utf-8")
            loaded = load_results(artifact_path)
            self.assertEqual(len(loaded), 1)
            self.assertEqual(loaded[0].events, result.events)
        artifact["results"][0]["command_count"] += 1
        receipt = validate_bytes(json.dumps(artifact).encode("utf-8"))
        self.assertFalse(receipt["valid"])
        self.assertTrue(any("event count" in item for item in receipt["errors"]))
        with tempfile.TemporaryDirectory(prefix="marginbench-reject-results-") as temporary:
            artifact_path = Path(temporary) / "reference.json"
            artifact_path.write_text(json.dumps(artifact), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "event count"):
                load_results(artifact_path)

    @unittest.skipUnless(JSONSCHEMA_AVAILABLE, "jsonschema is not installed")
    def test_validate_command_accepts_bounded_stdin_and_uses_data_error_exit(self) -> None:
        artifact = (PACKAGE_ROOT / "results" / "EXPERIMENT_LEDGER.json").read_bytes()
        environment = dict(os.environ)
        environment["PYTHONPATH"] = str(PACKAGE_ROOT)
        valid = subprocess.run(
            [sys.executable, "-m", "marginbench.cli", "validate", "-"],
            input=artifact,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=environment,
            check=False,
        )
        self.assertEqual(valid.returncode, 0, valid.stderr.decode("utf-8", errors="replace"))
        self.assertTrue(json.loads(valid.stdout)["valid"])
        invalid = subprocess.run(
            [sys.executable, "-m", "marginbench.cli", "validate", "-"],
            input=b'{"schema":"unknown"}',
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=environment,
            check=False,
        )
        self.assertEqual(invalid.returncode, 65)
        receipt = json.loads(invalid.stdout)
        self.assertFalse(receipt["valid"])
        self.assertEqual(receipt["error"]["code"], "UNSUPPORTED_SCHEMA")
        self.assertEqual(invalid.stderr, b"")


if __name__ == "__main__":
    unittest.main()
