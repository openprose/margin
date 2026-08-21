from __future__ import annotations

import argparse
import importlib.util
import sys
import unittest
from pathlib import Path


def repository_runner_path() -> Path | None:
    """Find the repository-only runner without assuming a checkout depth."""
    for parent in Path(__file__).resolve().parents:
        candidate = parent / "Scripts" / "run-linux-xctest.py"
        if candidate.is_file():
            return candidate
    return None


RUNNER_PATH = repository_runner_path()
if RUNNER_PATH is None:
    # The published source archive intentionally contains MarginBench, not the
    # repository's Swift test harness. Its archive verification may therefore
    # discover this test file without having the runner available to exercise.
    RUNNER = None
else:
    SPEC = importlib.util.spec_from_file_location("margin_linux_xctest_runner", RUNNER_PATH)
    if SPEC is None or SPEC.loader is None:  # pragma: no cover - import machinery guard
        raise RuntimeError("Could not load the Linux XCTest runner.")
    RUNNER = importlib.util.module_from_spec(SPEC)
    sys.modules[SPEC.name] = RUNNER
    SPEC.loader.exec_module(RUNNER)


KNOWN_FRAMEWORK_STACK = """
* thread #1
  * frame #0: libc.so.6`ppoll
    frame #1: libFoundation.so`__CFRunLoopServiceFileDescriptors
    frame #2: libFoundation.so`__CFRunLoopRun
    frame #3: libXCTest.so`XCTest.awaitUsingExpectation
    frame #4: libXCTest.so`XCTest.XCTestCase.performTearDownSequence
    frame #5: libXCTest.so`XCTest.XCTestCase.invokeTest
    frame #6: MarginPackageTests.xctest`static Runner.main
  thread #2
"""


@unittest.skipIf(RUNNER is None, "requires the repository's Linux XCTest runner")
class LinuxXCTestRunnerTests(unittest.TestCase):
    def test_accepts_only_the_known_framework_teardown_stack(self) -> None:
        self.assertTrue(RUNNER.is_framework_teardown_deadlock(KNOWN_FRAMEWORK_STACK))
        lldb_with_stop_summary = (
            "thread #2, stop reason = signal SIGSTOP\n"
            "(lldb) thread backtrace all\n"
            + KNOWN_FRAMEWORK_STACK
        )
        self.assertTrue(
            RUNNER.is_framework_teardown_deadlock(lldb_with_stop_summary)
        )
        self.assertFalse(
            RUNNER.is_framework_teardown_deadlock(
                KNOWN_FRAMEWORK_STACK.replace("performTearDownSequence", "setUpSequence")
            )
        )

    def test_rejects_a_product_frame_above_xctest_invoke(self) -> None:
        product_stack = KNOWN_FRAMEWORK_STACK.replace(
            "    frame #4: libXCTest.so`XCTest.XCTestCase.performTearDownSequence",
            "    frame #4: MarginCore`CollaborationService.wait\n"
            "    frame #5: libXCTest.so`XCTest.XCTestCase.performTearDownSequence",
        )
        self.assertFalse(RUNNER.is_framework_teardown_deadlock(product_stack))

    def test_rejects_product_work_on_another_thread(self) -> None:
        product_stack = KNOWN_FRAMEWORK_STACK + """
  thread #3
    frame #0: MarginCLI`CollaborationCLI.run
    frame #1: libdispatch.so`_dispatch_worker_thread
"""
        self.assertFalse(RUNNER.is_framework_teardown_deadlock(product_stack))

    def test_diagnostic_output_is_hard_bounded(self) -> None:
        payload = b"x" * (RUNNER.MAX_DIAGNOSTIC_BYTES + 123)
        bounded = RUNNER.bounded(payload)
        self.assertLess(len(bounded), len(payload))
        self.assertIn(b"omitted 123 diagnostic bytes", bounded)

    def test_retry_budget_is_bounded(self) -> None:
        self.assertEqual(RUNNER.bounded_retries("0"), 0)
        self.assertEqual(RUNNER.bounded_retries("5"), 5)
        with self.assertRaises(argparse.ArgumentTypeError):
            RUNNER.bounded_retries("6")


if __name__ == "__main__":
    unittest.main()
