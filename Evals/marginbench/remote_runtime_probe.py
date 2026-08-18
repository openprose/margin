#!/usr/bin/env python3
"""Budget-gated, no-model verification of a Prime-managed Linux runtime."""

from __future__ import annotations

import argparse
import asyncio
import hashlib
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path
from typing import Any


CONFIRMATION = "RUN_PAID_MARGINBENCH_SANDBOX"
HARD_MAX_COST_USD = 1.0
PRIME_BACKEND_MAX_HOURS = 24.0


def canonical(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True)


def sandbox_cost_bound(
    *,
    cpu: float,
    memory_gb: float,
    disk_gb: float,
    cpu_usd_per_core_hour: float,
    memory_usd_per_gb_hour: float,
    disk_usd_per_gb_hour: float,
) -> float:
    """Worst case if cleanup and the idle timer both fail until Prime's 24h cap."""
    hourly = (
        cpu * cpu_usd_per_core_hour
        + memory_gb * memory_usd_per_gb_hour
        + disk_gb * disk_usd_per_gb_hour
    )
    return round(hourly * PRIME_BACKEND_MAX_HOURS, 6)


def expected_probe_cost(
    *,
    cpu: float,
    memory_gb: float,
    disk_gb: float,
    expected_minutes: float,
    cpu_usd_per_core_hour: float,
    memory_usd_per_gb_hour: float,
    disk_usd_per_gb_hour: float,
) -> float:
    hourly = (
        cpu * cpu_usd_per_core_hour
        + memory_gb * memory_usd_per_gb_hour
        + disk_gb * disk_usd_per_gb_hour
    )
    return round(hourly * expected_minutes / 60, 6)


