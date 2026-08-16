#!/usr/bin/env python3

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path


EVAL_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(EVAL_DIR))

from compare import compare  # noqa: E402
from eval_lib import find_margin_binary, load_suite, prepare_case, usage_and_trace  # noqa: E402
from gate import gate_eligible  # noqa: E402
from merge import merge  # noqa: E402
from proxy import normalize_argv, would_launch_gui  # noqa: E402
from report import aggregate, render  # noqa: E402
from run import adjust_first_pass_for_trace, executable_version, repair_cycles, telemetry_integrity  # noqa: E402
from score import score_case  # noqa: E402
from snapshot import minimize  # noqa: E402


class ManifestTests(unittest.TestCase):
    def test_every_scenario_is_complete_and_uniquely_scored(self) -> None:
        scenarios = load_suite()
        self.assertEqual(len(scenarios), 6)
        for scenario in scenarios:
            self.assertEqual(sum(int(check["points"]) for check in scenario.checks), 100)
            ids = [check["id"] for check in scenario.checks]
            self.assertEqual(len(ids), len(set(ids)))
            self.assertTrue(scenario.prompt.read_text(encoding="utf-8").strip())

    def test_executable_version_accepts_stderr_output(self) -> None:
        with tempfile.TemporaryDirectory(prefix="margin-eval-test-") as temporary:
            executable = Path(temporary) / "version-on-stderr"
            executable.write_text("#!/bin/sh\nprintf '9.9.9\\n' >&2\n", encoding="utf-8")
            executable.chmod(0o755)
            self.assertEqual(executable_version(str(executable)), "9.9.9")


class PrivacyTests(unittest.TestCase):
    def test_proxy_redacts_document_and_sensitive_values(self) -> None:
        document = "/tmp/case/review.md"
        actual = normalize_argv(
            ["comments", "add", document, "-m", "private body", "--quote", "private quote", "--id", "abc"],
            document,
        )
        self.assertEqual(actual[:3], ["comments", "add", "$DOCUMENT"])
        self.assertNotIn("private body", actual)
        self.assertNotIn("private quote", actual)
        self.assertIn("--id", actual)
        self.assertIn("abc", actual)

    def test_proxy_redacts_supported_body_alias(self) -> None:
        actual = normalize_argv(["comment", "add", "review.md", "--body", "private body"], None)
        self.assertNotIn("private body", actual)

    def test_proxy_redacts_inline_sensitive_values(self) -> None:
        actual = normalize_argv(["comments", "add", "review.md", "--message=private body", "--quote=private quote"], None)
        encoded = json.dumps(actual)
        self.assertNotIn("private body", encoded)
        self.assertNotIn("private quote", encoded)
        self.assertIn("--message=sha256:", encoded)

    def test_headless_proxy_blocks_gui_routes_only(self) -> None:
        self.assertTrue(would_launch_gui([]))
        self.assertTrue(would_launch_gui(["open", "review.md"]))
        self.assertTrue(would_launch_gui(["review.md"]))
        self.assertFalse(would_launch_gui(["review", "review.md", "--json"]))
        self.assertFalse(would_launch_gui(["comments", "list", "review.md"]))

    def test_trace_detects_direct_document_reads_and_retains_only_hashes(self) -> None:
        events = [
            {"type": "tool_execution_start", "args": {"code": "Path('review.md').read_text()"}},
            {"type": "message_end", "message": {"role": "assistant", "usage": {"input": 4, "output": 2, "cost": {"total": 0.01}}}},
        ]
        payload = ("\n".join(json.dumps(item) for item in events) + "\n").encode()
        usage, trace = usage_and_trace(payload)
        self.assertEqual(trace["directDocumentReads"], 1)
        self.assertFalse(trace["policyCompliant"])
        self.assertNotIn("review.md", json.dumps(trace))
        self.assertEqual(usage["input"], 4)
        self.assertEqual(usage["cost"], 0.01)

    def test_trace_detects_grader_and_credential_reconnaissance(self) -> None:
        events = [{
            "type": "tool_execution_start",
            "args": {"code": "Path('../scenario.json').read_text(); print(os.environ)"},
        }]
        _, trace = usage_and_trace((json.dumps(events[0]) + "\n").encode())
        self.assertEqual(trace["harnessAccesses"], 1)
        self.assertEqual(trace["sensitiveAccesses"], 1)
        self.assertFalse(trace["policyCompliant"])

    def test_trace_detects_common_shell_reads_and_writes(self) -> None:
        events = [
            {"type": "tool_execution_start", "args": {"code": "rg cache review.md"}},
            {"type": "tool_execution_start", "args": {"code": "printf changed > review.md"}},
        ]
        payload = ("\n".join(json.dumps(item) for item in events) + "\n").encode()
        _, trace = usage_and_trace(payload)
        self.assertEqual(trace["directDocumentReads"], 1)
        self.assertEqual(trace["directDocumentWrites"], 1)
        self.assertFalse(trace["policyCompliant"])


