from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

try:
    import verifiers.v1 as vf  # noqa: F401
except ImportError:
    vf = None

from marginbench.controls import control_profile
from marginbench.entropy import PUBLIC_DEVELOPMENT_KEY
from marginbench.schema import canonical_json
from marginbench.validation import validate_bytes


@unittest.skipIf(vf is None, "Verifiers v1 is not installed")
class NoExchangeIsolationTests(unittest.TestCase):
    def test_tool_surface_is_read_only_and_confined(self) -> None:
        from marginbench.servers.no_exchange_gateway import (
            NoExchangeGatewayConfig,
            NoExchangeGatewayToolset,
        )

        with tempfile.TemporaryDirectory(prefix="marginbench-no-exchange-tool-") as temporary:
            root = Path(temporary)
            workspace = root / "workspace"
            workspace.mkdir()
            (workspace / "review.md").write_text("# Initial\n", encoding="utf-8")
            private = root / "private.md"
            private.write_text("private", encoding="utf-8")
            (workspace / "escape.md").symlink_to(private)
            toolset = NoExchangeGatewayToolset(NoExchangeGatewayConfig(
                workspace=str(workspace),
                state_directory=str(root / "state"),
                actor_id="urn:test:no-exchange",
                actor_name="No Exchange",
            ))

            def call(**arguments):
                return json.loads(toolset.workspace(**arguments))

            self.assertTrue(call(action="guide")["ok"])
            self.assertTrue(call(action="list")["ok"])
            self.assertTrue(call(action="read", path="review.md")["ok"])
            self.assertEqual(call(action="write")["error"]["code"], "READ_ONLY")
            self.assertEqual(
                call(action="read", path="../private.md")["error"]["code"],
                "UNSAFE_PATH",
            )
            self.assertEqual(
                call(action="read", path="escape.md")["error"]["code"],
                "SYMLINK_BLOCKED",
            )

    def test_served_preflight_proves_independent_copies_without_content(self) -> None:
        from marginbench.no_exchange_isolation import run_no_exchange_isolation_preflight
        from marginbench.scenarios import generate_episode

        scenarios = ["parallel_shards", "distributed_synthesis"]
        receipt = run_no_exchange_isolation_preflight(scenarios=scenarios)
        self.assertTrue(receipt["passed"])
        self.assertFalse(receipt["paidModelsInvoked"])
        self.assertFalse(receipt["controlRunnable"])
        self.assertEqual(receipt["assessmentCount"], 2)
        self.assertEqual(receipt["servedSessionCount"], receipt["roleWorkspaceCount"])
        self.assertTrue(all(
            all(assessment["checks"].values())
            for assessment in receipt["assessments"]
        ))
        encoded = canonical_json(receipt).decode("utf-8")
        for scenario in scenarios:
            episode = generate_episode(scenario, PUBLIC_DEVELOPMENT_KEY, 0)
            self.assertNotIn(episode.fingerprint, encoded)
            for path, body in episode.files.items():
                self.assertNotIn(path, encoded)
                self.assertNotIn(body, encoded)
            for role in episode.roles:
                self.assertNotIn(role.actor.id, encoded)
                self.assertNotIn(role.prompt, encoded)
        self.assertTrue(validate_bytes(canonical_json(receipt))["valid"])

    def test_profile_remains_gated_on_integrated_runner(self) -> None:
        profile = control_profile("role-separated-no-exchange-v1")
        self.assertEqual(profile["status"], "specified-not-runnable")
        self.assertEqual(
            [item["id"] for item in profile["blockingGates"]],
            ["integrated-no-exchange-profile-runner"],
        )


if __name__ == "__main__":
    unittest.main()
