from __future__ import annotations

import unittest

from remote_runtime_probe import expected_probe_cost, sandbox_cost_bound


class RemoteRuntimeProbeTests(unittest.TestCase):
    def test_expected_and_failure_costs_use_every_resource(self) -> None:
        expected = expected_probe_cost(
            cpu=0.1,
            memory_gb=0.1,
            disk_gb=0.1,
            expected_minutes=2,
            cpu_usd_per_core_hour=0.05,
            memory_usd_per_gb_hour=0.01,
            disk_usd_per_gb_hour=0.001,
        )
        bound = sandbox_cost_bound(
            cpu=0.1,
            memory_gb=0.1,
            disk_gb=0.1,
            cpu_usd_per_core_hour=0.05,
            memory_usd_per_gb_hour=0.01,
            disk_usd_per_gb_hour=0.001,
        )
        self.assertEqual(expected, 0.000203)
        self.assertEqual(bound, 0.1464)
        self.assertGreater(bound, expected)


if __name__ == "__main__":
    unittest.main()