class ScoringTests(unittest.TestCase):
    def setUp(self) -> None:
        self.binary = find_margin_binary(None)
        if self.binary is None:
            self.skipTest("Margin CLI is not built")

    def test_empty_agent_attempt_is_partial_not_saturated(self) -> None:
        scenario = load_suite(["safe_retries"])[0]
        with tempfile.TemporaryDirectory(prefix="margin-eval-test-") as temporary:
            case = Path(temporary)
            prepare_case(scenario, case, self.binary)
            result = score_case(case, scenario, self.binary)
            self.assertLess(result["score"], 50)
            self.assertIn("idempotent_comment", result["failedCheckIDs"])
            self.assertTrue(result["sourcePreserved"])

    def test_noop_attempt_cannot_pass_any_scenario(self) -> None:
        for scenario in load_suite():
            with self.subTest(scenario=scenario.id), tempfile.TemporaryDirectory(prefix="margin-eval-test-") as temporary:
                case = Path(temporary)
                prepare_case(scenario, case, self.binary)
                result = score_case(case, scenario, self.binary)
                self.assertLess(result["score"], 100)
                self.assertTrue(result["failedCheckIDs"])

    def test_direct_access_triggers_noncompensatory_cap(self) -> None:
        scenario = load_suite(["safe_retries"])[0]
        with tempfile.TemporaryDirectory(prefix="margin-eval-test-") as temporary:
            case = Path(temporary)
            prepare_case(scenario, case, self.binary)
            (case / "trace.json").write_text(json.dumps({
                "directDocumentReads": 1,
                "directDocumentWrites": 0,
                "policyCompliant": False,
            }), encoding="utf-8")
            result = score_case(case, scenario, self.binary)
            self.assertLessEqual(result["score"], 70)
            self.assertIn("cli_only_policy", result["failedCheckIDs"])

    def test_telemetry_tampering_triggers_hard_cap(self) -> None:
        scenario = load_suite(["safe_retries"])[0]
        with tempfile.TemporaryDirectory(prefix="margin-eval-test-") as temporary:
            case = Path(temporary)
            prepare_case(scenario, case, self.binary)
            (case / "integrity.json").write_text(
                json.dumps({"ok": False, "reasons": ["command_log_shrank_after_gate"]}),
                encoding="utf-8",
            )
            result = score_case(case, scenario, self.binary)
            self.assertLessEqual(result["score"], 30)
            self.assertIn({"check": "telemetry_integrity", "maxScore": 30}, result["appliedCaps"])

    def test_first_pass_includes_late_trace_penalty(self) -> None:
        scenario = load_suite(["safe_retries"])[0]
        value, failures = adjust_first_pass_for_trace(
            53,
            ["id_conflict"],
            [{"id": "cli_only_policy", "possible": 5}],
            {"policyCompliant": False},
            scenario,
        )
        self.assertEqual(value, 48)
        self.assertIn("cli_only_policy", failures)

    def test_only_repairable_checks_block_completion_gate(self) -> None:
        self.assertFalse(gate_eligible({"type": "command_budget"}))
        self.assertFalse(gate_eligible({"type": "trace_policy"}))
        self.assertFalse(gate_eligible({"type": "command", "expect": {"first": True}}))
        self.assertTrue(gate_eligible({"type": "comment"}))
        self.assertTrue(gate_eligible({"type": "command_sequence"}))


