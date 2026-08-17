#!/usr/bin/env python3

from __future__ import annotations

import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


EVAL_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(EVAL_DIR))

from compare import compare  # noqa: E402
from eval_lib import (  # noqa: E402
    HELP_WARM_SAMPLE_COUNT,
    HELP_WARMUP_COUNT,
    CommandResult,
    EvalError,
    _build_help_contract,
    assert_no_raw_values,
    create_holdout_key,
    find_margin_binary,
    load_suite,
    probe_capabilities,
    read_holdout_key,
    sanitize_argv,
)
from protocol import CHECKS, run_protocol_suite  # noqa: E402
from proxy import arguments_are_confined, would_launch_gui  # noqa: E402
from relay import (  # noqa: E402
    FOCUSED_HELP_MAX_BYTES,
    TRUSTED_EXTENSION_PATH,
    ModelSpec,
    TeamSpec,
    _agent_command,
    _expected_annotation_checks,
    _focused_cli_reference,
    agent_environment,
    run_live_case,
    summarize_agent_stream,
)
from report import aggregate, mean_confidence_interval, render  # noqa: E402
from run import _prime_tool_startup_probe, _token_budget_metadata  # noqa: E402
from scenarios import AgentTask, generate_case  # noqa: E402


EXPECTED_SCENARIOS = {
    "human_agent_relay",
    "agent_agent_handoff",
    "concurrent_agents_directory",
    "staged_multifile_atomic",
    "source_drift_reanchor",
    "distributed_semantic_merge",
    "suggestions_accept_reject",
    "adversarial_prompt_injection",
    "bounded_context",
    "collaborator_awareness",
    "duplicate_avoidance",
    "crash_retry_recovery",
}


class SuiteTests(unittest.TestCase):
    def test_suite_covers_every_required_collaboration_environment(self) -> None:
        scenarios = load_suite()
        self.assertEqual({scenario.id for scenario in scenarios}, EXPECTED_SCENARIOS)
        self.assertTrue(all(scenario.oracles for scenario in scenarios))
        self.assertTrue(all(scenario.required_capabilities for scenario in scenarios))

    def test_currently_adapted_scenarios_have_deterministic_oracles(self) -> None:
        self.assertEqual(set(CHECKS), EXPECTED_SCENARIOS)

    def test_unknown_selection_is_rejected(self) -> None:
        with self.assertRaises(EvalError):
            load_suite(["does_not_exist"])


