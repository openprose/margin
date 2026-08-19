from __future__ import annotations

import copy
import json
import unittest

try:
    import verifiers.v1 as vf
except ImportError:  # Provider-independent tests remain usable without Prime extras.
    vf = None

from marginbench.entropy import PUBLIC_DEVELOPMENT_KEY
from marginbench.plain_fake_model import scripted_plain_response
from marginbench.plain_prompts import plain_role_task
from marginbench.scenarios import generate_episode
from marginbench.schema import canonical_json
from marginbench.validation import validate_bytes


class PlainFakeModelTests(unittest.TestCase):
    def test_next_action_is_reconstructed_from_the_public_conversation_only(self) -> None:
        episode = generate_episode("human_agent_relay", PUBLIC_DEVELOPMENT_KEY, 0)
        prompt = plain_role_task(episode, episode.roles[0]).prompt
        messages = [{"role": "user", "content": prompt}]
        observed_prompt, first = scripted_plain_response(messages)
        self.assertEqual(observed_prompt, prompt)
        self.assertEqual(first, {"action": "guide", "topic": "facts"})

        messages.extend([
            {
                "role": "assistant",
                "content": "transcript-only-canary",
                "tool_calls": [{
                    "id": "call_1",
                    "type": "function",
                    "function": {
                        "name": "workspace",
                        "arguments": json.dumps(first),
                    },
                }],
            },
            {
                "role": "tool",
                "tool_call_id": "call_1",
                "content": json.dumps({
                    "schema": "urn:marginbench:plain-gateway:v1",
                    "ok": True,
                    "action": "guide",
                    "result": {"topic": "facts"},
                }),
            },
        ])
        _, second = scripted_plain_response(messages)
        self.assertEqual(second, {
            "action": "read",
            "path": "COLLABORATION.md",
            "max_lines": 2_000,
        })

        changed = copy.deepcopy(messages)
        changed[1]["tool_calls"][0]["function"]["arguments"] = json.dumps({
            "action": "guide",
            "topic": "suggestions",
        })
        with self.assertRaisesRegex(ValueError, "diverged"):
            scripted_plain_response(changed)


@unittest.skipIf(vf is None, "Verifiers v1 is not installed")
class PlainIsolationPreflightTests(unittest.TestCase):
    def test_real_prime_role_rollouts_echo_only_their_own_canary(self) -> None:
        from marginbench.plain_isolation import run_plain_isolation_preflight

        receipt = run_plain_isolation_preflight(
            scenarios=["agent_agent_handoff"],
            repetitions=1,
        )
        self.assertTrue(receipt["passed"])
        self.assertFalse(receipt["paidModelsInvoked"])
        self.assertEqual(receipt["roleProcessCount"], 2)
        self.assertEqual(receipt["distinctRolePromptCount"], 2)
        self.assertGreater(receipt["ownCanaryEchoCount"], 0)
        self.assertEqual(receipt["ownCanaryMissingCount"], 0)
        self.assertEqual(receipt["crossRoleCanaryLeakCount"], 0)
        self.assertEqual(receipt["malformedRequestCount"], 0)
        self.assertTrue(validate_bytes(canonical_json(receipt))["valid"])

        tampered = copy.deepcopy(receipt)
        tampered["crossRoleCanaryLeakCount"] = 1
        self.assertFalse(validate_bytes(canonical_json(tampered))["valid"])


if __name__ == "__main__":
    unittest.main()
