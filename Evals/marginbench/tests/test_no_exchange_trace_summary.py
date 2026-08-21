from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from marginbench.entropy import PUBLIC_DEVELOPMENT_KEY
from marginbench.no_exchange import NO_EXCHANGE_PROFILE
from marginbench.scenarios import generate_episode
from prime_pilot import _summarize_no_exchange_traces


class NoExchangeTraceSummaryTests(unittest.TestCase):
    def test_private_responses_and_arguments_reduce_to_counts_only(self) -> None:
        episode = generate_episode("concurrent_review", PUBLIC_DEVELOPMENT_KEY, 0)
        private = "PRIVATE-NO-EXCHANGE-CANARY"
        assessment = {
            "episodeID": episode.public_id,
            "aggregation": "per-role-only-no-overall-score",
            "roles": [
                {
                    "seat": role.seat,
                    "phase": role.phase,
                    "expectedFactCount": 1,
                    "submittedFactCount": 1,
                    "checks": {
                        "responseValid": True,
                        "exactIndependentFacts": True,
                        "initialSourceUnchanged": True,
                    },
                    "passed": True,
                }
                for role in episode.roles
            ],
            "passedRoleCount": 2,
            "roleCount": 2,
            "sourcePreserved": True,
            "overallScore": None,
            "durationMs": 25.0,
            "controlProfile": NO_EXCHANGE_PROFILE,
            "controlRunnable": False,
            "component": "integrated-profile-runner-development",
            "separateAgentRolloutCount": 2,
            "toolSurface": ["workspace"],
            "allowedActions": ["guide", "list", "read"],
            "agentProcessCount": 2,
            "traceSeats": ["author", "reviewer"],
            "phasePolicy": "independent-workspaces",
        }
        traces = []
        for role in episode.roles:
            traces.append({
                "task": {"data": {
                    "name": f"{episode.public_id}:{role.seat}",
                    "scenario_id": episode.scenario_id,
                    "repetition": episode.repetition,
                    "fingerprint": episode.fingerprint,
                }},
                "info": {"marginbenchNoExchangeDevelopment": assessment},
                "stop_condition": "agent_completed",
                "nodes": [
                    {"message": {"role": "assistant", "content": private, "tool_calls": [{
                        "id": "call-1", "name": "workspace",
                        "arguments": json.dumps({"action": "read", "path": private}),
                    }]}},
                    {"message": {"role": "tool", "name": "workspace", "content": private}},
                ],
                "calls": [{"usage": {
                    "prompt_tokens": 10, "completion_tokens": 5,
                    "cached_input_tokens": 2, "reasoning_tokens": 1, "cost": 0.001,
                }}],
            })
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "traces.jsonl").write_text(
                json.dumps({"traces": traces}) + "\n", encoding="utf-8",
            )
            summary = _summarize_no_exchange_traces(root)
        encoded = json.dumps(summary)
        self.assertNotIn(private, encoded)
        self.assertTrue(summary["traceConsistencyPassed"])
        self.assertEqual(summary["traceCount"], 2)
        result = summary["episodes"][0]
        self.assertEqual(result["toolRoundTrips"]["count"], 2)
        self.assertEqual(result["toolRoundTrips"]["actionCounts"]["read"], 2)
        self.assertEqual(result["toolRoundTrips"]["blockedActionCount"], 0)
        self.assertEqual(result["usage"]["reportedCostUSD"], 0.002)

    def test_blocked_or_malformed_actions_are_visible_without_arguments(self) -> None:
        episode = generate_episode("parallel_shards", PUBLIC_DEVELOPMENT_KEY, 0)
        assessment = {
            "episodeID": episode.public_id,
            "aggregation": "per-role-only-no-overall-score",
            "roles": [], "passedRoleCount": 0, "roleCount": 2,
            "sourcePreserved": True, "overallScore": None, "durationMs": 1.0,
            "controlProfile": NO_EXCHANGE_PROFILE, "controlRunnable": False,
            "component": "integrated-profile-runner-development",
            "separateAgentRolloutCount": 2, "toolSurface": ["workspace"],
            "allowedActions": ["guide", "list", "read"], "agentProcessCount": 2,
            "traceSeats": ["author", "reviewer"],
            "phasePolicy": "independent-workspaces",
        }
        trace = {
            "task": {"data": {"name": f"{episode.public_id}:author"}},
            "info": {"marginbenchNoExchangeDevelopment": assessment},
            "nodes": [{"message": {"role": "assistant", "tool_calls": [
                {"name": "workspace", "arguments": '{"action":"write"}'},
                {"name": "workspace", "arguments": "not-json"},
            ]}}],
            "calls": [],
        }
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "traces.jsonl").write_text(
                json.dumps({"traces": [trace]}) + "\n", encoding="utf-8",
            )
            result = _summarize_no_exchange_traces(root)["episodes"][0]
        self.assertEqual(result["toolRoundTrips"]["blockedActionCount"], 2)
        self.assertEqual(result["toolRoundTrips"]["actionCounts"]["write"], 1)
        self.assertEqual(result["toolRoundTrips"]["actionCounts"]["invalid"], 1)


if __name__ == "__main__":
    unittest.main()