class HoldoutTests(unittest.TestCase):
    def test_generation_is_repeatable_for_pairing_but_changes_with_key_and_repetition(self) -> None:
        scenario = load_suite(["agent_agent_handoff"])[0]
        first = generate_case(scenario, b"a" * 32, 4)
        repeat = generate_case(scenario, b"a" * 32, 4)
        different_key = generate_case(scenario, b"b" * 32, 4)
        different_repetition = generate_case(scenario, b"a" * 32, 5)
        self.assertEqual(first.fingerprint, repeat.fingerprint)
        self.assertEqual(first.files, repeat.files)
        self.assertEqual(first.tasks, repeat.tasks)
        self.assertNotEqual(first.fingerprint, different_key.fingerprint)
        self.assertNotEqual(first.fingerprint, different_repetition.fingerprint)
        self.assertNotEqual(first.files, different_key.files)

    def test_every_generator_has_hidden_material_and_no_checked_in_fixture_dependency(self) -> None:
        for index, scenario in enumerate(load_suite()):
            with self.subTest(scenario=scenario.id):
                generated = generate_case(scenario, bytes([index + 1]) * 32, index)
                self.assertTrue(generated.files)
                self.assertEqual(len(generated.tasks), scenario.agents)
                self.assertTrue(generated.forbidden_retention)
                self.assertTrue(generated.fingerprint.startswith("hmac-sha256:"))
                self.assertTrue(all(task.capability_workflow for task in generated.tasks))

    def test_large_context_fixture_is_adversarially_large(self) -> None:
        scenario = load_suite(["bounded_context"])[0]
        generated = generate_case(scenario, b"c" * 32, 0)
        self.assertGreater(len(generated.files["large.md"].encode("utf-8")), 100_000)

    def test_suggestion_live_prompt_supplies_every_exact_scored_body(self) -> None:
        scenario = load_suite(["suggestions_accept_reject"])[0]
        generated = generate_case(scenario, b"suggestion-prompt-holdout-key!!"[:32], 0)
        author_prompt = generated.tasks[0].prompt
        self.assertTrue(generated.expected["commentBodies"])
        for body in generated.expected["commentBodies"]:
            self.assertIn(body, author_prompt)

    def test_staged_live_prompt_hands_off_the_exact_hidden_plan(self) -> None:
        scenario = load_suite(["staged_multifile_atomic"])[0]
        generated = generate_case(scenario, b"staged-prompt-holdout-key!!!!!"[:32], 0)
        handoff = generated.expected["handoffBody"]
        self.assertIn(handoff, generated.tasks[0].prompt)
        self.assertIn("stage show` intentionally omits contribution bodies", generated.tasks[1].prompt)
        self.assertIn("use `stage refresh` to create a distinct immutable stage", generated.tasks[1].prompt)
        self.assertIn(("stage", "refresh"), generated.tasks[1].help_paths)
        for body in generated.expected["stagedBodies"].values():
            self.assertIn(body, handoff)

    def test_keygen_uses_private_mode_and_reader_rejects_public_mode(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "holdout.key"
            create_holdout_key(path)
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            self.assertEqual(len(read_holdout_key(path)), 32)
            path.chmod(0o644)
            with self.assertRaises(EvalError):
                read_holdout_key(path)


class PrivacyTests(unittest.TestCase):
    def test_command_sanitization_redacts_realpath_ids_actors_and_bodies(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workspace = Path(temporary) / "workspace"
            workspace.mkdir()
            document = workspace / "review.md"
            document.write_text("# Secret\n", encoding="utf-8")
            actual = sanitize_argv([
                "comments", "reply", str(document), "urn:uuid:11111111-1111-4111-8111-111111111111",
                "-m", "private body", "--actor-id", "urn:margin:eval:agent:private",
            ], workspace)
            encoded = json.dumps(actual)
            self.assertIn("$WORKSPACE/review.md", actual)
            self.assertNotIn("private body", encoded)
            self.assertNotIn("11111111-1111-4111-8111-111111111111", encoded)
            self.assertNotIn("urn:margin:eval:agent:private", encoded)

    def test_privacy_assertion_detects_raw_holdout_value(self) -> None:
        assert_no_raw_values({"valueHash": "sha256:abc"}, ["private body"])
        with self.assertRaises(EvalError):
            assert_no_raw_values({"value": "private body"}, ["private body"])

    def test_agent_stream_retains_hashes_not_raw_tool_text(self) -> None:
        events = [
            {"type": "tool_execution_start", "args": {"code": "cat review.md"}},
            {"type": "tool_execution_start", "args": {"code": "cat Evals/collaboration/suite.json"}},
            {"type": "tool_execution_start", "args": {"code": "printenv"}},
            {"type": "message_end", "message": {"role": "assistant", "usage": {"input": 4, "output": 2, "cost": {"total": 0.1}}}},
        ]
        payload = ("\n".join(json.dumps(event) for event in events) + "\n").encode()
        usage, trace = summarize_agent_stream(payload, ["review.md"])
        self.assertEqual(usage["input"], 4)
        self.assertEqual(trace["directAccesses"], 1)
        self.assertEqual(trace["harnessAccesses"], 1)
        self.assertEqual(trace["sensitiveAccesses"], 1)
        self.assertFalse(trace["policyCompliant"])
        self.assertNotIn("cat review.md", json.dumps(trace))

    def test_agent_stream_detects_direct_access_without_literal_fixture_name(self) -> None:
        events = [
            {"type": "tool_execution_start", "args": {"code": "cat *.md"}},
            {"type": "tool_execution_start", "args": {"code": "margin review review.md --json"}},
        ]
        payload = ("\n".join(json.dumps(event) for event in events) + "\n").encode()
        _, trace = summarize_agent_stream(payload, ["review.md"])
        self.assertEqual(trace["directAccesses"], 1)
        self.assertFalse(trace["policyCompliant"])

    def test_agent_stream_allows_local_operation_plan_computation(self) -> None:
        event = {
            "type": "tool_execution_start",
            "args": {"code": "python3 -c 'import json; print(json.dumps({\"version\": 1}))'"},
        }
        payload = (json.dumps(event) + "\n").encode()
        _, trace = summarize_agent_stream(payload, ["review.md"])
        self.assertEqual(trace["directAccesses"], 0)
        self.assertTrue(trace["policyCompliant"])

    def test_agent_environment_does_not_forward_host_secrets(self) -> None:
        environment = agent_environment({
            "HOME": "/safe/home",
            "LANG": "en_US.UTF-8",
            "OPENAI_API_KEY": "secret",
            "CI_JOB_TOKEN": "secret-too",
            "UNRELATED_HOST_VALUE": "private",
        })
        self.assertEqual(environment, {"HOME": "/safe/home", "LANG": "en_US.UTF-8"})

    def test_proxy_blocks_app_launch_routes(self) -> None:
        self.assertTrue(would_launch_gui([]))
        self.assertTrue(would_launch_gui(["open", "review.md"]))
        self.assertTrue(would_launch_gui(["review.md"]))
        self.assertFalse(would_launch_gui(["context", "review.md", "--json"]))
        self.assertFalse(would_launch_gui(["collaborators", "review.md", "--json"]))
        self.assertFalse(would_launch_gui(["comments", "list", "review.md"]))

    def test_confined_proxy_rejects_every_workspace_escape_spelling(self) -> None:
        self.assertTrue(arguments_are_confined([
            "stage", "create", ".", "--operations-file", "-",
        ]))
        self.assertTrue(arguments_are_confined([
            "comments", "add", "notes/review.md", "-m", "Keep human/agent context.",
        ]))
        for escaped in (
            "/etc/passwd",
            "../outside.md",
            "notes/../../outside.md",
            "~/credentials",
            "file:///etc/passwd",
            "--operations-file=../../outside.json",
            "C:\\outside\\secret.md",
        ):
            with self.subTest(escaped=escaped):
                self.assertFalse(arguments_are_confined(["read", escaped, "--json"]))


class CapabilityTests(unittest.TestCase):
    @staticmethod
    def _command(duration_ms: float, *, output: bytes = b"stable help\n") -> CommandResult:
        return CommandResult(
            argv=("--help",),
            exit_code=0,
            stdout=output,
            stderr=b"",
            duration_ms=duration_ms,
        )

    def test_help_performance_separates_cold_from_warm_p95(self) -> None:
        contract = _build_help_contract(
            self._command(300),
            [self._command(20) for _ in range(HELP_WARMUP_COUNT)],
            [self._command(12) for _ in range(HELP_WARM_SAMPLE_COUNT)],
        )
        self.assertEqual(contract["coldMs"], 300)
        self.assertEqual(contract["warmP95Ms"], 12)
        self.assertEqual(contract["warmupCount"], 3)
        self.assertEqual(contract["warmSampleCount"], 20)
        self.assertTrue(contract["warmP95WithinBudget"])

    def test_slow_warm_help_fails_the_static_contract(self) -> None:
        help_calls = 0

        def fake_run(_binary: Path, arguments: list[str], **_kwargs: object) -> CommandResult:
            nonlocal help_calls
            if arguments == ["--help"]:
                help_calls += 1
                duration = 250 if help_calls == 1 else (10 if help_calls <= 4 else 125)
                return self._command(
                    duration,
                    output=b"margin comments add comments reply comments list --if-revision --if-content-sha --id\n",
                )
            return CommandResult(tuple(arguments), 0, b"comments\n", b"", 1)

        with tempfile.TemporaryDirectory() as temporary:
            binary = Path(temporary) / "fake-margin"
            binary.write_bytes(b"fake")
            with patch("eval_lib.run_command", side_effect=fake_run):
                probe = probe_capabilities(binary)
        contract = probe["helpContract"]
        self.assertEqual(help_calls, 1 + HELP_WARMUP_COUNT + HELP_WARM_SAMPLE_COUNT)
        self.assertEqual(contract["coldMs"], 250)
        self.assertEqual(contract["warmP95Ms"], 125)
        self.assertFalse(contract["warmP95WithinBudget"])
        self.assertFalse(probe["staticContractPassed"])

    def test_capability_probe_uses_static_help_and_skips_absent_surfaces(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            binary = Path(temporary) / "fake-margin"
            binary.write_text(
                "#!/bin/sh\n"
                "printf '%s\\n' 'margin comments add comments reply comments list --if-revision --if-content-sha --id'\n",
                encoding="utf-8",
            )
            binary.chmod(0o755)
            probe = probe_capabilities(binary)
            self.assertTrue(probe["capabilities"]["comments"]["available"])
            self.assertTrue(probe["capabilities"]["compare_and_swap"]["available"])
            self.assertFalse(probe["capabilities"]["bounded_context"]["available"])
            self.assertTrue(probe["helpContract"]["deterministicAcrossDirectories"])

    def test_structured_catalog_does_not_treat_advertised_unsupported_commands_as_available(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            binary = Path(temporary) / "fake-margin"
            binary.write_text(
                """#!/usr/bin/env python3
import json, sys
if sys.argv[1:] == ['capabilities', '--json']:
    print(json.dumps({'commands':[
        {'path':['comments','add'],'availability':'available','options':[{'names':['--id','--if-revision','--if-content-sha']}]},
        {'path':['comments','reply'],'availability':'available','options':[]},
        {'path':['comments','list'],'availability':'available','options':[]},
        {'path':['context'],'availability':'unsupported','options':[]},
        {'path':['handoff'],'availability':'available','options':[]},
        {'path':['merge'],'availability':'unsupported','options':[]}
    ]}))
else:
    print('margin capabilities --json; margin context FILE --json; margin merge three-way')
""",
                encoding="utf-8",
            )
            binary.chmod(0o755)
            probe = probe_capabilities(binary)
            self.assertTrue(probe["capabilities"]["comments"]["available"])
            self.assertFalse(probe["capabilities"]["bounded_context"]["available"])
            self.assertFalse(probe["capabilities"]["semantic_merge"]["available"])
            self.assertFalse(probe["capabilities"]["typed_contributions"]["available"])
            self.assertEqual(probe["capabilities"]["bounded_context"]["evidence"], "structured_unsupported")

    def test_structured_catalog_detects_immutable_stage_refresh_separately(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            binary = Path(temporary) / "fake-margin"
            binary.write_text(
                """#!/usr/bin/env python3
import json, sys
if sys.argv[1:] == ['capabilities', '--json']:
    paths = [
        ['stage','create'], ['stage','list'], ['stage','show'], ['stage','refresh'],
        ['stage','discard'], ['stage','submit'], ['workspace','init'], ['workspace','show'],
    ]
    print(json.dumps({'commands':[{'path':path,'availability':'available','options':[]} for path in paths]}))
else:
    print('margin stage refresh creates a new immutable stage; margin transact base cursor; margin workspace workspace init')
""",
                encoding="utf-8",
            )
            binary.chmod(0o755)
            probe = probe_capabilities(binary)
        self.assertTrue(probe["capabilities"]["stage_refresh"]["available"])
        self.assertTrue(probe["capabilities"]["staged_transactions"]["available"])

    def test_model_free_real_cli_suite_has_no_runnable_failures(self) -> None:
        binary = find_margin_binary(None)
        if binary is None:
            self.skipTest("Margin CLI is not built")
        scenarios = load_suite()
        probe = probe_capabilities(binary)
        results = run_protocol_suite(scenarios, binary, probe, b"integration-holdout-key-value!!"[:32])
        self.assertFalse([item for item in results if item["status"] in {"failed", "error"}])
        self.assertTrue([item for item in results if item["status"] == "passed"])


class RelayConfigurationTests(unittest.TestCase):
    def test_empty_expected_annotation_values_do_not_create_vacuous_passes(self) -> None:
        self.assertEqual(_expected_annotation_checks(["actual"], ["id"], [], []), {})

    def test_expected_annotation_values_are_scored_only_when_supplied(self) -> None:
        checks = _expected_annotation_checks(
            ["one", "two"],
            ["urn:uuid:abc", "urn:uuid:def"],
            ["one", "missing"],
            ["abc", "def"],
        )
        self.assertFalse(checks["expected_bodies"])
        self.assertTrue(checks["expected_ids"])

    def test_focused_help_is_preloaded_from_only_requested_command_paths(self) -> None:
        task = AgentTask(
            role="author",
            actor_id="urn:margin:test:author",
            actor_name="Author",
            prompt="Do the task.",
            phase=0,
            help_paths=(("stage", "create"), ("handoff", "add")),
        )

        def fake_run(_binary: Path, arguments: list[str], **_kwargs: object) -> CommandResult:
            return CommandResult(
                tuple(arguments),
                0,
                f"HELP FOR {' '.join(arguments[1:])}\n".encode(),
                b"",
                1,
            )

        with patch("relay.run_command", side_effect=fake_run) as invoked:
            reference, metadata = _focused_cli_reference(Path("/tmp/margin"), task)
        self.assertEqual(
            [call.args[1] for call in invoked.call_args_list],
            [["help", "stage", "create"], ["help", "handoff", "add"]],
        )
        self.assertIn("HELP FOR stage create", reference)
        self.assertIn("HELP FOR handoff add", reference)
        self.assertTrue(metadata["focusedHelpComplete"])
        self.assertEqual(metadata["focusedHelpPaths"], [["stage", "create"], ["handoff", "add"]])

    def test_focused_help_has_a_utf8_safe_hard_bound(self) -> None:
        task = AgentTask(
            role="author",
            actor_id="urn:margin:test:author",
            actor_name="Author",
            prompt="Do the task.",
            phase=0,
            help_paths=(("stage", "create"), ("stage", "submit")),
        )
        huge = ("é" * FOCUSED_HELP_MAX_BYTES).encode("utf-8")
        result = CommandResult(("help",), 0, huge, b"", 1)
        with patch("relay.run_command", return_value=result):
            reference, metadata = _focused_cli_reference(Path("/tmp/margin"), task)
        self.assertLessEqual(len(reference.encode("utf-8")), FOCUSED_HELP_MAX_BYTES)
        self.assertEqual(reference.encode("utf-8").decode("utf-8"), reference)
        self.assertFalse(metadata["focusedHelpComplete"])
        self.assertEqual(metadata["focusedHelpPaths"], [])

    def test_task_capability_projection_avoids_redundant_help_calls(self) -> None:
        task = AgentTask(
            role="author",
            actor_id="urn:margin:test:author",
            actor_name="Author",
            prompt="Do the task.",
            phase=0,
            help_paths=(("suggest", "add"), ("suggest", "list")),
            capability_workflow="suggestions",
        )
        projection = json.dumps({
            "commands": [
                {"path": ["suggest", "add"]},
                {"path": ["suggest", "list"]},
            ],
            "projection": {"workflow": "suggestions"},
            "schema": "urn:margin:capabilities-projection:v1",
        }).encode()
        result = CommandResult(("capabilities",), 0, projection, b"", 1)
        with patch("relay.run_command", return_value=result) as invoked:
            reference, metadata = _focused_cli_reference(Path("/tmp/margin"), task)
        self.assertEqual(invoked.call_count, 1)
        self.assertEqual(
            invoked.call_args.args[1],
            ["capabilities", "--json", "--for", "suggestions"],
        )
        self.assertIn('"workflow": "suggestions"', reference)
        self.assertTrue(metadata["taskCapabilityProjection"]["used"])
        self.assertTrue(metadata["focusedHelpComplete"])
        self.assertTrue(metadata["taskDiscoveryComplete"])

    def test_real_pilot_tasks_receive_bounded_complete_workflow_discovery(self) -> None:
        binary = find_margin_binary(None)
        if binary is None:
            self.skipTest("Margin CLI is not built")
        generated_tasks = []
        for scenario_id in ("staged_multifile_atomic", "suggestions_accept_reject"):
            scenario = load_suite([scenario_id])[0]
            generated_tasks.extend(
                generate_case(scenario, b"focused-discovery-holdout-key!"[:32], 0).tasks
            )
        for task in generated_tasks:
            with self.subTest(role=task.role):
                reference, metadata = _focused_cli_reference(binary, task)
                self.assertTrue(reference)
                self.assertLessEqual(len(reference.encode("utf-8")), FOCUSED_HELP_MAX_BYTES)
                self.assertTrue(metadata["taskCapabilityProjection"]["schemaValid"])
                self.assertTrue(metadata["taskCapabilityProjection"]["used"])
                self.assertTrue(metadata["focusedHelpComplete"])
                self.assertTrue(metadata["taskDiscoveryComplete"])

    def test_token_budget_metadata_labels_generated_output_not_total_context(self) -> None:
        metadata = _token_budget_metadata(4, 6000)
        self.assertEqual(metadata["plannedAutonomousTokenCeiling"], 24_000)
        self.assertEqual(metadata["plannedGeneratedOutputTokenCeiling"], 24_000)
        self.assertEqual(
            metadata["autonomousTokenBudgetSemantics"],
            "generated_output_tokens_per_prime_process",
        )

    def test_team_maps_roles_across_multiple_models(self) -> None:
        team = TeamSpec.parse("mixed=openai/model-a,anthropic/model-b")
        self.assertEqual(team.name, "mixed")
        self.assertEqual(team.model_for(0).canonical, "openai/model-a")
        self.assertEqual(team.model_for(1).canonical, "anthropic/model-b")
        self.assertEqual(team.model_for(2).canonical, "openai/model-a")

    def test_invalid_team_is_rejected(self) -> None:
        with self.assertRaises(EvalError):
            TeamSpec.parse("missing-model")

    def test_trusted_agent_command_exposes_exactly_one_explicit_tool(self) -> None:
        scenario = load_suite(["human_agent_relay"])[0]
        task = generate_case(scenario, b"command-contract-holdout-key!!"[:32], 0).tasks[0]
        command = _agent_command(
            "prime-agent",
            ModelSpec("openai", "example"),
            Path("/tmp/fixed-margin-workspace"),
            task,
            token_budget=1000,
            timeout_seconds=30,
            max_turns=2,
            thinking="low",
            tool_mode="trusted",
        )
        self.assertIn("--no-builtin-tools", command)
        for disabled in (
            "--no-context-files",
            "--no-extensions",
            "--no-prompt-templates",
            "--no-skills",
            "--no-themes",
        ):
            self.assertIn(disabled, command)
        self.assertEqual(command.count("--extension"), 1)
        self.assertEqual(command[command.index("--extension") + 1], str(TRUSTED_EXTENSION_PATH))
        self.assertEqual(command.count("--tools"), 1)
        self.assertEqual(command[command.index("--tools") + 1], "margin_cli")

    def test_trusted_extension_has_one_fixed_spawn_tool_surface(self) -> None:
        source = TRUSTED_EXTENSION_PATH.read_text(encoding="utf-8")
        self.assertEqual(source.count("pi.registerTool({"), 1)
        self.assertIn('name: "margin_cli"', source)
        self.assertIn("spawn(proxyPath, argv", source)
        self.assertIn("cwd: workspace", source)
        self.assertIn("shell: false", source)

    def test_trusted_extension_loads_in_prime_before_any_model_lookup(self) -> None:
        prime = shutil.which("prime-agent")
        binary = find_margin_binary(None)
        if prime is None or binary is None:
            self.skipTest("Prime Agent or Margin CLI is not available")
        probe = _prime_tool_startup_probe(prime, binary, "trusted")
        self.assertTrue(probe["attempted"])
        self.assertTrue(probe["extensionLoaded"])
        self.assertTrue(probe["stoppedBeforeModel"])
        self.assertTrue(probe["passed"])

    def test_shell_mode_is_explicit_and_loads_no_ambient_resources(self) -> None:
        scenario = load_suite(["human_agent_relay"])[0]
        task = generate_case(scenario, b"shell-contract-holdout-key!!!"[:32], 0).tasks[0]
        command = _agent_command(
            "prime-agent",
            ModelSpec("openai", "example"),
            Path("/tmp/fixed-margin-workspace"),
            task,
            token_budget=1000,
            timeout_seconds=30,
            max_turns=2,
            thinking="low",
            tool_mode="shell",
        )
        self.assertNotIn("--extension", command)
        self.assertNotIn("--no-builtin-tools", command)
        self.assertEqual(command[command.index("--tools") + 1], "bash")
        self.assertIn("--no-extensions", command)
        self.assertIn("--no-skills", command)

    def test_live_relay_orchestration_with_local_fake_agent_retains_no_transcript(self) -> None:
        binary = find_margin_binary(None)
        if binary is None:
            self.skipTest("Margin CLI is not built")
        scenario = load_suite(["human_agent_relay"])[0]
        with tempfile.TemporaryDirectory() as temporary:
            fake = Path(temporary) / "fake-prime-agent"
            fake.write_text(
                """#!/usr/bin/env python3
import json, os, re, subprocess, sys
os.chdir(sys.argv[sys.argv.index('--cwd') + 1])
required = {'--no-builtin-tools','--no-extensions','--no-skills','--no-prompt-templates','--no-themes','--no-context-files'}
if not required.issubset(set(sys.argv)):
    raise SystemExit(4)
if sys.argv[sys.argv.index('--tools') + 1] != 'margin_cli':
    raise SystemExit(5)
if not sys.argv[sys.argv.index('--extension') + 1].endswith('/extensions/margin-cli.ts'):
    raise SystemExit(6)
prompt = sys.argv[sys.argv.index('--') + 1]
match = re.search(r'exactly:\\n(.+)\\nUse mutation id ([0-9a-f-]+)', prompt)
if not match:
    raise SystemExit(3)
body, identifier = match.groups()
listed = subprocess.run(['margin','comments','list','review.md','--status','all'], stdout=subprocess.PIPE, check=True)
state = json.loads(listed.stdout)
root = state['result']['comments'][0]['rootID']
revision = state['revision']
reply = subprocess.run(['margin','comments','reply','review.md',root,'-m',body,'--id',identifier,'--if-revision',str(revision)], stdout=subprocess.PIPE, check=True)
reply_state = json.loads(reply.stdout)
subprocess.run(['margin','comments','resolve','review.md',root,'--if-revision',str(reply_state['revision'])], stdout=subprocess.PIPE, check=True)
print(json.dumps({'type':'message_end','message':{'role':'assistant','usage':{'input':10,'output':4,'cost':{'total':0}}}}))
""",
                encoding="utf-8",
            )
            fake.chmod(0o755)
            result = run_live_case(
                scenario=scenario,
                holdout_key=b"local-fake-agent-holdout-key!!"[:32],
                repetition=0,
                team=TeamSpec("fake", (ModelSpec("local", "fake"),)),
                margin_binary=binary,
                prime_agent=str(fake),
                token_budget=1000,
                timeout_seconds=30,
                max_turns=2,
                thinking="low",
            )
            self.assertEqual(result["score"], 100)
            self.assertTrue(result["safetyPassed"])
            self.assertTrue(result["policyCompliant"])
            self.assertGreater(result["commandCount"], 0)
            self.assertNotIn("Relay [", json.dumps(result))

    def test_paid_execution_is_rejected_without_literal_confirmation(self) -> None:
        binary = find_margin_binary(None)
        if binary is None:
            self.skipTest("Margin CLI is not built")
        completed = subprocess.run(
            [
                sys.executable,
                str(EVAL_DIR / "run.py"),
                "--execute",
                "--margin-bin", str(binary),
                "--model", "local/must-not-run",
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
        )
        self.assertEqual(completed.returncode, 2)
        error = json.loads(completed.stderr)
        self.assertFalse(error["paidModelsInvoked"])

    def test_paid_execution_is_rejected_before_models_when_invocation_cap_is_exceeded(self) -> None:
        binary = find_margin_binary(None)
        if binary is None:
            self.skipTest("Margin CLI is not built")
        with tempfile.TemporaryDirectory() as temporary:
            key = Path(temporary) / "holdout.key"
            key.write_bytes(b"k" * 32)
            key.chmod(0o600)
            completed = subprocess.run(
                [
                    sys.executable,
                    str(EVAL_DIR / "run.py"),
                    "--execute",
                    "--confirm-paid", "RUN_PAID_COLLABORATION_EVALS",
                    "--holdout-key-file", str(key),
                    "--margin-bin", str(binary),
                    "--scenario", "human_agent_relay",
                    "--model", "local/one",
                    "--model", "local/two",
                    "--repetitions", "1",
                    "--max-paid-invocations", "1",
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
                env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
            )
        self.assertEqual(completed.returncode, 2)
        error = json.loads(completed.stderr)
        self.assertFalse(error["paidModelsInvoked"])

    def test_shell_research_requires_a_second_literal_confirmation(self) -> None:
        binary = find_margin_binary(None)
        if binary is None:
            self.skipTest("Margin CLI is not built")
        with tempfile.TemporaryDirectory() as temporary:
            key = Path(temporary) / "holdout.key"
            key.write_bytes(b"k" * 32)
            key.chmod(0o600)
            completed = subprocess.run(
                [
                    sys.executable,
                    str(EVAL_DIR / "run.py"),
                    "--execute",
                    "--confirm-paid", "RUN_PAID_COLLABORATION_EVALS",
                    "--holdout-key-file", str(key),
                    "--margin-bin", str(binary),
                    "--scenario", "human_agent_relay",
                    "--model", "local/must-not-run",
                    "--repetitions", "1",
                    "--tool-mode", "shell",
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
                env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
            )
        self.assertEqual(completed.returncode, 2)
        error = json.loads(completed.stderr)
        self.assertFalse(error["paidModelsInvoked"])


class StatisticsTests(unittest.TestCase):
    @staticmethod
    def payload(scores: list[float], *, safety: bool = True, commitment: str = "same") -> dict:
        return {
            "metadata": {"holdoutCommitment": commitment, "suiteSha256": "suite"},
            "runs": [{
                "caseFingerprint": f"case-{index}",
                "commandCount": 10,
                "configuration": "team",
                "durationSeconds": 2,
                "policyCompliant": safety,
                "repetition": index,
                "safetyPassed": safety,
                "scenario": "relay",
                "score": score,
                "usage": {"cost": 0.1, "input": 10, "output": 5},
            } for index, score in enumerate(scores)],
        }

    def test_bootstrap_interval_is_deterministic_and_contains_mean(self) -> None:
        first = mean_confidence_interval([1, 2, 3, 4], seed_material="fixed")
        second = mean_confidence_interval([1, 2, 3, 4], seed_material="fixed")
        self.assertEqual(first, second)
        self.assertLessEqual(first["low"], first["mean"])
        self.assertGreaterEqual(first["high"], first["mean"])

    def test_paired_comparison_reports_positive_delta_with_interval(self) -> None:
        baseline = self.payload([70, 72, 74, 76, 78])
        candidate = self.payload([75, 77, 79, 81, 83])
        result = compare(baseline, candidate)
        self.assertTrue(result["passed"])
        self.assertEqual(result["matchedPairs"], 5)
        self.assertEqual(result["overallPairedDelta"]["score"]["mean"], 5)
        self.assertEqual(result["decision"], "pass")

    def test_paired_comparison_rejects_new_safety_failure(self) -> None:
        baseline = self.payload([90, 90])
        candidate = self.payload([90, 90], safety=False)
        result = compare(baseline, candidate)
        self.assertFalse(result["passed"])
        self.assertIn("new_safety_failure", {item["reason"] for item in result["regressions"]})

    def test_paired_comparison_requires_same_hidden_holdout(self) -> None:
        with self.assertRaises(EvalError):
            compare(self.payload([90], commitment="a"), self.payload([90], commitment="b"))

    def test_paired_comparison_requires_same_tool_isolation(self) -> None:
        baseline = self.payload([90])
        candidate = self.payload([90])
        baseline["metadata"]["toolIsolation"] = {"mode": "trusted", "modelToolAllowlist": ["margin_cli"]}
        candidate["metadata"]["toolIsolation"] = {"mode": "shell", "modelToolAllowlist": ["bash"]}
        with self.assertRaises(EvalError):
            compare(baseline, candidate)

    def test_report_contains_only_aggregates(self) -> None:
        payload = self.payload([80, 90])
        payload["metadata"].update(_token_budget_metadata(4, 6000))
        payload["aggregate"] = aggregate(payload)
        markdown = render(payload)
        self.assertIn("Mean score", markdown)
        self.assertIn("Planned generated/output-token ceiling: `24000`", markdown)
        self.assertIn("Actual input / generated output tokens: `20` / `10`", markdown)
        self.assertIn("Actual cache read / write tokens: `0` / `0`", markdown)
        self.assertNotIn("case-0", markdown)


if __name__ == "__main__":
    unittest.main()