class ComparisonTests(unittest.TestCase):
    def test_comparison_flags_score_and_safety_regressions(self) -> None:
        metadata = {"harnessSha256": "same", "scenarioHashes": {"case": "same"}}
        baseline = {"metadata": metadata, "runs": [{
            "commandCount": 8,
            "finalScore": 100,
            "firstPassScore": 90,
            "model": "openai/test",
            "policyCompliant": True,
            "protocolValid": True,
            "repetition": 1,
            "scenario": "case",
            "sourcePreserved": True,
        }]}
        candidate = {"metadata": metadata, "runs": [{
            "commandCount": 12,
            "finalScore": 80,
            "firstPassScore": 70,
            "model": "openai/test",
            "policyCompliant": False,
            "protocolValid": True,
            "repetition": 1,
            "scenario": "case",
            "sourcePreserved": True,
        }]}
        result = compare(baseline, candidate, 0, 0, 2)
        reasons = {item["reason"] for item in result["regressions"]}
        self.assertFalse(result["passed"])
        self.assertIn("final_score", reasons)
        self.assertIn("first_pass_score", reasons)
        self.assertIn("command_efficiency", reasons)
        self.assertIn("policyCompliant", reasons)

    def test_repair_cycles_require_commands_after_failed_gate(self) -> None:
        gates = [
            {"failedCheckIDs": ["x"], "timestamp": "2026-01-01T00:00:02+00:00"},
            {"failedCheckIDs": [], "timestamp": "2026-01-01T00:00:04+00:00"},
        ]
        commands = [
            {"timestamp": "2026-01-01T00:00:01+00:00"},
            {"timestamp": "2026-01-01T00:00:03+00:00"},
        ]
        self.assertEqual(repair_cycles(gates, commands), 1)

    def test_integrity_detects_command_log_truncation(self) -> None:
        result = telemetry_integrity(
            [{"attempt": 1, "commandCount": 7}],
            [{"timestamp": "2026-01-01T00:00:01+00:00"}],
        )
        self.assertFalse(result["ok"])
        self.assertIn("command_log_shrank_after_gate", result["reasons"])

    def test_dimension_summary_applies_late_policy_audit_to_first_pass(self) -> None:
        payload = {"runs": [{
            "dimensions": {"safety": {"earned": 0, "possible": 5}},
            "firstPassDimensions": {"safety": {"earned": 5, "possible": 5}},
            "finalScore": 70,
            "firstPassScore": 70,
            "model": "test",
            "policyCompliant": False,
            "scenario": "test",
        }]}
        self.assertEqual(aggregate(payload)["dimensions"]["safety"]["firstPassPercent"], 0)

    def test_merge_rejects_incompatible_scenario_fingerprints(self) -> None:
        with tempfile.TemporaryDirectory(prefix="margin-eval-test-") as temporary:
            first = Path(temporary) / "first.json"
            second = Path(temporary) / "second.json"
            first.write_text("{}", encoding="utf-8")
            second.write_text("{}", encoding="utf-8")
            payload_a = {"metadata": {"scenarioHashes": {"case": "a"}}, "runs": []}
            payload_b = {"metadata": {"scenarioHashes": {"case": "b"}}, "runs": []}
            with self.assertRaises(ValueError):
                merge([(first, payload_a), (second, payload_b)], "test")

    def test_snapshot_removes_paths_and_verbose_event_counts(self) -> None:
        with tempfile.TemporaryDirectory(prefix="margin-eval-test-") as temporary:
            source = Path(temporary) / "source.json"
            source.write_text("{}", encoding="utf-8")
            payload = {
                "metadata": {"experiment": "test"},
                "runs": [{
                    "model": "test",
                    "runDir": "/private/path",
                    "scenario": "test",
                    "sourceEvalSet": "/private/source",
                    "usage": {"cost": 1.0, "eventCounts": {"secret": 2}, "input": 3, "output": 4},
                }],
            }
            result = minimize(payload, source)
            encoded = json.dumps(result)
            self.assertNotIn("/private", encoded)
            self.assertNotIn("eventCounts", encoded)

    def test_markdown_report_has_no_trailing_whitespace(self) -> None:
        payload = {"metadata": {"experiment": "test"}, "runs": []}
        self.assertFalse(any(line.endswith(" ") for line in render(payload).splitlines()))


if __name__ == "__main__":
    unittest.main()
