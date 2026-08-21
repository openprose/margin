from __future__ import annotations

import importlib.util
import http.client
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from concurrent.futures import ThreadPoolExecutor
from dataclasses import asdict
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import httpx

from marginbench.binary import resolve_margin_binary, validate_packaged_binary
from marginbench.budget_proxy import (
    InferenceBudgetGate,
    InferenceBudgetPolicy,
    InferenceBudgetProxy,
    InferenceRequestPacer,
)
from marginbench.candidates import CandidateManifest, load_results, paired_compare
from marginbench.controls import (
    DEFAULT_CONTROL_PROFILE,
    control_catalog,
    planned_topology,
    require_implemented_profile,
)
from marginbench.diagnostics import (
    DiagnosticError,
    _unfinished_after_stop,
    diagnose_artifacts,
)
from marginbench.entropy import PUBLIC_DEVELOPMENT_KEY
from marginbench.event_summary import SAFE_ERROR_CODES, summarize_command_events
from marginbench.fake_model import scripted_response
from marginbench.gateway import (
    BOOLEAN_OPTIONS,
    VALUE_OPTIONS,
    CommandRendezvous,
    MarginGateway,
    _error_code,
    event_command_path,
    read_command_events,
)
from marginbench.keys import create_holdout_key
from marginbench.phase_identity import PhaseIdentityController, read_phase_identity
from marginbench.provenance import implementation_files, implementation_sha256
from marginbench.reference_study import ReferenceStudyError, run_reference_study
from marginbench.runner import ReferenceDriver, run_episode
from marginbench.scenarios import (
    AVAILABLE_SCENARIO_IDS,
    EXPERIMENTAL_SCENARIO_IDS,
    SCENARIO_IDS,
    generate_episode,
)
from marginbench.schema import Actor, CommandEvent, EpisodeResult, RoleTask, canonical_json
from marginbench.scorer import _id_matches, score_episode
from marginbench.scheduling import build_execution_plan
from marginbench.studies import build_study_plan
from marginbench.submission import SubmissionError, build_submission, verify_submission
from marginbench.trace_shapes import summarize_trace_shapes
from marginbench.validation import submission_identifier, validate_artifact, validate_bytes
from prime_pilot import (
    DEFAULT_PROVIDER_RESPONSE_TOKEN_ALLOWANCE,
    _create_private_output_directory,
    _effective_stop_condition,
    _execution_status,
    _infrastructure_codes,
    _run_manifest,
    _summarize_traces,
    _require_fresh_output_targets,
    _write_new_artifact,
    agent_process_count,
    build_eval_command,
    claim_paid_start,
    estimate_maximum_cost,
    load_prime_inference_credentials,
    load_candidate_manifest,
    load_holdout_key,
    wallet,
)
from preflight import _expected_trace_count, _find_scores, _subprocess_environment


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


class ReferencePlusRedundantDiscoveryDriver:
    def run(self, episode, role, gateway) -> None:
        gateway.call(["context", ".", "--json", "--max-files", "16"])
        gateway.call(["inbox", ".", "--status", "open", "--max-contributions", "64"])
        ReferenceDriver().run(episode, role, gateway)


class WideTriageWrongDiscoveryOrderDriver:
    def run(self, episode, role, gateway) -> None:
        gateway.call(["inbox", ".", "--kind", "question", "--status", "open", "--brief"])
        gateway.call(["context", ".", "--json", "--brief"])
        ReferenceDriver().run(episode, role, gateway)


