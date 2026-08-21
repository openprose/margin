#!/usr/bin/env python3
"""Run one Linux XCTest method and classify the known corelibs teardown deadlock."""

from __future__ import annotations

import argparse
import os
import signal
import subprocess
import sys
from dataclasses import dataclass


RECOVERY_MARKER = "MARGIN_XCTEST_FRAMEWORK_TEARDOWN_DEADLOCK_RECOVERED"
MAX_DIAGNOSTIC_BYTES = 256 * 1024


@dataclass(frozen=True)
class Attempt:
    returncode: int
    output: bytes
    stack: str | None = None
    framework_teardown_deadlock: bool = False


def is_framework_teardown_deadlock(stack: str) -> bool:
    """Accept only the exact open swift-corelibs-xctest #504 stack shape."""
    backtrace = stack.split("(lldb) thread backtrace all", 1)[-1]
    main_thread = backtrace.split("thread #2", 1)[0]
    required = (
        "libc.so.6`ppoll",
        "libFoundation.so`__CFRunLoop",
        "libXCTest.so`XCTest.awaitUsingExpectation",
        "libXCTest.so`XCTest.XCTestCase.performTearDownSequence",
        "libXCTest.so`XCTest.XCTestCase.invokeTest",
    )
    if not all(symbol in main_thread for symbol in required):
        return False

    # A Margin frame above XCTest's invokeTest would indicate product code is
    # still executing. Runner/XCTMain frames below invokeTest are expected.
    active_frames = main_thread.split("libXCTest.so`XCTest.XCTestCase.invokeTest", 1)[0]
    if "MarginCore" in active_frames or "MarginCLI" in active_frames:
        return False

    # Also fail closed when product code is still active on another thread.
    # Test modules such as MarginCoreTests may appear below invokeTest, so use
    # module-boundary markers instead of a broad substring search.
    product_markers = (
        "MarginCore`",
        "MarginCore.",
        "MarginCLI`",
        "MarginCLI.",
    )
    return not any(marker in backtrace for marker in product_markers)


def bounded(data: bytes) -> bytes:
    if len(data) <= MAX_DIAGNOSTIC_BYTES:
        return data
    omitted = len(data) - MAX_DIAGNOSTIC_BYTES
    return (
        data[:MAX_DIAGNOSTIC_BYTES]
        + f"\n[Margin Linux test runner omitted {omitted} diagnostic bytes]\n".encode()
    )


def capture_stack(pid: int) -> str:
    command = [
        "lldb",
        "-b",
        "-p",
        str(pid),
        "-o",
        "thread backtrace all",
        "-o",
        "detach",
        "-o",
        "quit",
    ]
    try:
        completed = subprocess.run(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
            timeout=20,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        return f"Margin Linux test runner could not capture LLDB stack: {error}\n"
    return bounded(completed.stdout).decode("utf-8", errors="replace")


def stop_process_group(pid: int, requested_signal: signal.Signals) -> None:
    try:
        os.killpg(pid, requested_signal)
    except ProcessLookupError:
        pass


def run_attempt(test_binary: str, selector: str, timeout_seconds: float) -> Attempt:
    process = subprocess.Popen(
        [test_binary, selector],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    try:
        output, _ = process.communicate(timeout=timeout_seconds)
        return Attempt(process.returncode, bounded(output))
    except subprocess.TimeoutExpired:
        stop_process_group(process.pid, signal.SIGSTOP)
        stack = capture_stack(process.pid)
        stop_process_group(process.pid, signal.SIGKILL)
        try:
            tail, _ = process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            tail = b""
        # A second communicate() returns the complete buffered stream, including
        # bytes already attached to TimeoutExpired. Do not duplicate that prefix.
        output = bounded(tail)
        classified = is_framework_teardown_deadlock(stack)
        return Attempt(124, output, stack, classified)


def bounded_retries(value: str) -> int:
    parsed = int(value)
    if parsed < 0 or parsed > 5:
        raise argparse.ArgumentTypeError("must be between zero and five")
    return parsed


def positive_timeout(value: str) -> float:
    parsed = float(value)
    if parsed <= 0 or parsed > 600:
        raise argparse.ArgumentTypeError("must be greater than zero and at most 600")
    return parsed


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--test-binary", required=True)
    parser.add_argument("--selector", required=True)
    parser.add_argument("--timeout", type=positive_timeout, required=True)
    parser.add_argument("--framework-retries", type=bounded_retries, default=2)
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    if not os.path.isfile(arguments.test_binary) or not os.access(
        arguments.test_binary, os.X_OK
    ):
        print("Linux XCTest binary is unavailable or not executable.", file=sys.stderr)
        return 66

    recovered = 0
    for attempt_number in range(arguments.framework_retries + 1):
        attempt = run_attempt(
            arguments.test_binary,
            arguments.selector,
            arguments.timeout,
        )
        sys.stdout.buffer.write(attempt.output)
        sys.stdout.buffer.flush()
        if attempt.returncode == 0:
            if recovered:
                print(f"{RECOVERY_MARKER}={recovered}", file=sys.stderr)
            return 0
        if attempt.returncode != 124:
            return attempt.returncode
        if not attempt.framework_teardown_deadlock:
            print(
                "Linux XCTest timed out outside the recognized framework "
                "teardown path.",
                file=sys.stderr,
            )
            if attempt.stack:
                print(attempt.stack, file=sys.stderr)
            return 124
        recovered += 1
        print(
            "Linux XCTest framework teardown deadlock confirmed by live stack; "
            f"retrying {arguments.selector} "
            f"({attempt_number + 1}/{arguments.framework_retries}).",
            file=sys.stderr,
        )

    print(
        "Linux XCTest repeatedly deadlocked in framework teardown; "
        "retry budget exhausted.",
        file=sys.stderr,
    )
    return 124


if __name__ == "__main__":
    raise SystemExit(main())