def wallet(prime: Path) -> dict[str, Any]:
    completed = subprocess.run(
        [str(prime), "--plain", "wallet", "--limit", "5", "--output", "json"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=True,
        timeout=30,
    )
    payload = json.loads(completed.stdout)
    return {
        "balanceUSD": float(payload["balance_usd"]),
        "totalBillings": int(payload["total_billings"]),
    }


async def execute_probe(arguments: argparse.Namespace) -> dict[str, Any]:
    import verifiers.v1 as vf
    from verifiers.v1.runtimes import provision_runtime

    config = vf.PrimeConfig(
        image=arguments.image,
        vm=False,
        cpu=arguments.cpu,
        memory=arguments.memory_gb,
        disk=arguments.disk_gb,
        idle_timeout=arguments.idle_timeout_seconds,
        labels=["marginbench", "no-model-runtime-probe"],
    )
    started = time.perf_counter()
    async with provision_runtime(config, name="marginbench-no-model-probe") as runtime:
        await runtime.write("margin", arguments.margin_bin.read_bytes())
        await runtime.write("review.md", b"# Remote runtime probe\n")
        prepared = await runtime.run(["chmod", "0755", "margin"], {})
        if prepared.exit_code != 0:
            raise RuntimeError(f"remote chmod failed: {prepared.stderr[-500:]}")
        version = await runtime.run(["./margin", "version"], {})
        if version.exit_code != 0:
            raise RuntimeError(f"remote Margin launch failed: {version.stderr[-500:]}")
        added = await runtime.run([
            "./margin", "comments", "add", "review.md", "-m",
            "Prime-managed runtime is executable.", "--document", "--kind", "issue",
            "--id", "00000000-0000-4000-8000-0000000000aa",
            "--actor-id", "urn:marginbench:probe", "--actor-name", "MarginBench probe",
            "--actor-type", "software",
        ], {})
        if added.exit_code != 0:
            raise RuntimeError(f"remote comment mutation failed: {added.stderr[-500:]}")
        validated = await runtime.run(["./margin", "comments", "validate", "review.md"], {})
        if validated.exit_code != 0:
            raise RuntimeError(f"remote document validation failed: {validated.stderr[-500:]}")
        inspection = json.loads(validated.stdout)
        result = inspection.get("result") if isinstance(inspection, dict) else None
        return {
            "runtimeType": runtime.info.type,
            "imageCached": getattr(runtime.info, "image_cached", None),
            "marginVersion": version.stdout.strip(),
            "documentValid": bool(isinstance(result, dict) and result.get("valid")),
            "durationMs": round((time.perf_counter() - started) * 1000),
        }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--margin-bin", type=Path, required=True)
    parser.add_argument("--image", default="python:3.11-slim")
    parser.add_argument("--cpu", type=float, default=0.1)
    parser.add_argument("--memory-gb", type=float, default=0.1)
    parser.add_argument("--disk-gb", type=float, default=0.1)
    parser.add_argument("--idle-timeout-seconds", type=float, default=60.0)
    parser.add_argument("--expected-minutes", type=float, default=2.0)
    parser.add_argument("--cpu-usd-per-core-hour", type=float, default=0.05)
    parser.add_argument("--memory-usd-per-gb-hour", type=float, default=0.01)
    parser.add_argument("--disk-usd-per-gb-hour", type=float, default=0.001)
    parser.add_argument("--max-cost-usd", type=float, default=0.15)
    parser.add_argument("--execute", action="store_true", help="Create the paid sandbox.")
    parser.add_argument(
        "--confirm-paid",
        default="",
        help=f"Paid execution requires the literal token {CONFIRMATION}.",
    )
    arguments = parser.parse_args()

    arguments.margin_bin = arguments.margin_bin.expanduser().resolve()
    if not arguments.margin_bin.is_file() or not os.access(arguments.margin_bin, os.X_OK):
        raise SystemExit("A current executable Linux Margin artifact is required.")
    positive = [
        arguments.cpu, arguments.memory_gb, arguments.disk_gb,
        arguments.idle_timeout_seconds, arguments.expected_minutes,
    ]
    prices = [
        arguments.cpu_usd_per_core_hour,
        arguments.memory_usd_per_gb_hour,
        arguments.disk_usd_per_gb_hour,
    ]
    if any(value <= 0 for value in positive) or any(value < 0 for value in prices):
        raise SystemExit("Runtime resources and durations must be positive; prices cannot be negative.")
    if not (0 < arguments.max_cost_usd <= HARD_MAX_COST_USD):
        raise SystemExit(f"max-cost-usd must be above zero and at most {HARD_MAX_COST_USD}")

    bound = sandbox_cost_bound(
        cpu=arguments.cpu,
        memory_gb=arguments.memory_gb,
        disk_gb=arguments.disk_gb,
        cpu_usd_per_core_hour=arguments.cpu_usd_per_core_hour,
        memory_usd_per_gb_hour=arguments.memory_usd_per_gb_hour,
        disk_usd_per_gb_hour=arguments.disk_usd_per_gb_hour,
    )
    expected = expected_probe_cost(
        cpu=arguments.cpu,
        memory_gb=arguments.memory_gb,
        disk_gb=arguments.disk_gb,
        expected_minutes=arguments.expected_minutes,
        cpu_usd_per_core_hour=arguments.cpu_usd_per_core_hour,
        memory_usd_per_gb_hour=arguments.memory_usd_per_gb_hour,
        disk_usd_per_gb_hour=arguments.disk_usd_per_gb_hour,
    )
    if bound > arguments.max_cost_usd:
        raise SystemExit(
            f"24-hour failure bound ${bound:.6f} exceeds the ${arguments.max_cost_usd:.6f} cap"
        )
    public_basis = {
        "paidModelsInvoked": False,
        "image": arguments.image,
        "resources": {
            "cpu": arguments.cpu,
            "memoryGB": arguments.memory_gb,
            "diskGB": arguments.disk_gb,
            "idleTimeoutSeconds": arguments.idle_timeout_seconds,
        },
        "pricingUSDPerHour": {
            "cpuPerCore": arguments.cpu_usd_per_core_hour,
            "memoryPerGB": arguments.memory_usd_per_gb_hour,
            "diskPerGB": arguments.disk_usd_per_gb_hour,
        },
        "expectedCostUSD": expected,
        "failureBoundUSD": bound,
        "failureBoundHours": PRIME_BACKEND_MAX_HOURS,
        "hardAdmissionCapUSD": arguments.max_cost_usd,
        "marginSha256": hashlib.sha256(arguments.margin_bin.read_bytes()).hexdigest(),
    }
    plan = {
        "schema": "urn:marginbench:prime-runtime-probe-plan:v1",
        "execute": arguments.execute,
        **public_basis,
    }
    if not arguments.execute:
        print(canonical(plan))
        return 0
    if arguments.confirm_paid != CONFIRMATION:
        raise SystemExit(f"paid execution requires --confirm-paid {CONFIRMATION}")
    prime_name = shutil.which("prime")
    if prime_name is None:
        raise SystemExit("Prime CLI is not installed.")
    prime = Path(prime_name).resolve()
    before = wallet(prime)
    try:
        outcome = asyncio.run(execute_probe(arguments))
        status = "completed"
        error = None
    except Exception as caught:  # noqa: BLE001 - emit a bounded infrastructure result.
        outcome = None
        status = "infrastructure-error"
        error = {"type": type(caught).__name__, "message": str(caught)[:1000]}
    after = wallet(prime)
    result = {
        "schema": "urn:marginbench:prime-runtime-probe:v1",
        **public_basis,
        "status": status,
        "wallet": {
            "beforeBalanceUSD": before["balanceUSD"],
            "afterBalanceUSD": after["balanceUSD"],
            "observedDebitUSD": round(before["balanceUSD"] - after["balanceUSD"], 6),
        },
        "result": outcome,
        "error": error,
    }
    print(canonical(result))
    return 0 if status == "completed" else 75


if __name__ == "__main__":
    sys.dont_write_bytecode = True
    raise SystemExit(main())