class MarginBenchCoreTests(unittest.TestCase):
    def test_completed_durable_work_is_not_mislabeled_as_budget_exhaustion(self) -> None:
        complete = {
            "stops": ["agent_completed", "max_turns"],
            "dimensions": {"outcome": 100.0},
            "checks": {
                "all_expected_annotations": True,
                "required_commands": True,
                "required_recovery_observed": True,
                "valid_command_use": True,
            },
        }
        self.assertFalse(_unfinished_after_stop(complete))

        incomplete = json.loads(json.dumps(complete))
        incomplete["checks"]["required_commands"] = False
        self.assertTrue(_unfinished_after_stop(incomplete))

    def setUp(self) -> None:
        self.binary = available_binary()
        if self.binary is None:
            self.skipTest(f"Build Margin first or install a packaged Linux artifact: {BINARY}")

    def test_plain_text_usage_exit_is_classified_without_retaining_its_message(self) -> None:
        self.assertEqual(
            _error_code("", "unknown manual topic", exit_code=64),
            "USAGE",
        )
        self.assertIsNone(_error_code("", "provider-specific text", exit_code=65))

    def test_reply_shorthand_is_scored_as_the_same_semantic_command(self) -> None:
        self.assertEqual(
            event_command_path([
                "comments", "add", "review.md", "--parent", "urn:uuid:parent",
                "-m", "Verified", "--id", "00000000-0000-4000-8000-000000000001",
            ]),
            "comments reply",
        )
        self.assertEqual(
            event_command_path([
                "comments", "reply", "review.md", "urn:uuid:parent", "-m", "Verified",
            ]),
            "comments reply",
        )
        self.assertEqual(
            event_command_path([
                "comments", "add", "review.md", "--parent", "urn:uuid:parent",
                "-m", "Verified", "--resolve",
            ]),
            "comments reply --resolve",
        )

    def test_help_is_never_counted_as_the_command_it_documents(self) -> None:
        self.assertEqual(event_command_path(["--help"]), "help")
        self.assertEqual(event_command_path(["man", "suggestions"]), "man suggestions")
        self.assertEqual(
            event_command_path(["suggest", "add", "--help"]),
            "help suggest add",
        )

    def test_command_rendezvous_releases_participants_together_and_only_once(self) -> None:
        with tempfile.TemporaryDirectory(prefix="marginbench-rendezvous-") as temporary:
            root = Path(temporary)
            workspace = root / "workspace"
            state = root / "state"
            workspace.mkdir()
            (workspace / "review.md").write_text("# Review\n", encoding="utf-8")
            rendezvous = CommandRendezvous(
                directory=root / "control",
                command="suggest add",
                target="review.md",
                participant_count=2,
                launch_delay_seconds=0.02,
                lock_hold_seconds=0.05,
                timeout_seconds=2,
            )

            started = time.perf_counter()
            with ThreadPoolExecutor(max_workers=2) as pool:
                futures = [
                    pool.submit(rendezvous.wait, role, workspace, state)
                    for role in ("author", "reviewer")
                ]
                for future in futures:
                    future.result()
            elapsed = time.perf_counter() - started
            self.assertGreaterEqual(elapsed, 0.015)
            self.assertLess(elapsed, 1)

            replay_started = time.perf_counter()
            rendezvous.wait("author", workspace, state)
            self.assertLess(time.perf_counter() - replay_started, 0.02)

    def test_refresh_submit_shortcut_receives_refresh_and_submission_credit(self) -> None:
        semantic_path = event_command_path([
            "stage", "refresh", ".", "urn:margin:stage:old",
            "--id", "urn:margin:stage:new", "--submit",
        ])
        self.assertEqual(semantic_path, "stage refresh --submit")
        self.assertTrue(semantic_path.startswith("stage refresh "))

    def test_gateway_option_registry_covers_every_advertised_option(self) -> None:
        capabilities = subprocess.run(
            [str(self.binary), "capabilities", "--json"],
            check=True,
            capture_output=True,
            text=True,
        )
        payload = json.loads(capabilities.stdout)
        advertised = {
            name
            for command in payload["commands"]
            for option in command["options"]
            for name in option["names"]
        }
        self.assertEqual(advertised - (BOOLEAN_OPTIONS | VALUE_OPTIONS), set())

    def test_trace_shape_reports_refresh_submit_as_a_known_flag(self) -> None:
        trace = {
            "traces": [{
                "task": {"data": {"scenario_id": "staged_multifile"}},
                "agent": {"name": "reviewer"},
                "nodes": [
                    {"message": {
                        "role": "assistant",
                        "tool_calls": [{
                            "id": "refresh-call",
                            "name": "margin",
                            "arguments": json.dumps({"arguments": [
                                "stage", "refresh", ".", "private-old-id",
                                "--id", "private-new-id", "--submit", "--json",
                            ]}),
                        }],
                    }},
                    {"message": {
                        "role": "tool",
                        "tool_call_id": "refresh-call",
                        "content": json.dumps({"ok": True}),
                    }},
                ],
            }],
        }
        with tempfile.TemporaryDirectory(prefix="marginbench-refresh-trace-") as temporary:
            path = Path(temporary) / "traces.jsonl"
            path.write_text(json.dumps(trace) + "\n", encoding="utf-8")
            report = summarize_trace_shapes([path])
        self.assertIn({"name": "--submit", "count": 1}, report["flags"])
        signature = report["commandSignatures"][0]
        self.assertEqual(signature["command"], "stage refresh --submit")
        self.assertIn("--submit", signature["flags"])

    def test_trace_shape_preserves_atomic_reply_resolution_semantics(self) -> None:
        trace = {
            "traces": [{
                "task": {"data": {"scenario_id": "directory_handoff"}},
                "agent": {"name": "reviewer"},
                "nodes": [
                    {"message": {
                        "role": "assistant",
                        "tool_calls": [{
                            "id": "reply-call",
                            "name": "margin",
                            "arguments": json.dumps({"arguments": [
                                "comments", "reply", "private.md", "private-id",
                                "-m", "private body", "--resolve",
                            ]}),
                        }],
                    }},
                    {"message": {
                        "role": "tool",
                        "tool_call_id": "reply-call",
                        "content": json.dumps({"ok": True, "exitCode": 0}),
                    }},
                ],
            }],
        }
        with tempfile.TemporaryDirectory(prefix="marginbench-resolve-trace-") as temporary:
            path = Path(temporary) / "traces.jsonl"
            path.write_text(json.dumps(trace) + "\n", encoding="utf-8")
            report = summarize_trace_shapes([path])
        self.assertEqual(report["commands"][0]["name"], "comments reply --resolve")
        self.assertEqual(
            report["scenarios"][0]["sequences"],
            [{"commands": ["comments reply --resolve"], "count": 1}],
        )

    def test_trace_shape_retains_only_static_manual_topics(self) -> None:
        secret = "private-man-topic"
        nodes = []
        for index, arguments in enumerate((["man", "handoffs"], ["man", secret])):
            identifier = f"call-{index}"
            nodes.extend([
                {"message": {
                    "role": "assistant",
                    "tool_calls": [{
                        "id": identifier,
                        "name": "margin",
                        "arguments": json.dumps({"arguments": arguments}),
                    }],
                }},
                {"message": {
                    "role": "tool",
                    "tool_call_id": identifier,
                    "content": json.dumps({"ok": True, "exitCode": 0}),
                }},
            ])
        trace = {"traces": [{
            "task": {"data": {"scenario_id": "distributed_synthesis"}},
            "agent": {"name": "author"},
            "nodes": nodes,
        }]}
        with tempfile.TemporaryDirectory(prefix="marginbench-man-trace-") as temporary:
            path = Path(temporary) / "traces.jsonl"
            path.write_text(json.dumps(trace) + "\n", encoding="utf-8")
            report = summarize_trace_shapes([path])
        encoded = canonical_json(report)
        self.assertNotIn(secret.encode("utf-8"), encoded)
        self.assertEqual(
            {item["name"] for item in report["commands"]},
            {"man", "man handoff"},
        )

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

    def test_model_output_limit_is_not_reported_as_deliberate_completion(self) -> None:
        self.assertEqual(
            _effective_stop_condition({
                "stop_condition": "agent_completed",
                "calls": [{"finish_reason": "length"}],
            }),
            "model_output_limit",
        )
        self.assertEqual(
            _effective_stop_condition({
                "stop_condition": "agent_completed",
                "calls": [{"finish_reason": "stop"}],
            }),
            "agent_completed",
        )
        self.assertEqual(
            _effective_stop_condition({
                "stop_condition": "max_turns",
                "calls": [{"finish_reason": "length"}],
            }),
            "max_turns",
        )

    def test_trace_shape_report_finds_command_friction_without_retaining_content(self) -> None:
        secret = "private-body-and-path-8e12"
        trace = {
            "traces": [{
                "task": {"data": {"scenario_id": "parallel_shards", "prompt": secret}},
                "agent": {"name": "author"},
                "calls": [{"finish_reason": "length"}],
                "stop_condition": "agent_completed",
                "nodes": [
                    {"message": {
                        "role": "assistant",
                        "tool_calls": [{
                            "id": "private-call-id",
                            "name": "margin",
                            "arguments": json.dumps({"arguments": [
                                "margin", "comments", "add", f"{secret}.md",
                                "--document", "-m", secret, "--contribution-id",
                                "private-contribution-id",
                            ]}),
                        }],
                    }},
                    {"message": {
                        "role": "tool",
                        "tool_call_id": "private-call-id",
                        "content": json.dumps({
                            "ok": False,
                            "exitCode": 64,
                            "errorCode": "MARGINBENCH_COMMAND_BLOCKED",
                            "stdout": None,
                            "stderr": {"private": secret},
                        }),
                    }},
                ],
            }],
        }
        with tempfile.TemporaryDirectory(prefix="marginbench-trace-shape-") as temporary:
            path = Path(temporary) / "traces.jsonl"
            path.write_text(json.dumps(trace) + "\n", encoding="utf-8")
            report = summarize_trace_shapes([path.parent])
        encoded = canonical_json(report).decode("utf-8")
        self.assertTrue(validate_bytes(encoded.encode("utf-8"))["valid"])
        self.assertNotIn(secret, encoded)
        self.assertNotIn("private-call-id", encoded)
        self.assertNotIn("private-contribution-id", encoded)
        self.assertEqual(report["leadingLiteralMarginCount"], 1)
        self.assertEqual(report["blockedCount"], 1)
        self.assertEqual(report["writeLatency"], {
            "traceCount": 1,
            "tracesWithWriteAttempt": 1,
            "tracesWithoutWriteAttempt": 0,
            "writeAttemptCount": 1,
            "preWriteToolCallBuckets": [{"name": "0", "count": 1}],
        })
        self.assertEqual(report["commands"][0]["name"], "comments add")
        self.assertEqual(
            report["commandSignatures"],
            [{
                "command": "comments add",
                "flags": ["--contribution-id", "--document", "-m"],
                "count": 1,
                "successCount": 0,
                "failureCount": 1,
                "blockedCount": 1,
                "errors": [{"name": "MARGINBENCH_COMMAND_BLOCKED", "count": 1}],
                "resultSizeBuckets": [{"name": "1-1024", "count": 1}],
            }],
        )
        self.assertEqual(report["errors"][0]["name"], "MARGINBENCH_COMMAND_BLOCKED")
        self.assertIn({"name": "--contribution-id", "count": 1}, report["flags"])
        self.assertEqual(report["resultSizeBuckets"], [{"name": "1-1024", "count": 1}])
        self.assertEqual(
            report["commandResultSizeBuckets"],
            [{
                "command": "comments add",
                "buckets": [{"name": "1-1024", "count": 1}],
            }],
        )
        self.assertFalse(report["privacy"]["exactResultSizesRetained"])
        self.assertEqual(report["finalFinishReasons"], [{"name": "length", "count": 1}])
        self.assertEqual(report["stopConditions"], [{"name": "agent_completed", "count": 1}])
        self.assertEqual(
            report["scenarios"][0]["finalFinishReasons"],
            [{"name": "length", "count": 1}],
        )
        self.assertEqual(report["scenarios"][0]["commands"], report["commands"])
        self.assertEqual(report["scenarios"][0]["errors"], report["errors"])
        self.assertEqual(report["scenarios"][0]["flags"], report["flags"])
        self.assertEqual(report["scenarios"][0]["sequences"], report["sequences"])
        tampered = json.loads(json.dumps(report))
        tampered["resultSizeBuckets"][0]["count"] = 2
        receipt = validate_bytes(canonical_json(tampered))
        self.assertFalse(receipt["valid"])
        self.assertTrue(any("result-size" in error for error in receipt["errors"]))

    def test_trace_shape_report_understands_plain_workspace_without_retaining_content(self) -> None:
        secret = "private-plain-body-and-path-2a71"
        trace = {
            "traces": [{
                "task": {"data": {"scenario_id": "parallel_shards", "prompt": secret}},
                "agent": {"name": "reviewer"},
                "nodes": [
                    {"message": {
                        "role": "assistant",
                        "tool_calls": [{
                            "id": "private-read-id",
                            "name": "workspace",
                            "arguments": json.dumps({
                                "action": "read",
                                "path": f"{secret}.md",
                            }),
                        }],
                    }},
                    {"message": {
                        "role": "tool",
                        "tool_call_id": "private-read-id",
                        "content": json.dumps({
                            "ok": True,
                            "result": {"text": secret, "sha256": "0" * 64},
                        }),
                    }},
                    {"message": {
                        "role": "assistant",
                        "tool_calls": [{
                            "id": "private-write-id",
                            "name": "workspace",
                            "arguments": json.dumps({
                                "action": "write",
                                "path": f"{secret}.md",
                                "text": secret,
                                "if_sha256": "0" * 64,
                            }),
                        }],
                    }},
                    {"message": {
                        "role": "tool",
                        "tool_call_id": "private-write-id",
                        "content": json.dumps({
                            "ok": False,
                            "error": {"code": "PRECONDITION_FAILED", "message": secret},
                        }),
                    }},
                ],
            }],
        }
        with tempfile.TemporaryDirectory(prefix="marginbench-plain-trace-shape-") as temporary:
            path = Path(temporary) / "traces.jsonl"
            path.write_text(json.dumps(trace) + "\n", encoding="utf-8")
            report = summarize_trace_shapes([path])
        encoded = canonical_json(report).decode("utf-8")
        self.assertTrue(validate_bytes(encoded.encode("utf-8"))["valid"])
        self.assertNotIn(secret, encoded)
        self.assertEqual(report["successCount"], 1)
        self.assertEqual(report["failureCount"], 1)
        self.assertEqual(report["blockedCount"], 0)
        self.assertEqual(report["unansweredToolCallCount"], 0)
        self.assertEqual(
            [item["name"] for item in report["commands"]],
            ["workspace read", "workspace write"],
        )
        self.assertEqual(report["errors"], [{"name": "PRECONDITION_FAILED", "count": 1}])
        self.assertEqual(
            report["writeLatency"]["preWriteToolCallBuckets"],
            [{"name": "1-2", "count": 1}],
        )

    def test_trace_shape_report_counts_an_unanswered_workspace_call(self) -> None:
        trace = {
            "traces": [{
                "task": {"data": {"scenario_id": "parallel_shards"}},
                "agent": {"name": "reviewer"},
                "nodes": [{"message": {
                    "role": "assistant",
                    "tool_calls": [{
                        "id": "pending-call",
                        "name": "workspace",
                        "arguments": json.dumps({"action": "read", "path": "private.md"}),
                    }],
                }}],
            }],
        }
        with tempfile.TemporaryDirectory(prefix="marginbench-pending-trace-shape-") as temporary:
            path = Path(temporary) / "traces.jsonl"
            path.write_text(json.dumps(trace) + "\n", encoding="utf-8")
            report = summarize_trace_shapes([path])
        self.assertTrue(validate_bytes(canonical_json(report))["valid"])
        self.assertEqual(report["toolCallCount"], 0)
        self.assertEqual(report["unansweredToolCallCount"], 1)
        self.assertEqual(
            report["unansweredCommands"],
            [{"name": "workspace read", "count": 1}],
        )
        self.assertEqual(
            report["scenarios"][0]["unansweredCommands"],
            [{"name": "workspace read", "count": 1}],
        )
        self.assertEqual(
            report["writeLatency"]["preWriteToolCallBuckets"],
            [{"name": "none", "count": 1}],
        )

    def test_trace_shape_counts_unanswered_write_after_coarse_orientation_without_content(self) -> None:
        secret = "private-orientation-marker-d49b"
        nodes = []
        for index, arguments in enumerate((
            ["man", "agents"],
            ["capabilities", "--json", "--for", "handoff", "--brief"],
            ["context", ".", "--json", "--brief"],
            ["inbox", ".", "--status", "open"],
            ["handoff", "list", "."],
            ["comments", "list", f"{secret}.md"],
            ["comments", "get", f"{secret}.md", secret],
        )):
            call_id = f"read-{index}"
            nodes.extend([
                {"message": {"role": "assistant", "tool_calls": [{
                    "id": call_id,
                    "name": "margin",
                    "arguments": json.dumps({"arguments": arguments}),
                }]}},
                {"message": {
                    "role": "tool",
                    "tool_call_id": call_id,
                    "content": json.dumps({"ok": True, "exitCode": 0, "stdout": secret}),
                }},
            ])
        nodes.append({"message": {"role": "assistant", "tool_calls": [{
            "id": "unanswered-write",
            "name": "margin",
            "arguments": json.dumps({"arguments": [
                "handoff", "add", f"{secret}.md", "-m", secret,
            ]}),
        }]}})
        trace = {"traces": [{
            "task": {"data": {"scenario_id": "directory_handoff", "prompt": secret}},
            "agent": {"name": "author"},
            "nodes": nodes,
        }]}
        with tempfile.TemporaryDirectory(prefix="marginbench-write-latency-") as temporary:
            path = Path(temporary) / "traces.jsonl"
            path.write_text(json.dumps(trace) + "\n", encoding="utf-8")
            report = summarize_trace_shapes([path])
        encoded = canonical_json(report).decode("utf-8")
        self.assertTrue(validate_bytes(encoded.encode("utf-8"))["valid"])
        self.assertNotIn(secret, encoded)
        self.assertEqual(report["unansweredCommands"], [{"name": "handoff add", "count": 1}])
        self.assertEqual(report["writeLatency"], {
            "traceCount": 1,
            "tracesWithWriteAttempt": 1,
            "tracesWithoutWriteAttempt": 0,
            "writeAttemptCount": 1,
            "preWriteToolCallBuckets": [{"name": "7+", "count": 1}],
        })
        tampered = json.loads(encoded)
        tampered["writeLatency"]["tracesWithoutWriteAttempt"] = 1
        self.assertFalse(validate_bytes(canonical_json(tampered))["valid"])

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
        self.assertEqual(expected_roles, 17)

        handoff = generate_episode("agent_agent_handoff", KEY, 0)
        continued = scripted_response([
            {"role": "user", "content": handoff.roles[0].prompt},
            {"role": "assistant", "content": "First phase complete."},
            {"role": "user", "content": handoff.roles[1].prompt},
        ])
        self.assertEqual(continued["arguments"][:2], ["handoff", "list"])

    def test_fake_concurrent_agent_retries_after_a_real_write_conflict(self) -> None:
        episode = generate_episode("concurrent_review", KEY, 0)
        messages = [{"role": "user", "content": episode.roles[0].prompt}]
        self.assertEqual(scripted_response(messages)["arguments"][:2], ["comments", "add"])
        messages.append({
            "role": "tool",
            "content": json.dumps({
                "exitCode": 75,
                "errorCode": "COLLABORATION_PRECONDITION_FAILED",
            }),
        })
        self.assertEqual(scripted_response(messages)["arguments"][:2], ["comments", "list"])
        messages.append({"role": "tool", "content": json.dumps({"exitCode": 0})})
        self.assertEqual(scripted_response(messages)["arguments"][:2], ["comments", "add"])
        messages.append({"role": "tool", "content": json.dumps({"exitCode": 0})})
        self.assertEqual(scripted_response(messages)["arguments"][:2], ["comments", "list"])

    def test_preflight_collects_every_trace_reward_from_a_batched_envelope(self) -> None:
        envelope = {
            "traces": [
                {"rewards": {"marginbench": {"score": 1.0}}},
                {"rewards": {"marginbench": {"score": 0.75}}},
            ]
        }
        self.assertEqual(_find_scores(envelope), [1.0, 0.75])

    def test_preflight_counts_traces_from_the_selected_agent_topology(self) -> None:
        self.assertEqual(
            _expected_trace_count("role-separated-margin-only-v1", KEY),
            17,
        )
        self.assertEqual(_expected_trace_count("single-agent-margin-v1", KEY), 9)

        wide = generate_episode("wide_directory_triage", KEY, 0)
        self.assertEqual(
            scripted_response([{"role": "user", "content": wide.roles[0].prompt}])["arguments"],
            ["context", ".", "--json", "--brief"],
        )

    def test_preflight_uses_only_an_explicit_holdout_key(self) -> None:
        variable = "MARGINBENCH_HOLDOUT_KEY"
        with patch.dict(os.environ, {variable: "ambient-secret-must-not-be-used"}):
            public_environment = _subprocess_environment(None)
            private_environment = _subprocess_environment(b"explicit-private-test-key")
            self.assertEqual(os.environ[variable], "ambient-secret-must-not-be-used")
        self.assertNotIn(variable, public_environment)
        self.assertEqual(private_environment[variable], "explicit-private-test-key")

    def test_public_event_summary_is_exact_bounded_and_content_free(self) -> None:
        events = (
            CommandEvent(
                role="author",
                command="stage create",
                exit_code=64,
                duration_ms=1,
                stdin_bytes=123,
                stdout_bytes=0,
                stderr_bytes=456,
                error_code="USAGE",
            ),
            CommandEvent(
                role="reviewer",
                command="merge private/secret-plan.md",
                exit_code=65,
                duration_ms=2,
                stdin_bytes=0,
                stdout_bytes=789,
                stderr_bytes=1,
                error_code="SECRET_IDENTIFIER",
            ),
            CommandEvent(
                role="reviewer",
                command="stage refresh --submit",
                exit_code=0,
                duration_ms=3,
                stdin_bytes=0,
                stdout_bytes=1,
                stderr_bytes=0,
            ),
        )
        summary = summarize_command_events(events)
        self.assertEqual(summary["commandCount"], 3)
        self.assertEqual(summary["successCount"], 1)
        self.assertEqual(summary["failureCount"], 2)
        self.assertEqual(summary["blockedCount"], 0)
        self.assertEqual(
            summary["errors"],
            [{"name": "UNCLASSIFIED", "count": 1}, {"name": "USAGE", "count": 1}],
        )
        self.assertEqual(
            {item["name"] for item in summary["commands"]},
            {"merge", "stage create", "stage refresh --submit"},
        )
        encoded = canonical_json(summary)
        for private_value in (
            b"private", b"secret", b"SECRET_IDENTIFIER", b"author", b"reviewer",
            b"123", b"456", b"789",
        ):
            self.assertNotIn(private_value, encoded)

        bounded = summarize_command_events(tuple(
            CommandEvent(
                role="author",
                command="context",
                exit_code=65,
                duration_ms=1,
                stdin_bytes=0,
                stdout_bytes=0,
                stderr_bytes=0,
                error_code=code,
            )
            for code in sorted(SAFE_ERROR_CODES)
        ))
        self.assertEqual(len(bounded["errors"]), 64)
        self.assertTrue(bounded["isTruncated"])
        self.assertEqual(sum(item["count"] for item in bounded["errors"]), len(SAFE_ERROR_CODES))
        self.assertIn({"name": "OTHER", "count": len(SAFE_ERROR_CODES) - 63}, bounded["errors"])

    def test_prime_summary_aggregates_roles_into_one_schema_valid_episode(self) -> None:
        margin_sha256 = CandidateManifest.create("summary-test", self.binary).margin_sha256
        result = {
            "episodeID": "agent_agent_handoff:0:" + "a" * 12,
            "score": 100.0,
            "safetyPassed": True,
            "sourcePreserved": True,
            "commandCount": 7,
            "invalidCommandCount": 0,
            "eventSummary": summarize_command_events(tuple(
                CommandEvent(
                    role="author",
                    command="context",
                    exit_code=0,
                    duration_ms=1,
                    stdin_bytes=0,
                    stdout_bytes=0,
                    stderr_bytes=0,
                )
                for _ in range(7)
            )),
            "durationMs": 12.5,
            "marginSha256": margin_sha256,
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
        self.assertEqual(summary["episodes"][0]["eventSummary"]["commandCount"], 7)
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
            wall_timeout_seconds=300.0,
            live_proxy_timeout_seconds=120.0,
            minimum_start_interval_seconds=300.0,
            temperature=0.0,
            prior_infrastructure_attempts=0,
            scenario=["agent_agent_handoff"],
            repetitions=1,
            input_price_per_million=0.03,
            output_price_per_million=0.13,
            max_cost_usd=1.0,
            control_profile=DEFAULT_CONTROL_PROFILE,
        )
        live_budget = {
            "enabled": True,
            "forwardedRequestCount": 2,
            "rejectedRequestCount": 0,
            "reservedCostUpperBoundUSD": 0.001,
            "reportedPromptTokens": 1000,
            "reportedCompletionTokens": 100,
            "reportedTokenCostUSD": 0.000043,
            "policy": {
                "allowedModel": "test/model",
                "maxRequestBytes": 4096,
                "templateTokenAllowance": 128,
                "inputTokenCeiling": 4096,
                "maxOutputTokens": 250,
                "inputPricePerMillion": 0.03,
                "outputPricePerMillion": 0.13,
                "billingOverheadUSDPerCall": 0.0002,
                "maxTotalCostUSD": 1.0,
            },
        }
        manifest = _run_manifest(
            arguments,
            summary,
            status="completed",
            started_at="2026-08-18T00:00:00Z",
            duration_ms=123,
            observed_wallet_debit=0.003,
            live_budget=live_budget,
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
        self.assertEqual(manifest["cost"]["liveBudget"], live_budget)
        self.assertTrue(validate_bytes(canonical_json(manifest))["valid"])
        violating_manifest = json.loads(json.dumps(manifest))
        violating_manifest["cost"]["liveBudget"].update({
            "providerBoundViolationCount": 1,
            "latchedClosed": True,
        })
        violation_receipt = validate_bytes(canonical_json(violating_manifest))
        self.assertFalse(violation_receipt["valid"])
        self.assertTrue(any(
            "provider reported usage outside" in error
            for error in violation_receipt["errors"]
        ))
        infrastructure_manifest = json.loads(json.dumps(violating_manifest))
        infrastructure_manifest["status"] = "infrastructure-error"
        self.assertTrue(validate_bytes(canonical_json(infrastructure_manifest))["valid"])
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
        self.assertTrue(validate_bytes(canonical_json(manifest))["valid"])

    def test_single_agent_accounting_preserves_logical_actors_and_sums_limits(self) -> None:
        episode = generate_episode("agent_agent_handoff", KEY, 0)
        result = {
            "episodeID": episode.public_id,
            "score": 100.0,
            "safetyPassed": True,
            "sourcePreserved": True,
            "commandCount": 4,
            "invalidCommandCount": 0,
            "durationMs": 10.0,
            "marginSha256": CandidateManifest.create("single", self.binary).margin_sha256,
            "checks": {"valid_documents": True},
            "dimensions": {"outcome": 100.0},
            "controlProfile": "single-agent-margin-v1",
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
            **planned_topology(
                "single-agent-margin-v1",
                [role.seat for role in episode.roles],
            ),
        }
        trace = {
            "task": {"data": {
                "name": f"{episode.public_id}:agent",
                "scenario_id": episode.scenario_id,
                "repetition": episode.repetition,
                "fingerprint": episode.fingerprint,
            }},
            "calls": [],
            "info": {"marginbench": result},
            "stop_condition": "agent_completed",
        }
        with tempfile.TemporaryDirectory(prefix="marginbench-single-summary-") as temporary:
            output = Path(temporary)
            (output / "traces.jsonl").write_text(
                json.dumps({"traces": [trace]}) + "\n",
                encoding="utf-8",
            )
            summary = _summarize_traces(output)

        self.assertEqual(summary["traceCount"], 1)
        self.assertEqual(summary["episodes"][0]["traceSeats"], ["agent"])
        self.assertEqual(
            [actor["seat"] for actor in summary["episodes"][0]["logicalActors"]],
            [role.seat for role in episode.roles],
        )
        arguments = SimpleNamespace(
            candidate="single",
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
            wall_timeout_seconds=300.0,
            live_proxy_timeout_seconds=120.0,
            minimum_start_interval_seconds=300.0,
            temperature=0.0,
            prior_infrastructure_attempts=0,
            scenario=[episode.scenario_id],
            repetitions=1,
            input_price_per_million=0.03,
            output_price_per_million=0.13,
            max_cost_usd=1.0,
            control_profile="single-agent-margin-v1",
        )
        manifest = _run_manifest(
            arguments,
            summary,
            status="completed",
            started_at="2026-08-18T00:00:00Z",
            duration_ms=10,
            observed_wallet_debit=0,
        )
        self.assertEqual(manifest["execution"]["agentProcessCount"], 1)
        self.assertEqual(manifest["execution"]["roles"], ["author", "reviewer"])
        self.assertEqual(manifest["execution"]["traceSeats"], ["agent"])
        self.assertEqual(manifest["cost"]["boundBasis"]["modelCallsPerAgentAtMost"], 8)
        self.assertTrue(validate_bytes(canonical_json(manifest))["valid"])
        tampered = json.loads(json.dumps(manifest))
        tampered["episodes"][0]["agentProcessCount"] = 2
        receipt = validate_bytes(canonical_json(tampered))
        self.assertFalse(receipt["valid"])
        self.assertTrue(any("topology is inconsistent" in item for item in receipt["errors"]))
        tampered = json.loads(json.dumps(manifest))
        tampered["execution"]["agentProcessCount"] = 2
        receipt = validate_bytes(canonical_json(tampered))
        self.assertFalse(receipt["valid"])
        self.assertTrue(any("process count differs" in item for item in receipt["errors"]))

        command = build_eval_command(arguments, Path("/prime/eval"), Path("/output"))
        self.assertEqual(command[command.index("--env.author.max-turns") + 1], "8")
        self.assertEqual(command[command.index("--env.reviewer.max-turns") + 1], "4")
        self.assertEqual(
            agent_process_count(
                [episode.scenario_id],
                1,
                control_profile="single-agent-margin-v1",
            ),
            1,
        )
        mixed = SimpleNamespace(
            **{
                **vars(arguments),
                "scenario": ["human_agent_relay", "agent_agent_handoff"],
            }
        )
        with self.assertRaisesRegex(ValueError, "one logical-role count"):
            build_eval_command(mixed, Path("/prime/eval"), Path("/output"))

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
        self.assertEqual(len(schemas), 47)
        self.assertIn("urn:marginbench:crossover-prime-plan:v1", schemas)
        self.assertIn("urn:marginbench:crossover-prime-completion:v1", schemas)

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
        self.assertEqual(plan["episodeCount"], 36)
        self.assertEqual(plan["controlProfile"], DEFAULT_CONTROL_PROFILE)
        self.assertTrue(plan["sampleSizeSufficient"])
        self.assertEqual(plan["totalRoleRuns"], plan["roleRunsPerCandidate"] * 2)
        self.assertEqual(plan["agentProcessesPerCandidate"], plan["roleRunsPerCandidate"])
        self.assertEqual(plan["totalAgentProcesses"], plan["totalRoleRuns"])
        orders = [tuple(item["candidateOrder"]) for item in plan["episodes"]]
        self.assertEqual(orders.count(("baseline", "candidate-v2")), 18)
        self.assertEqual(orders.count(("candidate-v2", "baseline")), 18)
        encoded = json.dumps(plan)
        self.assertNotIn("oracle", encoded)
        self.assertNotIn("prompt", encoded)
        try:
            from jsonschema import Draft202012Validator
        except ImportError:
            return
        schema = json.loads((SCHEMA_ROOT / "study-plan.schema.json").read_text(encoding="utf-8"))
        Draft202012Validator(schema).validate(plan)

    def test_single_agent_control_is_compute_matched_and_runnable(self) -> None:
        profile = "single-agent-margin-v1"
        plan = build_study_plan(
            baseline="baseline",
            candidate="candidate-v2",
            scenarios=list(SCENARIO_IDS),
            repetitions=4,
            key=KEY,
            development_cases=False,
            control_profile=profile,
        )
        self.assertEqual(plan["controlProfile"], profile)
        self.assertEqual(plan["agentProcessesPerCandidate"], plan["episodeCount"])
        self.assertEqual(plan["totalAgentProcesses"], plan["episodeCount"] * 2)
        self.assertGreater(plan["roleRunsPerCandidate"], plan["agentProcessesPerCandidate"])
        for episode in plan["episodes"]:
            self.assertEqual(episode["agentProcessCount"], 1)
            self.assertEqual(episode["traceSeats"], ["agent"])
            self.assertEqual(episode["phasePolicy"], "serial-stable-role-order")
        self.assertTrue(validate_bytes(canonical_json(plan))["valid"])
        self.assertEqual(require_implemented_profile(profile)["blockingGates"], [])
        self.assertEqual(
            planned_topology(profile, ["author", "reviewer"]),
            {
                "agentProcessCount": 1,
                "traceSeats": ["agent"],
                "phasePolicy": "serial-stable-role-order",
            },
        )
        with tempfile.TemporaryDirectory(prefix="marginbench-single-control-plan-") as temporary:
            study_path = Path(temporary) / "study.json"
            study_path.write_bytes(canonical_json(plan))
            execution = build_execution_plan(study_path)
        self.assertEqual(execution["agentProcessCount"], plan["totalAgentProcesses"])
        self.assertEqual(execution["roleProcessCount"], plan["totalRoleRuns"])
        self.assertTrue(all(job["agentProcessCount"] == 1 for job in execution["jobs"]))
        self.assertTrue(validate_bytes(canonical_json(execution))["valid"])
        environment = dict(os.environ)
        environment["PYTHONPATH"] = str(PACKAGE_ROOT)
        completed = subprocess.run(
            [
                sys.executable, "-m", "marginbench.cli", "study-plan",
                "--baseline", "baseline", "--candidate", "candidate-v2",
                "--scenario", "human_agent_relay", "--repetitions", "1",
                "--control-profile", profile,
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=environment,
            check=False,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr.decode(errors="replace"))
        cli_plan = json.loads(completed.stdout)
        self.assertEqual(cli_plan["agentProcessesPerCandidate"], 1)
        self.assertEqual(cli_plan["episodes"][0]["traceSeats"], ["agent"])

    @unittest.skipUnless(JSONSCHEMA_AVAILABLE, "jsonschema is not installed")
    def test_execution_plan_flattens_study_order_deterministically(self) -> None:
        study = build_study_plan(
            baseline="baseline",
            candidate="candidate-v2",
            scenarios=list(SCENARIO_IDS),
            repetitions=4,
            key=KEY,
            development_cases=False,
        )
        with tempfile.TemporaryDirectory(prefix="marginbench-execution-plan-") as temporary:
            path = Path(temporary) / "study.json"
            path.write_text(json.dumps(study), encoding="utf-8")
            plan = build_execution_plan(path)
            self.assertEqual(plan, build_execution_plan(path))
            self.assertEqual(plan["episodeCount"], 36)
            self.assertEqual(plan["jobCount"], 72)
            self.assertEqual(plan["roleProcessCount"], study["totalRoleRuns"])
            self.assertEqual(plan["agentProcessCount"], study["totalAgentProcesses"])
            first = [job["candidateID"] for job in plan["jobs"] if job["candidatePosition"] == 0]
            self.assertEqual(first.count("baseline"), 18)
            self.assertEqual(first.count("candidate-v2"), 18)
            self.assertTrue(validate_bytes(json.dumps(plan).encode("utf-8"))["valid"])
            encoded = json.dumps(plan)
            self.assertNotIn("oracle", encoded)
            self.assertNotIn("prompt", encoded)

            environment = dict(os.environ)
            environment["PYTHONPATH"] = str(PACKAGE_ROOT)
            completed = subprocess.run(
                [sys.executable, "-m", "marginbench.cli", "execution-plan", str(path)],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env=environment,
                check=False,
            )
            self.assertEqual(completed.returncode, 0, completed.stderr.decode(errors="replace"))
            self.assertEqual(json.loads(completed.stdout), plan)

            plan["jobs"][0]["ordinal"] = 1
            receipt = validate_bytes(json.dumps(plan).encode("utf-8"))
            self.assertFalse(receipt["valid"])
            self.assertTrue(any("ordinals" in item for item in receipt["errors"]))

    @unittest.skipUnless(JSONSCHEMA_AVAILABLE, "jsonschema is not installed")
    def test_reference_study_runs_both_candidates_and_builds_verified_bundle(self) -> None:
        with tempfile.TemporaryDirectory(prefix="marginbench-reference-study-") as temporary:
            root = Path(temporary)
            baseline = CandidateManifest.create(
                "baseline",
                self.binary,
                settings={"guidance": "baseline"},
            )
            candidate = CandidateManifest.create(
                "candidate",
                self.binary,
                settings={"guidance": "candidate"},
            )
            study = build_study_plan(
                baseline=baseline.id,
                candidate=candidate.id,
                scenarios=["human_agent_relay"],
                repetitions=1,
                key=PUBLIC_DEVELOPMENT_KEY,
                development_cases=True,
            )
            baseline_path = root / "baseline.json"
            candidate_path = root / "candidate.json"
            study_path = root / "study.json"
            baseline_path.write_text(json.dumps(asdict(baseline)), encoding="utf-8")
            candidate_path.write_text(json.dumps(asdict(candidate)), encoding="utf-8")
            study_path.write_text(json.dumps(study), encoding="utf-8")
            execution_path = root / "execution.json"
            execution_path.write_text(
                json.dumps(build_execution_plan(study_path)),
                encoding="utf-8",
            )
            output = root / "publication"
            receipt = run_reference_study(
                output,
                study_plan=study_path,
                execution_plan=execution_path,
                baseline_manifest=baseline_path,
                baseline_binary=self.binary,
                candidate_manifest=candidate_path,
                candidate_binary=self.binary,
                package_root=PACKAGE_ROOT,
            )
            self.assertTrue(receipt["verified"])
            self.assertFalse(receipt["paidModelsInvoked"])
            self.assertEqual(receipt["jobCount"], 2)
            self.assertEqual(receipt["baselineMinimumScore"], 100)
            self.assertEqual(receipt["candidateMinimumScore"], 100)
            self.assertTrue(validate_bytes(json.dumps(receipt).encode("utf-8"))["valid"])
            verification = verify_submission(output / "submission.json")
            self.assertTrue(verification["valid"], verification)
            comparison = json.loads((output / "comparison.json").read_text(encoding="utf-8"))
            self.assertEqual(comparison["ties"], 1)
            self.assertFalse(comparison["promotable"])
            self.assertFalse((output / "raw-traces").exists())
            cli_output = root / "publication-cli"
            environment = dict(os.environ)
            environment["PYTHONPATH"] = str(PACKAGE_ROOT)
            completed = subprocess.run(
                [
                    sys.executable,
                    "-m",
                    "marginbench.cli",
                    "reference-study",
                    str(cli_output),
                    "--study-plan",
                    str(study_path),
                    "--execution-plan",
                    str(execution_path),
                    "--baseline-manifest",
                    str(baseline_path),
                    "--baseline-bin",
                    str(self.binary),
                    "--candidate-manifest",
                    str(candidate_path),
                    "--candidate-bin",
                    str(self.binary),
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env=environment,
                check=False,
            )
            self.assertEqual(completed.returncode, 0, completed.stderr.decode(errors="replace"))
            self.assertTrue(json.loads(completed.stdout)["verified"])
            self.assertTrue(verify_submission(cli_output / "submission.json")["valid"])
            with self.assertRaisesRegex(ReferenceStudyError, "new path"):
                run_reference_study(
                    output,
                    study_plan=study_path,
                    execution_plan=execution_path,
                    baseline_manifest=baseline_path,
                    baseline_binary=self.binary,
                    candidate_manifest=candidate_path,
                    candidate_binary=self.binary,
                    package_root=PACKAGE_ROOT,
                )

    def test_control_catalog_gates_unfair_or_unsafe_ablations(self) -> None:
        catalog = control_catalog()
        self.assertEqual(catalog["default"], DEFAULT_CONTROL_PROFILE)
        implemented = [item for item in catalog["profiles"] if item["status"] == "implemented"]
        self.assertEqual(
            [item["id"] for item in implemented],
            [
                DEFAULT_CONTROL_PROFILE,
                "single-agent-margin-v1",
                "role-separated-plain-markdown-v1",
            ],
        )
        self.assertEqual(implemented[0]["toolSurface"], ["margin"])
        self.assertFalse(implemented[0]["shellAccess"])
        self.assertTrue(all(not item["blockingGates"] for item in implemented))
        gated = [item for item in catalog["profiles"] if item["status"] != "implemented"]
        self.assertTrue(gated)
        for profile in gated:
            blockers = profile["blockingGates"]
            self.assertTrue(blockers, profile["id"])
            blocker_ids = [item["id"] for item in blockers]
            self.assertEqual(len(blocker_ids), len(set(blocker_ids)), profile["id"])
        shell = next(item for item in catalog["profiles"] if item["shellAccess"])
        self.assertEqual(shell["status"], "specified-not-runnable")
        self.assertIn("remote-sandbox", shell["isolationRequirement"])
        self.assertEqual(require_implemented_profile(DEFAULT_CONTROL_PROFILE), implemented[0])
        self.assertEqual(
            require_implemented_profile("single-agent-margin-v1")["status"],
            "implemented",
        )
        no_exchange = next(
            item for item in catalog["profiles"]
            if item["id"] == "role-separated-no-exchange-v1"
        )
        self.assertEqual(no_exchange["durableSurface"], "none")
        self.assertEqual(no_exchange["status"], "specified-not-runnable")
        episode = generate_episode("human_agent_relay", KEY, 0)
        self.assertEqual(episode.public_manifest()["controls"], [DEFAULT_CONTROL_PROFILE])
        mutated = control_catalog()
        mutated["profiles"][0]["blockingGates"].append(
            {"id": "caller-mutation", "requirement": "must not escape"}
        )
        self.assertEqual(control_catalog()["profiles"][0]["blockingGates"], [])
        try:
            from jsonschema import Draft202012Validator
        except ImportError:
            return
        schema = json.loads((SCHEMA_ROOT / "control-catalog.schema.json").read_text(encoding="utf-8"))
        Draft202012Validator(schema).validate(catalog)

    def test_phase_identity_is_trusted_ordered_atomic_and_single_advance(self) -> None:
        roles = [
            RoleTask(
                seat="author",
                actor=Actor("urn:test:phase-author", "Phase Author"),
                phase=0,
                prompt="Author phase",
                workflow="phase-test",
            ),
            RoleTask(
                seat="reviewer",
                actor=Actor("urn:test:phase-reviewer", "Phase Reviewer"),
                phase=1,
                prompt="Reviewer phase",
                workflow="phase-test",
            ),
        ]
        with tempfile.TemporaryDirectory(prefix="marginbench-phase-identity-") as temporary:
            root = Path(temporary)
            binding_path = root / "identity.json"
            controller = PhaseIdentityController(binding_path, roles)
            with self.assertRaisesRegex(ValueError, "out of order"):
                controller.advance(roles[1])
            self.assertFalse(binding_path.exists())
            author = controller.advance(roles[0])
            self.assertEqual(read_phase_identity(binding_path), author)
            self.assertEqual(os.stat(binding_path).st_mode & 0o777, 0o600)
            with self.assertRaisesRegex(ValueError, "out of order"):
                controller.advance(roles[0])
            reviewer = controller.advance(roles[1])
            self.assertEqual(read_phase_identity(binding_path), reviewer)
            self.assertEqual(reviewer.actor.id, "urn:test:phase-reviewer")
            with self.assertRaisesRegex(ValueError, "already complete"):
                controller.advance(roles[1])

            if hasattr(os, "O_NOFOLLOW"):
                linked = root / "linked-identity.json"
                linked.symlink_to(binding_path)
                with self.assertRaisesRegex(ValueError, "unavailable"):
                    read_phase_identity(linked)

            concurrent_path = root / "concurrent.json"
            concurrent = PhaseIdentityController(concurrent_path, [roles[0]])
            with ThreadPoolExecutor(max_workers=8) as pool:
                outcomes = list(pool.map(
                    lambda _: self._phase_identity_attempt(concurrent, roles[0]),
                    range(16),
                ))
            self.assertEqual(outcomes.count(True), 1)
            self.assertEqual(read_phase_identity(concurrent_path).actor, roles[0].actor)

    @staticmethod
    def _phase_identity_attempt(
        controller: PhaseIdentityController,
        role: RoleTask,
    ) -> bool:
        try:
            controller.advance(role)
        except ValueError:
            return False
        return True

    def test_holdout_key_creation_is_private_exclusive_and_never_echoes_secret(self) -> None:
        with tempfile.TemporaryDirectory(prefix="marginbench-key-test-") as temporary:
            path = Path(temporary) / "holdout.key"
            receipt = create_holdout_key(path)
            secret = path.read_text(encoding="ascii").strip()
            self.assertRegex(secret, "^[0-9a-f]{64}$")
            self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)
            self.assertFalse(receipt["secretPrinted"])
            self.assertNotIn(secret, json.dumps(receipt))
            loaded, key_id = load_holdout_key(path)
            self.assertEqual(loaded, secret)
            self.assertEqual(key_id, receipt["keyID"])
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
            path.chmod(0o644)
            with self.assertRaisesRegex(ValueError, "group- or world-accessible"):
                load_holdout_key(path)

    def test_paid_plan_costs_every_role_and_stays_conservative(self) -> None:
        one_role = estimate_maximum_cost(
            ["human_agent_relay"], 1, 12, 3, 65_536, 2_400, 0.03, 0.13, 0.0002
        )
        two_roles = estimate_maximum_cost(
            ["agent_agent_handoff"], 1, 12, 3, 65_536, 2_400, 0.03, 0.13, 0.0002
        )
        self.assertEqual(one_role, 0.089211)
        self.assertEqual(two_roles, 0.178422)
        selected = estimate_maximum_cost(
            ["human_agent_relay"],
            1,
            12,
            3,
            65_536,
            2_400,
            0.03,
            0.13,
            0.0002,
            [3, 7],
        )
        self.assertEqual(selected, one_role * 2)
        observed_stage_cost = 0.0044
        self.assertGreater(two_roles, observed_stage_cost)

        arguments = SimpleNamespace(
            scenario=["human_agent_relay"],
            repetitions=1,
            repetition_id=[3, 7],
            model="test/model",
            max_concurrent=1,
            margin_bin=self.binary,
            control_profile=DEFAULT_CONTROL_PROFILE,
            temperature=0.0,
            max_tokens_per_call=100,
            max_turns=2,
            max_input_tokens=1000,
            max_output_tokens=500,
            max_total_tokens=1200,
            rollout_timeout_seconds=30.0,
            wall_timeout_seconds=300.0,
            live_proxy_timeout_seconds=120.0,
            minimum_start_interval_seconds=300.0,
        )
        command = build_eval_command(arguments, Path("/prime/eval"), Path("/output"))
        self.assertEqual(command[command.index("--num-tasks") + 1], "2")
        repetition_flag = command.index("--env.taskset.repetition-ids")
        self.assertEqual(command[repetition_flag + 1:repetition_flag + 3], ["3", "7"])
        proxied = build_eval_command(
            arguments,
            Path("/prime/eval"),
            Path("/output"),
            client_base_url="http://127.0.0.1:1234/api/v1",
            client_api_key_var="MARGINBENCH_PROXY_TOKEN",
        )
        self.assertEqual(
            proxied[proxied.index("--client.base-url") + 1],
            "http://127.0.0.1:1234/api/v1",
        )
        self.assertEqual(
            proxied[proxied.index("--client.api-key-var") + 1],
            "MARGINBENCH_PROXY_TOKEN",
        )

    def test_prime_inference_credentials_require_a_private_config(self) -> None:
        with tempfile.TemporaryDirectory(prefix="marginbench-prime-config-") as temporary:
            root = Path(temporary)
            config = root / ".prime" / "config.json"
            config.parent.mkdir()
            config.write_text(json.dumps({
                "api_key": "private-test-token",
                "inference_url": "https://inference.example/api/v1",
                "team_id": "team-test",
            }), encoding="utf-8")
            config.chmod(0o600)
            with (
                patch("prime_pilot.Path.home", return_value=root),
                patch.dict(os.environ, {
                    "PRIME_API_KEY": "",
                    "PRIME_INFERENCE_URL": "",
                    "PRIME_TEAM_ID": "",
                }),
            ):
                self.assertEqual(load_prime_inference_credentials(), (
                    "https://inference.example/api/v1",
                    "private-test-token",
                    "team-test",
                ))
                config.chmod(0o644)
                with self.assertRaisesRegex(ValueError, "private regular file") as captured:
                    load_prime_inference_credentials()
                self.assertNotIn("private-test-token", str(captured.exception))

    def test_wallet_falls_back_to_documented_api_when_prime_agent_removed_command(self) -> None:
        secret = "private-wallet-test-token"

        class Response:
            def __enter__(self):
                return self

            def __exit__(self, *_: object) -> None:
                return None

            def read(self, limit: int) -> bytes:
                self_limit = 1024 * 1024 + 1
                self.assertEqual(limit, self_limit)
                return json.dumps({
                    "balance_usd": 197.25,
                    "total_billings": 42,
                }).encode("utf-8")

        response = Response()
        response.assertEqual = self.assertEqual
        with (
            patch("prime_pilot.subprocess.run", return_value=SimpleNamespace(
                returncode=1,
                stdout=b"",
                stderr=b"unsupported",
            )),
            patch(
                "prime_pilot.load_prime_inference_credentials",
                return_value=("https://inference.example", secret, "team one"),
            ),
            patch("prime_pilot.urlopen", return_value=response) as open_wallet,
        ):
            self.assertEqual(wallet(Path("/prime-agent")), {
                "balanceUSD": 197.25,
                "totalBillings": 42,
            })
        request = open_wallet.call_args.args[0]
        self.assertEqual(
            request.full_url,
            "https://api.primeintellect.ai/api/v1/billing/wallet?limit=5&teamId=team+one",
        )
        self.assertEqual(request.get_header("Authorization"), f"Bearer {secret}")

    def test_wallet_api_failure_never_exposes_credentials(self) -> None:
        secret = "private-wallet-test-token"
        with (
            patch("prime_pilot.subprocess.run", return_value=SimpleNamespace(
                returncode=1,
                stdout=b"",
                stderr=secret.encode("utf-8"),
            )),
            patch(
                "prime_pilot.load_prime_inference_credentials",
                return_value=("https://inference.example", secret, None),
            ),
            patch("prime_pilot.urlopen", side_effect=OSError(secret)),
        ):
            with self.assertRaisesRegex(RuntimeError, "wallet API is unavailable") as captured:
                wallet(Path("/prime-agent"))
        self.assertNotIn(secret, str(captured.exception))

    def test_inference_budget_proxy_enforces_auth_bytes_output_and_cumulative_cost(self) -> None:
        observed: list[dict[str, object]] = []

        class UpstreamHandler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, format: str, *args: object) -> None:
                return

            def do_POST(self) -> None:  # noqa: N802
                length = int(self.headers.get("content-length", "0"))
                raw = self.rfile.read(length)
                observed.append({
                    "path": self.path,
                    "authorization": self.headers.get("authorization"),
                    "team": self.headers.get("x-prime-team-id"),
                    "body": json.loads(raw),
                })
                response = json.dumps({
                    "id": "fake-completion",
                    "choices": [{"message": {"role": "assistant", "content": "done"}}],
                    "usage": {"prompt_tokens": 10, "completion_tokens": 5},
                }).encode("utf-8")
                self.send_response(200)
                self.send_header("content-type", "application/json")
                self.send_header("content-length", str(len(response)))
                self.end_headers()
                self.wfile.write(response)

        upstream = ThreadingHTTPServer(("127.0.0.1", 0), UpstreamHandler)
        upstream.daemon_threads = True
        upstream_thread = threading.Thread(target=upstream.serve_forever, daemon=True)
        upstream_thread.start()
        try:
            host, port = upstream.server_address[:2]
            policy = InferenceBudgetPolicy(
                allowed_model="test/model",
                max_request_bytes=512,
                template_token_allowance=32,
                input_token_ceiling=1000,
                max_output_tokens=100,
                input_price_per_million=1.0,
                output_price_per_million=1.0,
                billing_overhead_usd_per_call=0.0,
                max_total_cost_usd=0.00023,
            )
            with InferenceBudgetProxy(
                f"http://{host}:{port}/api/v1",
                "actual-upstream-secret",
                policy,
                team_id="team-test",
            ) as proxy:
                endpoint = proxy.base_url + "/chat/completions"
                headers = {"authorization": f"Bearer {proxy.client_token}"}
                payload = {
                    "model": "test/model",
                    "messages": [{"role": "user", "content": "hello"}],
                    "max_tokens": 20,
                }
                with httpx.Client(timeout=5) as client:
                    accepted = client.post(endpoint, headers=headers, json=payload)
                    self.assertEqual(accepted.status_code, 200)
                    unauthorized = client.post(
                        endpoint,
                        headers={"authorization": "Bearer wrong"},
                        json=payload,
                    )
                    self.assertEqual(unauthorized.status_code, 401)
                    self.assertEqual(unauthorized.json()["error"]["code"], "BUDGET_PROXY_UNAUTHORIZED")
                    streaming = client.post(endpoint, headers=headers, json={**payload, "stream": True})
                    self.assertEqual(streaming.status_code, 400)
                    self.assertEqual(streaming.json()["error"]["code"], "BUDGET_PROXY_STREAMING")
                    numeric_streaming = client.post(
                        endpoint,
                        headers=headers,
                        json={**payload, "stream": 1},
                    )
                    self.assertEqual(numeric_streaming.status_code, 400)
                    self.assertEqual(
                        numeric_streaming.json()["error"]["code"],
                        "BUDGET_PROXY_STREAMING",
                    )
                    wrong_model = client.post(
                        endpoint,
                        headers=headers,
                        json={**payload, "model": "different/model"},
                    )
                    self.assertEqual(wrong_model.status_code, 400)
                    self.assertEqual(wrong_model.json()["error"]["code"], "BUDGET_PROXY_MODEL")
                    excessive_output = client.post(
                        endpoint,
                        headers=headers,
                        json={**payload, "max_tokens": 101},
                    )
                    self.assertEqual(excessive_output.status_code, 400)
                    self.assertEqual(
                        excessive_output.json()["error"]["code"],
                        "BUDGET_PROXY_OUTPUT_LIMIT",
                    )
                    boolean_output = client.post(
                        endpoint,
                        headers=headers,
                        json={**payload, "max_tokens": True},
                    )
                    self.assertEqual(boolean_output.status_code, 400)
                    self.assertEqual(
                        boolean_output.json()["error"]["code"],
                        "BUDGET_PROXY_OUTPUT_LIMIT",
                    )
                    conflicting_output = client.post(
                        endpoint,
                        headers=headers,
                        json={**payload, "max_completion_tokens": 20, "max_tokens": 101},
                    )
                    self.assertEqual(conflicting_output.status_code, 400)
                    self.assertEqual(
                        conflicting_output.json()["error"]["code"],
                        "BUDGET_PROXY_OUTPUT_LIMIT",
                    )
                    duplicate_model = client.post(
                        endpoint,
                        headers={**headers, "content-type": "application/json"},
                        content=(
                            b'{"model":"test/model","model":"test/model",'
                            b'"messages":[],"max_tokens":20}'
                        ),
                    )
                    self.assertEqual(duplicate_model.status_code, 400)
                    self.assertEqual(duplicate_model.json()["error"]["code"], "BUDGET_PROXY_JSON")
                    nonfinite = client.post(
                        endpoint,
                        headers={**headers, "content-type": "application/json"},
                        content=(
                            b'{"model":"test/model","messages":[],"max_tokens":20,'
                            b'"temperature":NaN}'
                        ),
                    )
                    self.assertEqual(nonfinite.status_code, 400)
                    self.assertEqual(nonfinite.json()["error"]["code"], "BUDGET_PROXY_JSON")
                    wrong_route = client.post(
                        proxy.base_url + "/models",
                        headers=headers,
                        json=payload,
                    )
                    self.assertEqual(wrong_route.status_code, 404)
                    self.assertEqual(wrong_route.json()["error"]["code"], "BUDGET_PROXY_ROUTE")
                    oversized = client.post(endpoint, headers=headers, content=b"x" * 513)
                    self.assertEqual(oversized.status_code, 413)
                    self.assertEqual(oversized.json()["error"]["code"], "BUDGET_PROXY_REQUEST_LIMIT")
                    parsed_endpoint = httpx.URL(endpoint)
                    framed = http.client.HTTPConnection(
                        parsed_endpoint.host,
                        parsed_endpoint.port,
                        timeout=5,
                    )
                    framed.putrequest("POST", parsed_endpoint.raw_path.decode("ascii"))
                    framed.putheader("authorization", f"Bearer {proxy.client_token}")
                    framed.putheader("content-length", "2")
                    framed.putheader("content-length", "2")
                    framed.endheaders(b"{}")
                    framed_response = framed.getresponse()
                    self.assertEqual(framed_response.status, 400)
                    self.assertEqual(
                        json.loads(framed_response.read())["error"]["code"],
                        "BUDGET_PROXY_FRAMING",
                    )
                    framed.close()
                    exhausted = client.post(endpoint, headers=headers, json=payload)
                    self.assertEqual(exhausted.status_code, 429)
                    self.assertEqual(exhausted.json()["error"]["code"], "BUDGET_PROXY_COST_LIMIT")
                report = proxy.gate.report()
        finally:
            upstream.shutdown()
            upstream.server_close()
            upstream_thread.join(timeout=5)

        self.assertEqual(len(observed), 1)
        self.assertEqual(observed[0]["path"], "/api/v1/chat/completions")
        self.assertEqual(observed[0]["authorization"], "Bearer actual-upstream-secret")
        self.assertEqual(observed[0]["team"], "team-test")
        self.assertEqual(report["forwardedRequestCount"], 1)
        self.assertEqual(report["rejectedRequestCount"], 13)
        self.assertEqual(report["policy"]["allowedModel"], "test/model")
        self.assertEqual(report["reportedPromptTokens"], 10)
        self.assertEqual(report["reportedCompletionTokens"], 5)
        self.assertEqual(report["settledRequestCount"], 1)
        self.assertEqual(report["outstandingReservationCount"], 0)
        self.assertEqual(report["providerBoundViolationCount"], 0)
        self.assertFalse(report["latchedClosed"])
        self.assertLessEqual(report["reservedCostUpperBoundUSD"], 0.00023)

    def test_inference_request_pacer_spaces_provider_starts_without_wall_clock_delay(self) -> None:
        now = [100.0]
        sleeps: list[float] = []

        def sleep(seconds: float) -> None:
            sleeps.append(seconds)
            now[0] += seconds

        pacer = InferenceRequestPacer(
            6.0,
            clock=lambda: now[0],
            sleeper=sleep,
        )
        pacer.wait()
        now[0] += 2.0
        pacer.wait()
        now[0] += 9.0
        pacer.wait()

        self.assertEqual(sleeps, [4.0])
        self.assertEqual(now[0], 115.0)
        for invalid in (-1, 61, float("nan"), True):
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                InferenceRequestPacer(invalid)

    def test_inference_budget_policy_and_upstream_url_reject_ambiguous_types(self) -> None:
        values = {
            "allowed_model": "test/model",
            "max_request_bytes": 512,
            "template_token_allowance": 32,
            "input_token_ceiling": 1000,
            "max_output_tokens": 100,
            "input_price_per_million": 1.0,
            "output_price_per_million": 1.0,
            "billing_overhead_usd_per_call": 0.0,
            "max_total_cost_usd": 0.01,
        }
        for field, invalid in (
            ("max_request_bytes", True),
            ("template_token_allowance", False),
            ("input_price_per_million", True),
            ("max_total_cost_usd", float("nan")),
        ):
            with self.subTest(field=field), self.assertRaises(ValueError):
                InferenceBudgetPolicy(**{**values, field: invalid})
        policy = InferenceBudgetPolicy(**values)
        with self.assertRaisesRegex(ValueError, "must be HTTPS"):
            InferenceBudgetProxy(
                "https://embedded:credential@inference.example/api/v1",
                "upstream-secret",
                policy,
            )

    def test_inference_budget_gate_serializes_simultaneous_reservations(self) -> None:
        gate = InferenceBudgetGate(InferenceBudgetPolicy(
            allowed_model="test/model",
            max_request_bytes=64,
            template_token_allowance=0,
            input_token_ceiling=1000,
            max_output_tokens=10,
            input_price_per_million=1.0,
            output_price_per_million=0.0,
            billing_overhead_usd_per_call=0.0,
            max_total_cost_usd=0.0001,
        ))
        with ThreadPoolExecutor(max_workers=32) as pool:
            reservations = list(pool.map(lambda _: gate.reserve(10, 1), range(32)))
        self.assertEqual(sum(value is not None for value in reservations), 5)
        report = gate.report()
        self.assertEqual(report["forwardedRequestCount"], 5)
        self.assertEqual(report["rejectedRequestCount"], 27)
        self.assertEqual(report["reservedCostUpperBoundUSD"], 0.0001)

    def test_inference_budget_report_and_validator_agree_at_half_microdollar(self) -> None:
        policy = InferenceBudgetPolicy(
            allowed_model="test/model",
            max_request_bytes=1_048_576,
            template_token_allowance=8192,
            input_token_ceiling=400_000,
            max_output_tokens=1800,
            input_price_per_million=0.75,
            output_price_per_million=4.5,
            billing_overhead_usd_per_call=0.0002,
            max_total_cost_usd=1.5,
            response_token_allowance=8,
        )
        gate = InferenceBudgetGate(policy)
        for _ in range(2):
            reservation = gate.reserve(1_048_576, 1800)
            self.assertIsNotNone(reservation)
            gate.record_response(
                {
                    "usage": {
                        "prompt_tokens": 71_929,
                        "completion_tokens": 1_047,
                    }
                },
                reservation,
            )
        report = gate.report()
        self.assertEqual(report["reportedTokenCostUSD"], 0.117316)
        errors: list[str] = []
        from marginbench.validation import _live_budget_semantics

        _live_budget_semantics(report, "test budget", errors)
        self.assertEqual(errors, [])

    def test_inference_budget_gate_reuses_settled_sequential_headroom(self) -> None:
        policy = InferenceBudgetPolicy(
            allowed_model="test/model",
            max_request_bytes=64,
            template_token_allowance=0,
            input_token_ceiling=1000,
            max_output_tokens=100,
            input_price_per_million=1.0,
            output_price_per_million=1.0,
            billing_overhead_usd_per_call=0.0,
            max_total_cost_usd=0.0003,
        )
        gate = InferenceBudgetGate(policy)
        for _ in range(10):
            reservation = gate.reserve(50, 100)
            self.assertIsNotNone(reservation)
            gate.record_response(
                {"usage": {"prompt_tokens": 5, "completion_tokens": 5}},
                reservation,
            )
        report = gate.report()
        self.assertEqual(report["forwardedRequestCount"], 10)
        self.assertEqual(report["settledRequestCount"], 10)
        self.assertEqual(report["outstandingReservationCount"], 0)
        self.assertEqual(report["reservedCostUpperBoundUSD"], 0.0001)
        self.assertEqual(report["grossReservedCostUpperBoundUSD"], 0.002)
        self.assertEqual(report["rejectedRequestCount"], 0)

    def test_inference_budget_gate_retains_unsettled_response_reservation(self) -> None:
        gate = InferenceBudgetGate(InferenceBudgetPolicy(
            allowed_model="test/model",
            max_request_bytes=64,
            template_token_allowance=0,
            input_token_ceiling=1000,
            max_output_tokens=100,
            input_price_per_million=1.0,
            output_price_per_million=1.0,
            billing_overhead_usd_per_call=0.0,
            max_total_cost_usd=0.00025,
        ))
        reservation = gate.reserve(50, 100)
        self.assertIsNotNone(reservation)
        gate.record_response({"error": {"code": "upstream"}}, reservation)
        self.assertIsNone(gate.reserve(50, 100))
        report = gate.report()
        self.assertEqual(report["settledRequestCount"], 0)
        self.assertEqual(report["outstandingReservationCount"], 1)
        self.assertEqual(report["reservedCostUpperBoundUSD"], 0.0002)

    def test_inference_budget_gate_settles_reservation_only_once(self) -> None:
        gate = InferenceBudgetGate(InferenceBudgetPolicy(
            allowed_model="test/model",
            max_request_bytes=64,
            template_token_allowance=0,
            input_token_ceiling=1000,
            max_output_tokens=100,
            input_price_per_million=1.0,
            output_price_per_million=1.0,
            billing_overhead_usd_per_call=0.0,
            max_total_cost_usd=0.001,
        ))
        reservation = gate.reserve(50, 100)
        self.assertIsNotNone(reservation)
        payload = {"usage": {"prompt_tokens": 5, "completion_tokens": 5}}
        gate.record_response(payload, reservation)
        gate.record_response(payload, reservation)
        report = gate.report()
        self.assertEqual(report["settledRequestCount"], 1)
        self.assertEqual(report["providerBoundViolationCount"], 1)
        self.assertTrue(report["latchedClosed"])

    def test_inference_budget_gate_latches_closed_after_provider_bound_violation(self) -> None:
        gate = InferenceBudgetGate(InferenceBudgetPolicy(
            allowed_model="test/model",
            max_request_bytes=64,
            template_token_allowance=0,
            input_token_ceiling=1000,
            max_output_tokens=10,
            input_price_per_million=1.0,
            output_price_per_million=1.0,
            billing_overhead_usd_per_call=0.0,
            max_total_cost_usd=0.001,
        ))
        reservation = gate.reserve(10, 5)
        self.assertIsNotNone(reservation)
        gate.record_response(
            {"usage": {"prompt_tokens": 21, "completion_tokens": 5}},
            reservation,
        )
        self.assertIsNone(gate.reserve(1, 1))
        report = gate.report()
        self.assertEqual(report["providerBoundViolationCount"], 1)
        self.assertTrue(report["latchedClosed"])
        self.assertEqual(report["forwardedRequestCount"], 1)
        self.assertEqual(report["rejectedRequestCount"], 1)

    def test_inference_budget_gate_prices_bounded_provider_wrapper_tokens(self) -> None:
        gate = InferenceBudgetGate(InferenceBudgetPolicy(
            allowed_model="test/model",
            max_request_bytes=64,
            template_token_allowance=0,
            input_token_ceiling=1000,
            max_output_tokens=10,
            input_price_per_million=1.0,
            output_price_per_million=1.0,
            billing_overhead_usd_per_call=0.0,
            max_total_cost_usd=0.001,
            response_token_allowance=2,
        ))
        reservation = gate.reserve(10, 5)
        self.assertIsNotNone(reservation)
        self.assertEqual(reservation.output_tokens_upper, 7)
        gate.record_response(
            {"usage": {"prompt_tokens": 20, "completion_tokens": 7}},
            reservation,
        )
        report = gate.report()
        self.assertEqual(report["policy"]["maxOutputTokens"], 10)
        self.assertEqual(report["policy"]["responseTokenAllowance"], 2)
        self.assertEqual(report["providerBoundViolationCount"], 0)
        self.assertFalse(report["latchedClosed"])

    def test_default_provider_allowance_covers_priced_hidden_reasoning_tokens(self) -> None:
        gate = InferenceBudgetGate(InferenceBudgetPolicy(
            allowed_model="test/reasoning-model",
            max_request_bytes=64,
            template_token_allowance=0,
            input_token_ceiling=1000,
            max_output_tokens=1800,
            input_price_per_million=1.0,
            output_price_per_million=1.0,
            billing_overhead_usd_per_call=0.0,
            max_total_cost_usd=0.01,
            response_token_allowance=DEFAULT_PROVIDER_RESPONSE_TOKEN_ALLOWANCE,
        ))
        reservation = gate.reserve(10, 1800)
        self.assertIsNotNone(reservation)
        self.assertEqual(reservation.output_tokens_upper, 5896)
        gate.record_response(
            {"usage": {"prompt_tokens": 20, "completion_tokens": 2863}},
            reservation,
        )
        report = gate.report()
        self.assertEqual(report["providerBoundViolationCount"], 0)
        self.assertFalse(report["latchedClosed"])

    def test_paid_start_gate_serializes_and_enforces_cooldown(self) -> None:
        with tempfile.TemporaryDirectory(prefix="marginbench-paid-gate-") as temporary:
            marker = Path(temporary) / "last-start"
            claim_paid_start(marker, now=1_000.0, minimum_interval_seconds=300.0)
            with self.assertRaisesRegex(RuntimeError, "200 seconds remaining"):
                claim_paid_start(marker, now=1_100.0, minimum_interval_seconds=300.0)
            claim_paid_start(marker, now=1_300.0, minimum_interval_seconds=300.0)

    def test_paid_worker_outputs_are_atomic_private_and_never_replaced(self) -> None:
        with tempfile.TemporaryDirectory(prefix="marginbench-output-test-") as temporary:
            root = Path(temporary)
            output = root / "raw"
            summary = root / "summary.json"
            run = root / "run.json"
            _require_fresh_output_targets(output, summary, run)
            with self.assertRaisesRegex(ValueError, "distinct paths"):
                _require_fresh_output_targets(output, summary, summary)

            _create_private_output_directory(output)
            self.assertEqual(output.stat().st_mode & 0o777, 0o700)

            _write_new_artifact(summary, b'{"first":true}\n')
            self.assertEqual(summary.read_bytes(), b'{"first":true}\n')
            self.assertEqual(summary.stat().st_mode & 0o777, 0o600)
            with self.assertRaisesRegex(ValueError, "Refusing to replace"):
                _write_new_artifact(summary, b'{"second":true}\n')
            self.assertEqual(summary.read_bytes(), b'{"first":true}\n')
            with self.assertRaisesRegex(ValueError, "Refusing to replace"):
                _require_fresh_output_targets(output, summary, run)

            dangling = root / "dangling.json"
            dangling.symlink_to(root / "missing.json")
            with self.assertRaisesRegex(ValueError, "Refusing to replace"):
                _require_fresh_output_targets(output, dangling, run)

    def test_infrastructure_codes_and_role_errors_cannot_publish_completed_runs(self) -> None:
        complete = {
            "traceCount": 1,
            "traceConsistencyPassed": True,
            "episodes": [{"roleRuns": [{"stopCondition": "agent_completed"}]}],
        }
        self.assertEqual(_execution_status(0, complete, []), "completed")
        self.assertEqual(
            _execution_status(0, complete, ["PROVIDER_USAGE_BOUND_VIOLATION"]),
            "infrastructure_error",
        )
        failed_role = json.loads(json.dumps(complete))
        failed_role["episodes"][0]["roleRuns"][0]["stopCondition"] = "error"
        self.assertEqual(_execution_status(0, failed_role, []), "infrastructure_error")

    def test_provider_throttling_is_not_masked_by_the_later_budget_stop(self) -> None:
        codes = _infrastructure_codes(
            (
                "ProviderError: upstream 429 rate_limit_exceeded\n"
                "ProviderError: BUDGET_PROXY_COST_LIMIT\n"
            ),
            {"providerBoundViolationCount": 0},
            timed_out=False,
        )
        self.assertEqual(
            codes,
            ["PROVIDER_RATE_LIMIT", "LIVE_BUDGET_EXHAUSTED"],
        )

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
            directory_block = gateway.call(["ls", "."])
            self.assertEqual(directory_block.error_code, "MARGINBENCH_COMMAND_BLOCKED")
            self.assertIn("man agents", directory_block.stderr)
            self.assertNotIn("context . --json", directory_block.stderr)
            self.assertNotIn("inbox . --status", directory_block.stderr)
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
            handoff_identity = gateway.call([
                "handoff", "add", "note.md", "-m", "Transfer", "--actor-id", "urn:recipient",
            ])
            self.assertEqual(handoff_identity.error_code, "MARGINBENCH_IDENTITY_BOUND")
            self.assertIn("--next-actor ACTOR_ID", handoff_identity.stderr)
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
            atomic_reply = gateway.call([
                "comments", "reply", "note.md",
                "urn:uuid:4ff7ed11-5899-4ed2-a282-4e0362f43cba",
                "-m", "Verified without retaining this prose in telemetry.",
                "--resolve", "--mutation-id", "5b9f6319-38b7-49b7-a916-6f707984ce85",
            ])
            self.assertTrue(atomic_reply.ok)
            self.assertNotIn(secret_body, log.read_text(encoding="utf-8"))
            recorded = read_command_events(log)
            self.assertEqual(recorded[-1].command, "comments reply --resolve")
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
                    root = Path(temporary)
                    workspace = root / "workspace"
                    result = run_episode(
                        episode,
                        self.binary,
                        workspace,
                        ReferenceDriver(),
                    )
                    self.assertEqual(result.score, 100.0)
                    self.assertTrue(result.safety_passed)
                    self.assertTrue(all(result.checks.values()))

                    missing_protocol = score_episode(
                        episode,
                        workspace,
                        self.binary,
                        root / "missing-events.jsonl",
                    )
                    self.assertFalse(missing_protocol.checks["required_commands"])
                    self.assertLess(missing_protocol.score, 100.0)
                    self.assertTrue(missing_protocol.safety_passed)

                    (workspace / "unexpected-agent-residue.txt").write_text(
                        "unrequested\n",
                        encoding="utf-8",
                    )
                    unexpected_path = score_episode(
                        episode,
                        workspace,
                        self.binary,
                        root / ".marginbench-control" / "events.jsonl",
                    )
                    self.assertFalse(unexpected_path.checks["workspace_expected_paths"])
                    self.assertFalse(unexpected_path.safety_passed)
                    self.assertLessEqual(unexpected_path.score, 25.0)

    def test_concurrent_review_does_not_penalize_one_normal_write_collision(self) -> None:
        episode = generate_episode("concurrent_review", KEY, 0)
        self.assertEqual(episode.oracle["efficientCommandTarget"], 6)
        with tempfile.TemporaryDirectory(prefix="marginbench-concurrent-recovery-") as temporary:
            root = Path(temporary)
            workspace = root / "workspace"
            complete = run_episode(
                episode,
                self.binary,
                workspace,
                ReferenceDriver(),
                control_profile="single-agent-margin-v1",
            )
            self.assertEqual(complete.command_count, 4)
            log = root / ".marginbench-control" / "events.jsonl"
            collision = CommandEvent(
                role="reviewer",
                command="comments add",
                exit_code=75,
                duration_ms=1.0,
                stdin_bytes=0,
                stdout_bytes=0,
                stderr_bytes=1,
                error_code="COLLABORATION_PRECONDITION_FAILED",
                blocked=False,
            )
            recovery_read = CommandEvent(
                role="reviewer",
                command="comments list",
                exit_code=0,
                duration_ms=1.0,
                stdin_bytes=0,
                stdout_bytes=1,
                stderr_bytes=0,
                error_code=None,
                blocked=False,
            )
            with log.open("ab") as stream:
                stream.write(canonical_json(asdict(collision)) + b"\n")
                stream.write(canonical_json(asdict(recovery_read)) + b"\n")
            recovered = score_episode(episode, workspace, self.binary, log)
        self.assertEqual(recovered.command_count, 6)
        self.assertEqual(recovered.dimensions["efficiency"], 100.0)
        self.assertEqual(recovered.score, 100.0)
        self.assertTrue(recovered.checks["valid_command_use"])

    def test_wide_directory_triage_is_opt_in_exact_and_reference_solvable(self) -> None:
        self.assertNotIn("wide_directory_triage", SCENARIO_IDS)
        self.assertIn("wide_directory_triage", EXPERIMENTAL_SCENARIO_IDS)
        self.assertIn("wide_directory_triage", AVAILABLE_SCENARIO_IDS)
        episode = generate_episode("wide_directory_triage", KEY, 0)
        repeated = generate_episode("wide_directory_triage", KEY, 0)
        self.assertEqual(episode.fingerprint, repeated.fingerprint)
        self.assertEqual(episode.files, repeated.files)
        self.assertEqual(len(episode.files), 16)
        self.assertEqual(len(episode.events), 64)
        self.assertEqual(len(episode.oracle["annotations"]), 65)
        self.assertTrue(episode.oracle["contextThenInboxIsExpected"])
        plan = build_study_plan(
            baseline="wide-baseline",
            candidate="wide-candidate",
            scenarios=["wide_directory_triage"],
            repetitions=1,
            key=KEY,
            development_cases=True,
        )
        self.assertEqual(plan["scenarioIDs"], ["wide_directory_triage"])

        with tempfile.TemporaryDirectory(prefix="marginbench-wide-triage-") as temporary:
            result = run_episode(
                episode,
                self.binary,
                Path(temporary) / "workspace",
                ReferenceDriver(),
            )
        self.assertEqual(result.score, 100.0)
        self.assertTrue(result.safety_passed)
        self.assertTrue(all(result.checks.values()))
        self.assertEqual(
            [event.command for event in result.events],
            [
                "context",
                "inbox",
                "comments reply --resolve",
                "comments list",
                "comments validate",
            ],
        )
        self.assertLess(result.events[0].stdout_bytes, 12 * 1_024)
        self.assertLess(result.events[1].stdout_bytes, 4 * 1_024)

        with tempfile.TemporaryDirectory(prefix="marginbench-wide-order-") as temporary:
            wrong_order = run_episode(
                episode,
                self.binary,
                Path(temporary) / "workspace",
                WideTriageWrongDiscoveryOrderDriver(),
            )
        self.assertTrue(wrong_order.checks["all_expected_annotations"])
        self.assertFalse(wrong_order.checks["avoided_redundant_initial_reads"])

    def test_suggestion_contention_is_opt_in_exact_and_reference_solvable(self) -> None:
        self.assertNotIn("suggestion_contention", SCENARIO_IDS)
        self.assertIn("suggestion_contention", EXPERIMENTAL_SCENARIO_IDS)
        self.assertIn("suggestion_contention", AVAILABLE_SCENARIO_IDS)
        episode = generate_episode("suggestion_contention", KEY, 0)
        repeated = generate_episode("suggestion_contention", KEY, 0)
        self.assertEqual(episode.fingerprint, repeated.fingerprint)
        self.assertEqual(episode.files, repeated.files)
        self.assertEqual(episode.oracle, repeated.oracle)
        self.assertEqual(len(episode.roles), 2)
        self.assertEqual({role.phase for role in episode.roles}, {0})
        self.assertEqual(len(episode.oracle["annotations"]), 8)
        self.assertEqual(
            {item["creatorID"] for item in episode.oracle["annotations"]},
            {role.actor.id for role in episode.roles},
        )
        plan = build_study_plan(
            baseline="contention-baseline",
            candidate="contention-candidate",
            scenarios=["suggestion_contention"],
            repetitions=1,
            key=KEY,
            development_cases=True,
        )
        self.assertEqual(plan["scenarioIDs"], ["suggestion_contention"])
        self.assertEqual(plan["totalAgentProcesses"], 4)

        for role in episode.roles:
            messages = [{"role": "user", "content": role.prompt}]
            for index in range(4):
                invocation = scripted_response(messages)
                self.assertEqual(invocation["arguments"][:2], ["suggest", "add"])
                self.assertEqual(invocation["arguments"][-2:], ["--id", episode.oracle["reference"]["assignments"][role.actor.id][index]["id"]])
                messages.append({
                    "role": "tool",
                    "content": json.dumps({"exitCode": 0, "stdout": "{}"}),
                })
            self.assertEqual(
                scripted_response(messages)["arguments"],
                ["suggest", "list", "review.md", "--json"],
            )
            messages.append({
                "role": "tool",
                "content": json.dumps({"exitCode": 0, "stdout": "{}"}),
            })
            self.assertEqual(
                scripted_response(messages)["arguments"],
                ["read", "review.md", "--json"],
            )

        with tempfile.TemporaryDirectory(prefix="marginbench-suggestion-contention-") as temporary:
            result = run_episode(
                episode,
                self.binary,
                Path(temporary) / "workspace",
                ReferenceDriver(),
            )
        self.assertEqual(result.score, 100.0)
        self.assertTrue(result.safety_passed)
        self.assertTrue(result.source_preserved)
        self.assertTrue(all(result.checks.values()))
        self.assertEqual(result.command_count, 12)
        self.assertEqual(result.invalid_command_count, 0)

    def test_redundant_initial_directory_reads_are_diagnosed_without_changing_outcomes(self) -> None:
        episode = generate_episode("directory_handoff", KEY, 41)
        with tempfile.TemporaryDirectory(prefix="marginbench-redundant-discovery-") as temporary:
            root = Path(temporary)
            result = run_episode(
                episode,
                self.binary,
                root / "workspace",
                ReferencePlusRedundantDiscoveryDriver(),
            )
            self.assertTrue(result.checks["all_expected_annotations"])
            self.assertTrue(result.checks["source_expected"])
            self.assertFalse(result.checks["avoided_redundant_initial_reads"])
            artifact = root / "result.json"
            artifact.write_bytes(canonical_json(result.to_dict()))
            report = diagnose_artifacts([artifact])
        self.assertEqual(report["topOpportunity"], "redundant-discovery")
        self.assertEqual(
            report["findings"][0]["evidence"]["failedChecks"],
            [{"name": "avoided_redundant_initial_reads", "count": 1}],
        )

    def test_annotation_ids_match_only_exact_values_or_canonical_uuid_urns(self) -> None:
        identifier = "00000000-0000-4000-8000-000000000123"
        self.assertTrue(_id_matches(identifier, identifier))
        self.assertTrue(_id_matches(f"urn:uuid:{identifier}", identifier))
        self.assertFalse(_id_matches(f"urn:marginbench:lookalike:{identifier}", identifier))
        self.assertFalse(_id_matches(f"prefix-{identifier}", identifier))

    def test_failed_required_command_does_not_receive_protocol_credit(self) -> None:
        episode = generate_episode("human_agent_relay", KEY, 0)
        with tempfile.TemporaryDirectory(prefix="marginbench-command-credit-test-") as temporary:
            root = Path(temporary)
            workspace = root / "workspace"
            complete = run_episode(episode, self.binary, workspace, ReferenceDriver())
            self.assertTrue(complete.checks["required_commands"])
            failed_log = root / "failed-events.jsonl"
            failed = CommandEvent(
                role="reviewer",
                command="comments reply",
                exit_code=64,
                duration_ms=1.0,
                stdin_bytes=0,
                stdout_bytes=0,
                stderr_bytes=1,
                error_code="USAGE",
                blocked=False,
            )
            failed_log.write_bytes(canonical_json(asdict(failed)) + b"\n")
            rescored = score_episode(episode, workspace, self.binary, failed_log)
            self.assertFalse(rescored.checks["required_commands"])
            self.assertFalse(rescored.checks["valid_command_use"])

    def test_unexpected_empty_directory_is_workspace_residue(self) -> None:
        episode = generate_episode("human_agent_relay", KEY, 0)
        with tempfile.TemporaryDirectory(prefix="marginbench-empty-dir-test-") as temporary:
            root = Path(temporary)
            workspace = root / "workspace"
            complete = run_episode(episode, self.binary, workspace, ReferenceDriver())
            self.assertTrue(complete.checks["workspace_expected_paths"])
            (workspace / "unrequested-empty-directory").mkdir()
            rescored = score_episode(
                episode,
                workspace,
                self.binary,
                root / ".marginbench-control" / "events.jsonl",
            )
            self.assertFalse(rescored.checks["workspace_expected_paths"])
            self.assertFalse(rescored.safety_passed)
            self.assertLessEqual(rescored.score, 25.0)

    def test_directory_handoff_scores_verified_state_not_one_validation_spelling(self) -> None:
        episode = generate_episode("directory_handoff", KEY, 0)
        required = episode.oracle["requiredCommandGroups"]
        self.assertNotIn(["comments validate"], required)
        self.assertIn(["context"], required)
        self.assertIn(["inbox", "handoff list"], required)
        self.assertEqual(set(episode.oracle["logicalSourceSha256"]), set(episode.files))

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
        self.assertFalse(result.checks["annotation_identity"])
        self.assertFalse(result.checks["annotation_body"])
        self.assertFalse(result.checks["annotation_kind"])
        self.assertFalse(result.checks["annotation_status"])
        self.assertFalse(result.checks["annotation_thread"])
        self.assertFalse(result.checks["annotation_properties"])
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

    def test_wrong_body_does_not_erase_independent_creator_attribution(self) -> None:
        episode = generate_episode("agent_agent_handoff", KEY, 0)
        with tempfile.TemporaryDirectory(prefix="marginbench-attribution-test-") as temporary:
            root = Path(temporary)
            workspace = root / "workspace"
            complete = run_episode(episode, self.binary, workspace, ReferenceDriver())
            self.assertTrue(complete.checks["all_expected_annotations"])
            expected = episode.oracle["annotations"][0]
            editor = MarginGateway(
                self.binary,
                workspace,
                Actor("urn:marginbench:test-editor", "Test Editor", "software"),
                "author",
                event_log=root / ".marginbench-control" / "events.jsonl",
            )
            edited = editor.call([
                "comments", "edit", expected["path"], expected["id"],
                "-m", "The durable body is now intentionally wrong.",
            ])
            self.assertTrue(edited.ok)
            rescored = score_episode(
                episode,
                workspace,
                self.binary,
                root / ".marginbench-control" / "events.jsonl",
            )
            self.assertFalse(rescored.checks["all_expected_annotations"])
            self.assertTrue(rescored.checks["annotation_identity"])
            self.assertFalse(rescored.checks["annotation_body"])
            self.assertTrue(rescored.checks["annotation_kind"])
            self.assertTrue(rescored.checks["annotation_status"])
            self.assertTrue(rescored.checks["annotation_thread"])
            self.assertTrue(rescored.checks["annotation_properties"])
            self.assertTrue(rescored.checks["attribution"])

    def test_synthesis_prompts_do_not_present_placeholders_as_exact_text(self) -> None:
        specialist = generate_episode("specialist_audit", KEY, 0)
        distributed = generate_episode("distributed_synthesis", KEY, 0)
        specialist_text = "\n".join(role.prompt for role in specialist.roles)
        distributed_text = "\n".join(role.prompt for role in distributed.roles)
        for marker in ("ORIGINAL", "SECURE", "NAME."):
            self.assertNotIn(marker, specialist_text)
        self.assertNotIn("A-TOKEN", distributed_text)
        self.assertIn("Do not write a generic", specialist_text)
        self.assertIn("Do not write a generic", distributed_text)

    def test_specialist_diagnostics_localize_unresolved_template_markers(self) -> None:
        episode = generate_episode("specialist_audit", KEY, 0)
        with tempfile.TemporaryDirectory(prefix="marginbench-specialist-diagnostic-") as temporary:
            root = Path(temporary)
            workspace = root / "workspace"
            complete = run_episode(episode, self.binary, workspace, ReferenceDriver())
            self.assertTrue(complete.checks["diagnostic_recorded_choice_recovered"])
            self.assertTrue(complete.checks["diagnostic_secure_choice_recovered"])
            issue = episode.oracle["annotations"][1]
            editor = MarginGateway(
                self.binary,
                workspace,
                Actor("urn:marginbench:test-editor", "Test Editor", "software"),
                "reviewer",
                event_log=root / ".marginbench-control" / "events.jsonl",
            )
            edited = editor.call([
                "comments", "edit", issue["path"], issue["id"], "-m",
                "Security correction: ORIGINAL is ineligible; choose SECURE.",
            ])
            self.assertTrue(edited.ok)
            rescored = score_episode(
                episode,
                workspace,
                self.binary,
                root / ".marginbench-control" / "events.jsonl",
            )
            self.assertTrue(rescored.checks["diagnostic_decision_fact_recovered"])
            self.assertFalse(rescored.checks["diagnostic_recorded_choice_recovered"])
            self.assertFalse(rescored.checks["diagnostic_secure_choice_recovered"])
            self.assertTrue(rescored.checks["diagnostic_sentence_shape_valid"])
            self.assertFalse(rescored.checks["diagnostic_template_markers_absent"])

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

    def test_paired_comparison_requires_identical_cases_and_candidate_integrity(self) -> None:
        def result(
            identifier: str,
            score: float,
            candidate_id: str,
            safe: bool = True,
            source_preserved: bool | None = None,
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
                source_preserved=safe if source_preserved is None else source_preserved,
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
        source_corrupt = [
            result("a", 25, "candidate", source_preserved=False),
            result("b", 70, "candidate"),
        ]
        source_comparison = paired_compare(baseline, source_corrupt, bootstrap_samples=100)
        self.assertEqual(source_comparison["safetyRegressions"], ["a"])
        self.assertFalse(source_comparison["promotable"])
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
        if JSONSCHEMA_AVAILABLE:
            with tempfile.TemporaryDirectory(prefix="marginbench-candidate-load-") as temporary:
                path = Path(temporary) / "candidate.json"
                path.write_text(json.dumps(asdict(first)), encoding="utf-8")
                self.assertEqual(
                    load_candidate_manifest(
                        path,
                        binary=self.binary,
                        candidate_id="read-receipts-v1",
                    ),
                    first,
                )
                with self.assertRaisesRegex(ValueError, "does not match --candidate"):
                    load_candidate_manifest(path, binary=self.binary, candidate_id="other")
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
    def test_diagnostics_rank_actionable_failures_without_private_content(self) -> None:
        source = PACKAGE_ROOT / "results" / "PRIME_GATE2_CONCURRENT_V7.json"
        report = diagnose_artifacts([source])
        self.assertEqual(report["episodeCount"], 1)
        self.assertEqual(report["topOpportunity"], "command-discoverability")
        self.assertEqual(report["invalidCommandCount"], 1)
        self.assertEqual(report["findings"][0]["severity"], "high")
        self.assertEqual(report["recommendedNextExperiment"]["gate"], "matched-private-pairs")
        self.assertFalse(report["privacy"]["documentContentRetained"])
        encoded = canonical_json(report)
        self.assertNotIn(str(source).encode("utf-8"), encoded)
        validation = validate_bytes(encoded)
        self.assertTrue(validation["valid"], validation["errors"])
        self.assertEqual(validation["artifactSchema"], "urn:marginbench:diagnostic-report:v1")

        with self.assertRaisesRegex(DiagnosticError, "repeat a candidate/episode pair"):
            diagnose_artifacts([source, source])

        other = PACKAGE_ROOT / "results" / "PRIME_GATE1_CANDIDATE3.json"
        with self.assertRaisesRegex(DiagnosticError, "explicit focus candidate"):
            diagnose_artifacts([source, other])
        focused = diagnose_artifacts(
            [source, other],
            focus_candidate="typed-work-guidance-v7",
        )
        self.assertEqual(focused["candidateCount"], 2)
        self.assertEqual(focused["focusCandidateID"], "typed-work-guidance-v7")
        self.assertEqual(focused["focus"], focused["candidates"][1])
        self.assertTrue(validate_bytes(canonical_json(focused))["valid"])

    @unittest.skipUnless(JSONSCHEMA_AVAILABLE, "jsonschema is not installed")
    def test_multi_candidate_diagnostics_publish_both_shapes_but_focus_one(self) -> None:
        digest_a = "a" * 64
        digest_b = "b" * 64
        episode_id = "directory_handoff:0:abcabcabcabc"

        def result(candidate: str, digest: str) -> EpisodeResult:
            return EpisodeResult(
                episode_id=episode_id,
                candidate_id=candidate,
                score=100.0,
                dimensions={
                    "outcome": 100.0,
                    "integrity": 100.0,
                    "protocol": 100.0,
                    "recovery": 100.0,
                    "efficiency": 100.0,
                },
                checks={"valid_command_use": True},
                command_count=0,
                invalid_command_count=0,
                duration_ms=1.0,
                safety_passed=True,
                source_preserved=True,
                margin_sha256=digest,
            )

        def shape(root: Path, candidate: str, digest: str, output_bytes: int) -> Path:
            trace = root / f"{digest[0]}.jsonl"
            nodes = [
                {"message": {
                    "role": "assistant",
                    "tool_calls": [{
                        "id": "context-1",
                        "name": "margin",
                        "arguments": json.dumps({
                            "arguments": ["context", ".", "--json", "--brief"],
                        }),
                    }],
                }},
                {"message": {
                    "role": "tool",
                    "tool_call_id": "context-1",
                    "content": json.dumps({
                        "ok": True,
                        "exitCode": 0,
                        "stdout": "x" * output_bytes,
                    }),
                }},
            ]
            if output_bytes > 4_096:
                nodes.extend([
                    {"message": {
                        "role": "assistant",
                        "tool_calls": [{
                            "id": "context-2",
                            "name": "margin",
                            "arguments": json.dumps({
                                "arguments": ["context", ".", "--json", "--brief"],
                            }),
                        }],
                    }},
                    {"message": {
                        "role": "tool",
                        "tool_call_id": "context-2",
                        "content": json.dumps({
                            "ok": True,
                            "exitCode": 0,
                            "stdout": "y" * output_bytes,
                        }),
                    }},
                ])
            trace.write_text(json.dumps({
                "traces": [{
                    "info": {"marginbench": {"marginSha256": digest}},
                    "task": {"data": {"scenario_id": "directory_handoff"}},
                    "agent": {"name": "author"},
                    "nodes": nodes,
                }],
            }) + "\n", encoding="utf-8")
            report = root / f"{digest[0]}-shape.json"
            payload = summarize_trace_shapes([trace])
            payload["candidateIDs"] = [candidate]
            report.write_bytes(canonical_json(payload))
            return report

        with tempfile.TemporaryDirectory(prefix="marginbench-label-neutral-") as temporary:
            root = Path(temporary)
            result_a = root / "a-result.json"
            result_b = root / "b-result.json"
            result_a.write_bytes(canonical_json(result("candidate-a", digest_a).to_dict()))
            result_b.write_bytes(canonical_json(result("candidate-b", digest_b).to_dict()))
            shape_a = shape(root, "candidate-a", digest_a, 5_000)
            shape_b = shape(root, "candidate-b", digest_b, 100)
            report = diagnose_artifacts(
                [result_a, result_b, shape_a, shape_b],
                focus_candidate="candidate-a",
            )

        self.assertEqual(report["artifactCount"], 4)
        evidence = next(
            item["evidence"]["responseSizeEvidence"]
            for item in report["findings"]
            if item["id"] == "heavy-context-responses"
        )
        self.assertEqual(evidence["resultCount"], 2)
        self.assertEqual(evidence["largerThan4096Count"], 2)
        self.assertTrue(validate_bytes(canonical_json(report))["valid"])

        broken = dict(report)
        broken["topOpportunity"] = "not-the-ranked-finding"
        invalid = validate_bytes(canonical_json(broken))
        self.assertFalse(invalid["valid"])
        self.assertTrue(any("topOpportunity" in error for error in invalid["errors"]))

        unsafe = EpisodeResult(
            episode_id="human_agent_relay:9:" + "b" * 12,
            candidate_id="unsafe-test-candidate",
            score=25.0,
            dimensions={
                "outcome": 100.0,
                "integrity": 0.0,
                "protocol": 100.0,
                "recovery": 100.0,
                "efficiency": 100.0,
            },
            checks={
                "source_expected": False,
                "valid_documents": False,
                "all_or_none": True,
                "workspace_policy": True,
            },
            command_count=0,
            invalid_command_count=0,
            duration_ms=1.0,
            safety_passed=False,
            source_preserved=False,
            margin_sha256="0" * 64,
        )
        with tempfile.TemporaryDirectory(prefix="marginbench-diagnostic-test-") as temporary:
            unsafe_path = Path(temporary) / "unsafe.json"
            unsafe_path.write_bytes(canonical_json(unsafe.to_dict()))
            unsafe_report = diagnose_artifacts([unsafe_path])
        self.assertEqual(unsafe_report["topOpportunity"], "safety-or-integrity")
        self.assertEqual(unsafe_report["recommendedNextExperiment"]["gate"], "local-safety")
        self.assertEqual(unsafe_report["recommendedNextExperiment"]["minimumMatchedEpisodes"], 0)
        self.assertTrue(validate_bytes(canonical_json(unsafe_report))["valid"])

        blocked_only = EpisodeResult(
            episode_id="directory_handoff:7:" + "c" * 12,
            candidate_id="guarded-test-candidate",
            score=25.0,
            dimensions={
                "outcome": 100.0,
                "integrity": 100.0,
                "protocol": 50.0,
                "recovery": 100.0,
                "efficiency": 100.0,
            },
            checks={
                "source_expected": True,
                "valid_documents": True,
                "all_or_none": True,
                "workspace_policy": False,
            },
            command_count=1,
            invalid_command_count=1,
            duration_ms=1.0,
            safety_passed=False,
            source_preserved=True,
            margin_sha256="0" * 64,
            events=(CommandEvent(
                role="reviewer",
                command="ls",
                exit_code=64,
                duration_ms=1.0,
                stdin_bytes=0,
                stdout_bytes=0,
                stderr_bytes=1,
                error_code="MARGINBENCH_COMMAND_BLOCKED",
                blocked=True,
            ),),
        )
        with tempfile.TemporaryDirectory(prefix="marginbench-policy-diagnostic-test-") as temporary:
            policy_path = Path(temporary) / "policy.json"
            policy_path.write_bytes(canonical_json(blocked_only.to_dict()))
            policy_report = diagnose_artifacts([policy_path])
        self.assertEqual(policy_report["topOpportunity"], "workspace-policy-attempt")
        self.assertIn("boundary held", policy_report["findings"][0]["title"])
        self.assertNotIn("damaged", policy_report["findings"][0]["title"])
        self.assertEqual(policy_report["recommendedNextExperiment"]["gate"], "local-safety")
        self.assertTrue(validate_bytes(canonical_json(policy_report))["valid"])

    @unittest.skipUnless(JSONSCHEMA_AVAILABLE, "jsonschema is not installed")
    def test_diagnostics_reject_infrastructure_runs_as_product_evidence(self) -> None:
        for name in (
            "topology-agent-handoff-continuing-v2-public-r0-summary.json",
            "topology-agent-handoff-continuing-v2-public-r0-run.json",
        ):
            source = PACKAGE_ROOT / "results" / name
            self.assertTrue(validate_artifact(source)["valid"])
            with self.assertRaisesRegex(DiagnosticError, "not product evidence"):
                diagnose_artifacts([source])

    @unittest.skipUnless(JSONSCHEMA_AVAILABLE, "jsonschema is not installed")
    def test_diagnostics_use_coarse_trace_sizes_only_as_supplementary_evidence(self) -> None:
        result = EpisodeResult(
            episode_id="directory_handoff:3:" + "d" * 12,
            candidate_id="compact-context-candidate",
            score=100.0,
            dimensions={
                "outcome": 100.0,
                "integrity": 100.0,
                "protocol": 100.0,
                "recovery": 100.0,
                "efficiency": 100.0,
            },
            checks={
                "source_expected": True,
                "valid_documents": True,
                "all_or_none": True,
                "workspace_expected_paths": True,
                "workspace_policy": True,
                "duplicate_free": True,
                "all_expected_annotations": True,
                "minimum_annotations": True,
                "committed_all": True,
                "no_unexpected_annotations": True,
                "required_recovery_observed": True,
                "required_commands": True,
                "valid_command_use": True,
                "attribution": True,
                "avoided_redundant_initial_reads": True,
            },
            command_count=0,
            invalid_command_count=0,
            duration_ms=1.0,
            safety_passed=True,
            source_preserved=True,
            margin_sha256="0" * 64,
        )
        private_marker = "private-context-result-5f31"
        nodes = []
        for index in range(3):
            identifier = f"context-{index}"
            nodes.extend((
                {"message": {
                    "role": "assistant",
                    "tool_calls": [{
                        "id": identifier,
                        "name": "margin",
                        "arguments": json.dumps({
                            "arguments": ["context", ".", "--json", "--brief"],
                        }),
                    }],
                }},
                {"message": {
                    "role": "tool",
                    "tool_call_id": identifier,
                    "content": json.dumps({
                        "ok": True,
                        "exitCode": 0,
                        "stdout": private_marker * 240,
                    }),
                }},
            ))
        raw_trace = {
            "traces": [{
                "task": {"data": {"scenario_id": "directory_handoff"}},
                "agent": {"name": "author"},
                "nodes": nodes,
            }],
        }
        with tempfile.TemporaryDirectory(prefix="marginbench-size-diagnostic-") as temporary:
            root = Path(temporary)
            result_path = root / "result.json"
            result_path.write_bytes(canonical_json(result.to_dict()))
            trace_path = root / "traces.jsonl"
            trace_path.write_text(json.dumps(raw_trace) + "\n", encoding="utf-8")
            shape = summarize_trace_shapes([trace_path])
            shape_path = root / "trace-shape.json"
            shape_path.write_bytes(canonical_json(shape))
            self.assertTrue(
                validate_bytes(result_path.read_bytes())["valid"],
                validate_bytes(result_path.read_bytes())["errors"],
            )
            self.assertTrue(
                validate_bytes(shape_path.read_bytes())["valid"],
                validate_bytes(shape_path.read_bytes())["errors"],
            )
            report = diagnose_artifacts([result_path, shape_path])

            with self.assertRaisesRegex(DiagnosticError, "no episodes"):
                diagnose_artifacts([shape_path])
            with self.assertRaisesRegex(DiagnosticError, "overlap"):
                diagnose_artifacts([result_path, shape_path, shape_path])

        self.assertEqual(report["artifactCount"], 2)
        self.assertEqual(report["episodeCount"], 1)
        self.assertEqual(report["topOpportunity"], "heavy-context-responses")
        evidence = report["findings"][0]["evidence"]["responseSizeEvidence"]
        self.assertEqual(evidence["command"], "context")
        self.assertEqual(evidence["resultCount"], 3)
        self.assertEqual(evidence["largerThan4096Count"], 3)
        self.assertEqual(evidence["buckets"], [{"name": "4097-16384", "count": 3}])
        self.assertFalse(report["privacy"]["exactResultSizesRetained"])
        encoded = canonical_json(report)
        self.assertNotIn(private_marker.encode("utf-8"), encoded)
        self.assertTrue(validate_bytes(encoded)["valid"])

        tampered = json.loads(encoded)
        tampered["findings"][0]["evidence"]["responseSizeEvidence"][
            "largerThan4096Count"
        ] = 2
        receipt = validate_bytes(canonical_json(tampered))
        self.assertFalse(receipt["valid"])
        self.assertTrue(any("large-response" in item for item in receipt["errors"]))

    @unittest.skipUnless(JSONSCHEMA_AVAILABLE, "jsonschema is not installed")
    def test_diagnostics_do_not_charge_full_context_sizes_to_the_brief_projection(self) -> None:
        result = EpisodeResult(
            episode_id="directory_handoff:4:" + "e" * 12,
            candidate_id="signature-scoped-context-candidate",
            score=100.0,
            dimensions={
                "outcome": 100.0,
                "integrity": 100.0,
                "protocol": 100.0,
                "recovery": 100.0,
                "efficiency": 100.0,
            },
            checks={
                "source_expected": True,
                "valid_documents": True,
                "all_or_none": True,
                "workspace_expected_paths": True,
                "workspace_policy": True,
                "duplicate_free": True,
                "all_expected_annotations": True,
                "minimum_annotations": True,
                "committed_all": True,
                "no_unexpected_annotations": True,
                "required_recovery_observed": True,
                "required_commands": True,
                "valid_command_use": True,
                "attribution": True,
                "avoided_redundant_initial_reads": True,
            },
            command_count=0,
            invalid_command_count=0,
            duration_ms=1.0,
            safety_passed=True,
            source_preserved=True,
            margin_sha256="0" * 64,
        )
        nodes = []
        for index, brief in enumerate((False, False, False, True, True)):
            identifier = f"context-{index}"
            arguments = ["context", ".", "--json"]
            if brief:
                arguments.append("--brief")
            nodes.extend((
                {"message": {
                    "role": "assistant",
                    "tool_calls": [{
                        "id": identifier,
                        "name": "margin",
                        "arguments": json.dumps({"arguments": arguments}),
                    }],
                }},
                {"message": {
                    "role": "tool",
                    "tool_call_id": identifier,
                    "content": json.dumps({
                        "ok": True,
                        "exitCode": 0,
                        "stdout": ("full-private-marker" * 1_000)
                        if not brief else ("brief-private-marker" * 40),
                    }),
                }},
            ))
        raw_trace = {
            "traces": [{
                "task": {"data": {"scenario_id": "directory_handoff"}},
                "agent": {"name": "author"},
                "nodes": nodes,
            }],
        }
        with tempfile.TemporaryDirectory(prefix="marginbench-signature-diagnostic-") as temporary:
            root = Path(temporary)
            result_path = root / "result.json"
            result_path.write_bytes(canonical_json(result.to_dict()))
            trace_path = root / "traces.jsonl"
            trace_path.write_text(json.dumps(raw_trace) + "\n", encoding="utf-8")
            shape_path = root / "trace-shape.json"
            shape_path.write_bytes(canonical_json(summarize_trace_shapes([trace_path])))
            report = diagnose_artifacts([result_path, shape_path])

        self.assertEqual(report["topOpportunity"], "no-ranked-defect")
        self.assertNotIn(
            "heavy-context-responses",
            {finding["id"] for finding in report["findings"]},
        )
        self.assertTrue(validate_bytes(canonical_json(report))["valid"])

    def test_diagnostics_flag_oversized_capability_discovery_without_exact_sizes(self) -> None:
        result = EpisodeResult(
            episode_id="directory_handoff:0:capability-size",
            candidate_id="compact-discovery-candidate",
            score=100.0,
            dimensions={
                "outcome": 100.0,
                "protocol": 100.0,
                "integrity": 100.0,
                "recovery": 100.0,
                "efficiency": 100.0,
            },
            checks={
                "source_expected": True,
                "valid_documents": True,
                "all_or_none": True,
                "workspace_expected_paths": True,
                "workspace_policy": True,
                "duplicate_free": True,
                "all_expected_annotations": True,
                "minimum_annotations": True,
                "committed_all": True,
                "no_unexpected_annotations": True,
                "required_recovery_observed": True,
                "required_commands": True,
                "valid_command_use": True,
                "attribution": True,
                "avoided_redundant_initial_reads": True,
            },
            command_count=0,
            invalid_command_count=0,
            duration_ms=1.0,
            safety_passed=True,
            source_preserved=True,
            margin_sha256="0" * 64,
        )
        private_marker = "private-capability-result-7d42"
        raw_trace = {
            "traces": [{
                "task": {"data": {"scenario_id": "directory_handoff"}},
                "agent": {"name": "author"},
                "nodes": [
                    {"message": {
                        "role": "assistant",
                        "tool_calls": [{
                            "id": "capability-1",
                            "name": "margin",
                            "arguments": json.dumps({
                                "arguments": [
                                    "capabilities", "--json", "--for", "handoff", "--brief",
                                ],
                            }),
                        }],
                    }},
                    {"message": {
                        "role": "tool",
                        "tool_call_id": "capability-1",
                        "content": json.dumps({
                            "ok": True,
                            "exitCode": 0,
                            "stdout": private_marker * 1_200,
                        }),
                    }},
                ],
            }],
        }
        with tempfile.TemporaryDirectory(prefix="marginbench-capability-diagnostic-") as temporary:
            root = Path(temporary)
            result_path = root / "result.json"
            result_path.write_bytes(canonical_json(result.to_dict()))
            trace_path = root / "traces.jsonl"
            trace_path.write_text(json.dumps(raw_trace) + "\n", encoding="utf-8")
            shape_path = root / "trace-shape.json"
            shape_path.write_bytes(canonical_json(summarize_trace_shapes([trace_path])))
            self.assertTrue(
                validate_bytes(result_path.read_bytes())["valid"],
                validate_bytes(result_path.read_bytes())["errors"],
            )
            self.assertTrue(
                validate_bytes(shape_path.read_bytes())["valid"],
                validate_bytes(shape_path.read_bytes())["errors"],
            )
            report = diagnose_artifacts([result_path, shape_path])

        self.assertEqual(report["topOpportunity"], "oversized-capability-responses")
        evidence = report["findings"][0]["evidence"]["responseSizeEvidence"]
        self.assertEqual(evidence["command"], "capabilities")
        self.assertEqual(evidence["resultCount"], 1)
        self.assertEqual(evidence["largerThan4096Count"], 1)
        self.assertEqual(evidence["buckets"], [{"name": "16385-65536", "count": 1}])
        encoded = canonical_json(report)
        self.assertNotIn(private_marker.encode("utf-8"), encoded)
        self.assertTrue(validate_bytes(encoded)["valid"])

    def test_diagnostics_flag_long_path_to_first_write_without_retaining_trace_content(self) -> None:
        result = EpisodeResult(
            episode_id="directory_handoff:0:write-latency",
            candidate_id="action-first-candidate",
            score=100.0,
            dimensions={
                "outcome": 100.0,
                "protocol": 100.0,
                "integrity": 100.0,
                "recovery": 100.0,
                "efficiency": 100.0,
            },
            checks={
                "source_expected": True,
                "valid_documents": True,
                "all_or_none": True,
                "workspace_expected_paths": True,
                "workspace_policy": True,
                "duplicate_free": True,
                "all_expected_annotations": True,
                "minimum_annotations": True,
                "committed_all": True,
                "no_unexpected_annotations": True,
                "required_recovery_observed": True,
                "required_commands": True,
                "valid_command_use": True,
                "attribution": True,
                "avoided_redundant_initial_reads": True,
            },
            command_count=0,
            invalid_command_count=0,
            duration_ms=1.0,
            safety_passed=True,
            source_preserved=True,
            margin_sha256="0" * 64,
        )
        secret = "private-latency-evidence-4d72"
        nodes = []
        for index in range(5):
            identifier = f"orientation-{index}"
            nodes.extend((
                {"message": {"role": "assistant", "tool_calls": [{
                    "id": identifier,
                    "name": "margin",
                    "arguments": json.dumps({"arguments": ["context", secret, "--brief"]}),
                }]}},
                {"message": {
                    "role": "tool",
                    "tool_call_id": identifier,
                    "content": json.dumps({"ok": True, "exitCode": 0, "stdout": secret}),
                }},
            ))
        nodes.extend((
            {"message": {"role": "assistant", "tool_calls": [{
                "id": "write",
                "name": "margin",
                "arguments": json.dumps({"arguments": [
                    "handoff", "add", secret, "-m", secret,
                ]}),
            }]}},
            {"message": {
                "role": "tool",
                "tool_call_id": "write",
                "content": json.dumps({"ok": True, "exitCode": 0}),
            }},
        ))
        raw_trace = {"traces": [{
            "task": {"data": {"scenario_id": "directory_handoff", "prompt": secret}},
            "agent": {"name": "author"},
            "nodes": nodes,
        }]}
        with tempfile.TemporaryDirectory(prefix="marginbench-write-diagnostic-") as temporary:
            root = Path(temporary)
            result_path = root / "result.json"
            result_path.write_bytes(canonical_json(result.to_dict()))
            trace_path = root / "traces.jsonl"
            trace_path.write_text(json.dumps(raw_trace) + "\n", encoding="utf-8")
            shape_path = root / "trace-shape.json"
            shape_path.write_bytes(canonical_json(summarize_trace_shapes([trace_path])))
            report = diagnose_artifacts([result_path, shape_path])

        self.assertEqual(report["topOpportunity"], "long-path-to-first-write")
        evidence = report["findings"][0]["evidence"]["writeLatencyEvidence"]
        self.assertEqual(evidence["fiveOrMorePreWriteCount"], 1)
        self.assertEqual(evidence["preWriteToolCallBuckets"], [
            {"name": "5-6", "count": 1},
        ])
        encoded = canonical_json(report)
        self.assertNotIn(secret.encode("utf-8"), encoded)
        self.assertTrue(validate_bytes(encoded)["valid"])

        tampered = json.loads(encoded)
        tampered["findings"][0]["evidence"]["writeLatencyEvidence"][
            "fiveOrMorePreWriteCount"
        ] = 2
        receipt = validate_bytes(canonical_json(tampered))
        self.assertFalse(receipt["valid"])
        self.assertTrue(any("delayed-write" in item for item in receipt["errors"]))

    @unittest.skipUnless(JSONSCHEMA_AVAILABLE, "jsonschema is not installed")
    def test_run_manifest_validation_recomputes_cost_and_rejects_tampering(self) -> None:
        margin_sha256 = CandidateManifest.create("validation-test", self.binary).margin_sha256
        published_events = (
            CommandEvent(
                role="author",
                command="stage create",
                exit_code=64,
                duration_ms=1,
                stdin_bytes=0,
                stdout_bytes=0,
                stderr_bytes=0,
                error_code="USAGE",
            ),
            *(CommandEvent(
                role="reviewer",
                command="context",
                exit_code=0,
                duration_ms=1,
                stdin_bytes=0,
                stdout_bytes=0,
                stderr_bytes=0,
            ) for _ in range(6)),
        )
        result = {
            "episodeID": "agent_agent_handoff:0:" + "a" * 12,
            "score": 100.0,
            "safetyPassed": True,
            "sourcePreserved": True,
            "commandCount": 7,
            "invalidCommandCount": 1,
            "eventSummary": summarize_command_events(published_events),
            "durationMs": 12.5,
            "marginSha256": margin_sha256,
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
                wall_timeout_seconds=300.0,
                live_proxy_timeout_seconds=120.0,
                minimum_start_interval_seconds=300.0,
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
            self.assertEqual(
                manifest["episodes"][0]["stopConditions"],
                [{"name": "agent_completed", "count": 2}],
            )
            artifact = output / "run.json"
            artifact.write_text(json.dumps(manifest), encoding="utf-8")
            self.assertTrue(validate_artifact(artifact)["valid"])
            diagnostic = diagnose_artifacts([artifact])
            self.assertEqual(diagnostic["errorCodes"], [{"name": "USAGE", "count": 1}])
            self.assertEqual(
                diagnostic["failingCommandPaths"],
                [{"name": "stage create", "count": 1}],
            )
            unsafe_summary = json.loads(json.dumps(manifest))
            unsafe_summary["episodes"][0]["eventSummary"]["commands"][0]["name"] = (
                "private secret"
            )
            receipt = validate_bytes(canonical_json(unsafe_summary))
            self.assertFalse(receipt["valid"])
            self.assertTrue(any("non-public command label" in item for item in receipt["errors"]))
            representation_manifest = json.loads(json.dumps(manifest))
            representation_manifest["track"] = "representation"
            artifact.write_text(json.dumps(representation_manifest), encoding="utf-8")
            self.assertTrue(validate_artifact(artifact)["valid"])
            artifact.write_text(json.dumps(manifest), encoding="utf-8")
            loaded = load_results(artifact)
            self.assertEqual(len(loaded), 1)
            self.assertEqual(loaded[0].candidate_id, "validation-test")
            self.assertEqual(loaded[0].episode_id, result["episodeID"])
            self.assertEqual(loaded[0].score, result["score"])
            self.assertEqual(loaded[0].events, ())
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
    def test_prime_summary_resolves_the_content_free_event_summary_schema(self) -> None:
        payload = json.loads(
            (PACKAGE_ROOT / "results" / "PRIME_GATE2_CONCURRENT_V7.json").read_text(
                encoding="utf-8"
            )
        )
        episode = payload["episodes"][0]
        command_count = episode["commandCount"]
        episode["eventSummary"] = {
            "commandCount": command_count,
            "successCount": command_count - 1,
            "failureCount": 1,
            "blockedCount": 0,
            "commands": [{
                "name": "comments add",
                "count": command_count,
                "successCount": command_count - 1,
                "failureCount": 1,
                "blockedCount": 0,
            }],
            "errors": [{"name": "USAGE", "count": 1}],
            "isTruncated": False,
        }
        receipt = validate_bytes(canonical_json(payload))
        self.assertTrue(receipt["valid"], receipt["errors"])
        episode["eventSummary"]["commands"][0]["name"] = "private identifier"
        receipt = validate_bytes(canonical_json(payload))
        self.assertFalse(receipt["valid"])
        self.assertTrue(any("non-public command label" in item for item in receipt["errors"]))

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

    @unittest.skipUnless(JSONSCHEMA_AVAILABLE, "jsonschema is not installed")
    def test_submission_binds_candidates_study_runs_and_recomputed_comparison(self) -> None:
        with tempfile.TemporaryDirectory(prefix="marginbench-submission-") as temporary:
            root = Path(temporary)
            baseline_manifest = CandidateManifest.create(
                "baseline",
                self.binary,
                settings={"guidance": "released"},
            )
            candidate_manifest = CandidateManifest.create(
                "candidate",
                self.binary,
                settings={"guidance": "compact"},
            )
            study = build_study_plan(
                baseline="baseline",
                candidate="candidate",
                scenarios=["human_agent_relay"],
                repetitions=1,
                key=KEY,
                development_cases=False,
            )
            planned = study["episodes"][0]

            def episode_result(candidate_id: str, score: float, duration: float) -> EpisodeResult:
                return EpisodeResult(
                    episode_id=planned["id"],
                    candidate_id=candidate_id,
                    score=score,
                    dimensions={"outcome": score},
                    checks={"exact": True},
                    command_count=1,
                    invalid_command_count=0,
                    duration_ms=duration,
                    safety_passed=True,
                    source_preserved=True,
                    margin_sha256=baseline_manifest.margin_sha256,
                )

            baseline_result = episode_result("baseline", 50, 10)
            candidate_result = episode_result("candidate", 60, 8)
            comparison = paired_compare([baseline_result], [candidate_result])

            def run_manifest(
                identifier: str,
                manifest: CandidateManifest,
                result: EpisodeResult,
            ) -> dict:
                return {
                    "schema": "urn:marginbench:run:v1",
                    "runID": identifier,
                    "status": "completed",
                    "track": "interface",
                    "benchmark": {
                        "name": "MarginBench",
                        "version": study["benchmarkVersion"],
                        "taskSet": study["taskSet"],
                        "developmentCases": study["developmentCases"],
                        "implementationSha256": "a" * 64,
                    },
                    "candidate": {
                        "id": manifest.id,
                        "marginSha256": manifest.margin_sha256,
                        "manualSha256": manifest.manual_sha256,
                        "settingsSha256": manifest.settings_sha256,
                    },
                    "execution": {
                        "adapter": "test",
                        "provider": "test",
                        "model": "test/model",
                        "harness": "test",
                        "runtime": "test",
                        "controlProfile": study["controlProfile"],
                        "roles": planned["roles"],
                        "startedAt": "2026-08-18T00:00:00Z",
                        "durationMs": result.duration_ms,
                        "limits": {"maxTurns": 1},
                        "retryPolicy": "none",
                        "priorInfrastructureAttempts": 0,
                    },
                    "episodes": [{
                        "id": planned["id"],
                        "scenario": planned["scenario"],
                        "fingerprint": planned["fingerprint"],
                        "repetition": planned["repetition"],
                        "score": result.score,
                        "safetyPassed": result.safety_passed,
                        "sourcePreserved": result.source_preserved,
                        "commandCount": result.command_count,
                        "invalidCommandCount": result.invalid_command_count,
                        "durationMs": result.duration_ms,
                        "marginSha256": result.margin_sha256,
                        "checks": result.checks,
                        "dimensions": result.dimensions,
                        "usage": {
                            "modelCalls": 1,
                            "promptTokens": 1,
                            "completionTokens": 1,
                            "cachedInputTokens": 0,
                            "reasoningTokens": 0,
                            "reportedCostUSD": 0.001,
                        },
                    }],
                    "cost": {
                        "currency": "USD",
                        "traceReported": 0.001,
                        "observedWalletDebit": 0.001,
                        "unreconciled": 0,
                    },
                    "privacy": {
                        "rawTracesPublished": False,
                        "credentialsPresent": False,
                        "promptsPublished": False,
                        "holdoutKeyPublished": False,
                    },
                }

            (root / "study.json").write_text(json.dumps(study), encoding="utf-8")
            execution_plan = build_execution_plan(root / "study.json")
            values = {
                "baseline.json": asdict(baseline_manifest),
                "candidate.json": asdict(candidate_manifest),
                "study.json": study,
                "execution.json": execution_plan,
                "comparison.json": comparison,
                "run-baseline.json": run_manifest("run-baseline", baseline_manifest, baseline_result),
                "run-candidate.json": run_manifest("run-candidate", candidate_manifest, candidate_result),
            }
            for name, value in values.items():
                (root / name).write_text(json.dumps(value), encoding="utf-8")

            manifest = build_submission(
                root,
                baseline_manifest=Path("baseline.json"),
                candidate_manifest=Path("candidate.json"),
                study_plan=Path("study.json"),
                execution_plan=Path("execution.json"),
                comparison=Path("comparison.json"),
                runs=[Path("run-baseline.json"), Path("run-candidate.json")],
            )
            manifest_path = root / "submission.json"
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
            receipt = verify_submission(manifest_path)
            self.assertTrue(receipt["valid"], receipt)
            self.assertEqual(receipt["artifactCount"], 7)
            self.assertTrue(validate_bytes(json.dumps(receipt).encode("utf-8"))["valid"])
            self.assertEqual(manifest["baseline"]["id"], "baseline")
            self.assertEqual(manifest["candidate"]["id"], "candidate")
            reversed_runs = build_submission(
                root,
                baseline_manifest=Path("baseline.json"),
                candidate_manifest=Path("candidate.json"),
                study_plan=Path("study.json"),
                execution_plan=Path("execution.json"),
                comparison=Path("comparison.json"),
                runs=[Path("run-candidate.json"), Path("run-baseline.json")],
            )
            self.assertEqual(reversed_runs, manifest)

            alias = root / "baseline-link.json"
            alias.symlink_to(root / "baseline.json")
            with self.assertRaisesRegex(SubmissionError, "symbolic link"):
                build_submission(
                    root,
                    baseline_manifest=Path("baseline-link.json"),
                    candidate_manifest=Path("candidate.json"),
                    study_plan=Path("study.json"),
                    execution_plan=Path("execution.json"),
                    comparison=Path("comparison.json"),
                    runs=[Path("run-baseline.json"), Path("run-candidate.json")],
                )
            alias.unlink()

            lowered_threshold = json.loads(json.dumps(comparison))
            lowered_threshold["minimumPairsForPromotion"] = 2
            (root / "comparison.json").write_text(
                json.dumps(lowered_threshold),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(SubmissionError, "promotion threshold"):
                build_submission(
                    root,
                    baseline_manifest=Path("baseline.json"),
                    candidate_manifest=Path("candidate.json"),
                    study_plan=Path("study.json"),
                    execution_plan=Path("execution.json"),
                    comparison=Path("comparison.json"),
                    runs=[Path("run-baseline.json"), Path("run-candidate.json")],
                )
            (root / "comparison.json").write_text(json.dumps(comparison), encoding="utf-8")

            changed_model = json.loads(json.dumps(values["run-candidate.json"]))
            changed_model["execution"]["model"] = "different/model"
            (root / "run-candidate.json").write_text(
                json.dumps(changed_model),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(SubmissionError, "different execution controls"):
                build_submission(
                    root,
                    baseline_manifest=Path("baseline.json"),
                    candidate_manifest=Path("candidate.json"),
                    study_plan=Path("study.json"),
                    execution_plan=Path("execution.json"),
                    comparison=Path("comparison.json"),
                    runs=[Path("run-baseline.json"), Path("run-candidate.json")],
                )
            (root / "run-candidate.json").write_text(
                json.dumps(values["run-candidate.json"]),
                encoding="utf-8",
            )

            reordered = json.loads(json.dumps(execution_plan))
            reordered["jobs"] = list(reversed(reordered["jobs"]))
            for ordinal, job in enumerate(reordered["jobs"]):
                job["ordinal"] = ordinal
            reordered["id"] = submission_identifier(reordered)
            (root / "execution.json").write_text(json.dumps(reordered), encoding="utf-8")
            with self.assertRaisesRegex(SubmissionError, "deterministic expansion"):
                build_submission(
                    root,
                    baseline_manifest=Path("baseline.json"),
                    candidate_manifest=Path("candidate.json"),
                    study_plan=Path("study.json"),
                    execution_plan=Path("execution.json"),
                    comparison=Path("comparison.json"),
                    runs=[Path("run-baseline.json"), Path("run-candidate.json")],
                )
            (root / "execution.json").write_text(
                json.dumps(execution_plan),
                encoding="utf-8",
            )

            environment = dict(os.environ)
            environment["PYTHONPATH"] = str(PACKAGE_ROOT)
            created = subprocess.run(
                [
                    sys.executable,
                    "-m",
                    "marginbench.cli",
                    "submission",
                    "create",
                    ".",
                    "--baseline-manifest",
                    "baseline.json",
                    "--candidate-manifest",
                    "candidate.json",
                    "--study-plan",
                    "study.json",
                    "--execution-plan",
                    "execution.json",
                    "--comparison",
                    "comparison.json",
                    "--run",
                    "run-baseline.json",
                    "--run",
                    "run-candidate.json",
                ],
                cwd=root,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env=environment,
                check=False,
            )
            self.assertEqual(created.returncode, 0, created.stderr.decode(errors="replace"))
            self.assertEqual(json.loads(created.stdout), manifest)
            cli_manifest = root / "submission-cli.json"
            cli_manifest.write_bytes(created.stdout)
            verified = subprocess.run(
                [
                    sys.executable,
                    "-m",
                    "marginbench.cli",
                    "submission",
                    "verify",
                    str(cli_manifest),
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env=environment,
                check=False,
            )
            self.assertEqual(verified.returncode, 0, verified.stderr.decode(errors="replace"))
            self.assertTrue(json.loads(verified.stdout)["valid"])

            legacy_run = json.loads(json.dumps(values["run-candidate.json"]))
            del legacy_run["episodes"][0]["sourcePreserved"]
            (root / "run-candidate.json").write_text(json.dumps(legacy_run), encoding="utf-8")
            with self.assertRaisesRegex(SubmissionError, "publication fields"):
                build_submission(
                    root,
                    baseline_manifest=Path("baseline.json"),
                    candidate_manifest=Path("candidate.json"),
                    study_plan=Path("study.json"),
                    execution_plan=Path("execution.json"),
                    comparison=Path("comparison.json"),
                    runs=[Path("run-baseline.json"), Path("run-candidate.json")],
                )
            (root / "run-candidate.json").write_text(
                json.dumps(values["run-candidate.json"]),
                encoding="utf-8",
            )

            values["run-candidate.json"]["episodes"][0]["score"] = 61
            (root / "run-candidate.json").write_text(
                json.dumps(values["run-candidate.json"]),
                encoding="utf-8",
            )
            receipt = verify_submission(manifest_path)
            self.assertFalse(receipt["valid"])
            self.assertEqual(receipt["error"]["code"], "SUBMISSION_INCONSISTENT")

            (root / "run-candidate.json").write_text(
                json.dumps(run_manifest("run-candidate", candidate_manifest, candidate_result)),
                encoding="utf-8",
            )
            comparison["meanScoreDelta"] = 9
            (root / "comparison.json").write_text(json.dumps(comparison), encoding="utf-8")
            with self.assertRaisesRegex(SubmissionError, "recomputation"):
                build_submission(
                    root,
                    baseline_manifest=Path("baseline.json"),
                    candidate_manifest=Path("candidate.json"),
                    study_plan=Path("study.json"),
                    execution_plan=Path("execution.json"),
                    comparison=Path("comparison.json"),
                    runs=[Path("run-baseline.json"), Path("run-candidate.json")],
                )


if __name__ == "__main__":
    unittest.main()
