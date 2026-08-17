#!/usr/bin/env python3
"""Shared primitives for Margin's dynamic collaboration evaluations.

The module deliberately uses only the Python standard library.  It never reads
credentials and never persists prompts, Markdown bodies, comment bodies, raw
tool output, or model transcripts.
"""

from __future__ import annotations

import hashlib
import hmac
import json
import math
import os
import re
import shutil
import statistics
import subprocess
import tempfile
import time
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable, Mapping, Sequence


EVAL_DIR = Path(__file__).resolve().parent
REPO_ROOT = EVAL_DIR.parents[1]
SUITE_PATH = EVAL_DIR / "suite.json"
CAPABILITIES_PATH = EVAL_DIR / "capabilities.json"
PAID_CONFIRMATION = "RUN_PAID_COLLABORATION_EVALS"
HELP_WARMUP_COUNT = 3
HELP_WARM_SAMPLE_COUNT = 20
HELP_WARM_P95_BUDGET_MS = 100.0
SENSITIVE_OPTIONS = frozenset({
    "-m", "--message", "--body", "--message-file", "--stdin", "--quote",
    "--prefix", "--suffix", "--expect", "--replacement", "--prompt",
    "--actor-id", "--actor-name", "--id", "--request-id", "--stage-id",
})
VALUELESS_OPTIONS = frozenset({
    "--apply", "--document", "--force", "--json", "--jsonl", "--pretty",
    "--reopen", "--stdin", "--subtree", "--wait", "--unambiguous-only",
})


class EvalError(RuntimeError):
    pass


@dataclass(frozen=True)
class Scenario:
    id: str
    agents: int
    execution: str
    required_capabilities: tuple[str, ...]
    optional_capabilities: tuple[str, ...]
    oracles: tuple[str, ...]
    weight: float


@dataclass(frozen=True)
class CommandResult:
    argv: tuple[str, ...]
    exit_code: int
    stdout: bytes
    stderr: bytes
    duration_ms: float

    @property
    def json(self) -> Any:
        try:
            return json.loads(self.stdout.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            return None

    @property
    def error_code(self) -> str | None:
        for payload in (self.stderr, self.stdout):
            try:
                value = json.loads(payload.decode("utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError):
                continue
            if isinstance(value, dict):
                error = value.get("error")
                if isinstance(error, dict) and isinstance(error.get("code"), str):
                    return error["code"]
                if isinstance(value.get("code"), str):
                    return value["code"]
        return None


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def canonical_json(value: Any) -> bytes:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True).encode("utf-8")


def sha256_bytes(value: bytes) -> str:
    return "sha256:" + hashlib.sha256(value).hexdigest()


def sha256_text(value: str) -> str:
    return sha256_bytes(value.encode("utf-8"))


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return "sha256:" + digest.hexdigest()


def load_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise EvalError(f"Could not load {path}: {error}") from error


def _string_tuple(value: Any, field: str, scenario_id: str) -> tuple[str, ...]:
    if value is None:
        return ()
    if not isinstance(value, list) or any(not isinstance(item, str) or not item for item in value):
        raise EvalError(f"Scenario {scenario_id} has invalid {field}.")
    return tuple(value)


def load_suite(requested: Iterable[str] = ()) -> list[Scenario]:
    payload = load_json(SUITE_PATH)
    if not isinstance(payload, dict) or payload.get("schema") != "urn:margin:collaboration-eval-suite:v1":
        raise EvalError("Collaboration suite has an unsupported schema.")
    capability_payload = load_json(CAPABILITIES_PATH)
    known_capabilities = set(capability_payload.get("capabilities", {}))
    contract_oracles = set(payload.get("contractOracles", []))
    requested_set = set(requested)
    result: list[Scenario] = []
    seen: set[str] = set()
    for raw in payload.get("scenarios", []):
        if not isinstance(raw, dict) or not isinstance(raw.get("id"), str):
            raise EvalError("Every collaboration scenario requires an id.")
        scenario_id = raw["id"]
        if scenario_id in seen:
            raise EvalError(f"Duplicate collaboration scenario {scenario_id}.")
        seen.add(scenario_id)
        if requested_set and scenario_id not in requested_set:
            continue
        required = _string_tuple(raw.get("requiredCapabilities"), "requiredCapabilities", scenario_id)
        optional = _string_tuple(raw.get("optionalCapabilities"), "optionalCapabilities", scenario_id)
        unknown = (set(required) | set(optional)) - known_capabilities
        if unknown:
            raise EvalError(f"Scenario {scenario_id} references unknown capabilities: {sorted(unknown)}")
        oracles = _string_tuple(raw.get("oracles"), "oracles", scenario_id)
        unknown_oracles = set(oracles) - contract_oracles
        if unknown_oracles:
            raise EvalError(f"Scenario {scenario_id} references unknown contract oracles: {sorted(unknown_oracles)}")
        agents = raw.get("agents")
        weight = raw.get("weight")
        execution = raw.get("execution")
        if not isinstance(agents, int) or agents < 1 or agents > 4:
            raise EvalError(f"Scenario {scenario_id} has invalid agent count.")
        if not isinstance(weight, (int, float)) or float(weight) <= 0:
            raise EvalError(f"Scenario {scenario_id} has invalid weight.")
        if not isinstance(execution, str) or not execution:
            raise EvalError(f"Scenario {scenario_id} has invalid execution mode.")
        result.append(Scenario(
            id=scenario_id,
            agents=agents,
            execution=execution,
            required_capabilities=required,
            optional_capabilities=optional,
            oracles=oracles,
            weight=float(weight),
        ))
    missing = requested_set - seen
    if missing:
        raise EvalError(f"Unknown collaboration scenarios: {', '.join(sorted(missing))}")
    if not result:
        raise EvalError("No collaboration scenarios selected.")
    return result


def suite_fingerprint() -> str:
    return sha256_bytes(canonical_json({
        "capabilities": load_json(CAPABILITIES_PATH),
        "suite": load_json(SUITE_PATH),
    }))


def find_margin_binary(explicit: Path | None) -> Path | None:
    candidates: list[Path] = []
    if explicit is not None:
        candidates.append(explicit.expanduser())
    environment = os.environ.get("MARGIN_BIN")
    if environment:
        candidates.append(Path(environment).expanduser())
    candidates.extend([
        REPO_ROOT / "build" / "margin",
        REPO_ROOT / ".build" / "debug" / "margin-cli",
        REPO_ROOT / ".build" / "release" / "margin-cli",
    ])
    located = shutil.which("margin")
    if located:
        candidates.append(Path(located))
    for candidate in candidates:
        resolved = candidate.resolve()
        if resolved.is_file() and os.access(resolved, os.X_OK):
            return resolved
    return None


def run_command(
    binary: Path,
    arguments: Sequence[str],
    *,
    cwd: Path | None = None,
    environment: Mapping[str, str] | None = None,
    timeout: float = 30,
    stdin: bytes | None = None,
) -> CommandResult:
    env = os.environ.copy()
    if environment:
        env.update(environment)
    started = time.perf_counter()
    completed = subprocess.run(
        [str(binary), *arguments],
        cwd=str(cwd) if cwd else None,
        env=env,
        input=stdin,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=timeout,
        check=False,
    )
    return CommandResult(
        argv=tuple(arguments),
        exit_code=completed.returncode,
        stdout=completed.stdout,
        stderr=completed.stderr,
        duration_ms=(time.perf_counter() - started) * 1000,
    )


def _structured_capability_names(value: Any) -> tuple[set[str], bool]:
    if not isinstance(value, dict):
        return set(), False
    result = value.get("result", value)
    capabilities = result.get("capabilities") if isinstance(result, dict) else None
    if isinstance(capabilities, dict):
        return {str(name) for name, state in capabilities.items() if state is not False}, True
    if isinstance(capabilities, list):
        names: set[str] = set()
        for item in capabilities:
            if isinstance(item, str):
                names.add(item)
            elif isinstance(item, dict) and isinstance(item.get("id"), str) and item.get("available", True):
                names.add(item["id"])
        return names, True
    commands = result.get("commands") if isinstance(result, dict) else None
    if isinstance(commands, list):
        available_paths: set[str] = set()
        for command in commands:
            if not isinstance(command, dict) or command.get("availability") != "available":
                continue
            path = command.get("path")
            if isinstance(path, list) and path and all(isinstance(item, str) for item in path):
                available_paths.add(" ".join(path))
        names: set[str] = set()
        if {"comments add", "comments reply", "comments list"}.issubset(available_paths):
            names.add("comments")
        if "comments reanchor" in available_paths:
            names.add("reanchor")
        if "comments watch" in available_paths:
            names.add("watch")
        if "review" in available_paths:
            names.add("review")
        if "context" in available_paths:
            names.add("bounded_context")
        if "collaborators" in available_paths:
            names.add("collaborator_activity")
        if {"workspace init", "workspace show"}.issubset(available_paths):
            names.add("workspace")
        if {"stage create", "stage list", "stage discard", "stage submit"}.issubset(available_paths):
            names.add("staged_transactions")
        if "stage refresh" in available_paths:
            names.add("stage_refresh")
        if "reconcile" in available_paths:
            names.add("reconcile")
        if "merge" in available_paths:
            names.add("semantic_merge")
        if {"suggest add", "suggest list", "suggest accept", "suggest reject"}.issubset(available_paths):
            names.add("suggestions")
        if {"handoff add", "handoff list"}.issubset(available_paths):
            names.add("typed_contributions")
        mutation_commands = [
            command for command in commands
            if isinstance(command, dict)
            and command.get("availability") == "available"
            and isinstance(command.get("path"), list)
            and command["path"][:1] == ["comments"]
        ]
        option_names = {
            name
            for command in mutation_commands
            for option in command.get("options", [])
            if isinstance(option, dict)
            for name in option.get("names", [])
            if isinstance(name, str)
        }
        if {"--if-revision", "--if-content-sha"}.issubset(option_names):
            names.add("compare_and_swap")
        if "--id" in option_names:
            names.add("idempotency")
        return names, True
    return set(), False


def _percentile(values: list[float], percentile: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    index = max(0, min(len(ordered) - 1, math.ceil(percentile * len(ordered)) - 1))
    return ordered[index]


def _build_help_contract(
    cold: CommandResult,
    warmups: Sequence[CommandResult],
    warm_samples: Sequence[CommandResult],
) -> dict[str, Any]:
    all_samples = [cold, *warmups, *warm_samples]
    all_outputs = [sample.stdout + sample.stderr for sample in all_samples]
    all_hashes = [sha256_bytes(output) for output in all_outputs]
    warm_durations = [sample.duration_ms for sample in warm_samples if sample.exit_code == 0]
    warm_p95 = _percentile(warm_durations, 0.95) if warm_durations else None
    all_succeeded = all(sample.exit_code == 0 for sample in all_samples)
    deterministic = all_succeeded and bool(all_hashes) and len(set(all_hashes)) == 1
    complete_warm_sample = len(warm_durations) == len(warm_samples) == HELP_WARM_SAMPLE_COUNT
    warm_within_budget = (
        complete_warm_sample
        and warm_p95 is not None
        and warm_p95 <= HELP_WARM_P95_BUDGET_MS
    )
    return {
        "byteCount": len(all_outputs[0]) if all_outputs else 0,
        "coldExitCode": cold.exit_code,
        "coldMs": round(cold.duration_ms, 3),
        "coldSha256": all_hashes[0] if all_hashes else None,
        "deterministicAcrossDirectories": deterministic,
        "exitCodes": [sample.exit_code for sample in all_samples],
        "medianMs": round(statistics.median(warm_durations), 3) if warm_durations else None,
        "p95Ms": round(warm_p95, 3) if warm_p95 is not None else None,
        "sha256": all_hashes[0] if deterministic else None,
        "warmMedianMs": round(statistics.median(warm_durations), 3) if warm_durations else None,
        "warmP95BudgetMs": HELP_WARM_P95_BUDGET_MS,
        "warmP95Ms": round(warm_p95, 3) if warm_p95 is not None else None,
        "warmP95WithinBudget": warm_within_budget,
        "warmSampleCount": len(warm_samples),
        "warmupCount": len(warmups),
        "warmupExitCodes": [sample.exit_code for sample in warmups],
    }


def probe_capabilities(binary: Path) -> dict[str, Any]:
    definition = load_json(CAPABILITIES_PATH).get("capabilities", {})
    with tempfile.TemporaryDirectory(prefix="margin-collab-help-a-") as first, tempfile.TemporaryDirectory(
        prefix="margin-collab-help-b-"
    ) as second:
        roots = [Path(first), Path(second)]
        cold_help = run_command(binary, ["--help"], cwd=roots[0], timeout=10)
        help_warmups = [
            run_command(binary, ["--help"], cwd=roots[(index + 1) % 2], timeout=10)
            for index in range(HELP_WARMUP_COUNT)
        ]
        warm_help_samples = [
            run_command(binary, ["--help"], cwd=roots[index % 2], timeout=10)
            for index in range(HELP_WARM_SAMPLE_COUNT)
        ]
    samples = [cold_help, *help_warmups, *warm_help_samples]
    successful_help = [sample for sample in samples if sample.exit_code == 0]
    help_outputs = [sample.stdout + sample.stderr for sample in successful_help]
    main_help = help_outputs[0] if help_outputs else b""
    comments = run_command(binary, ["help", "comments"], timeout=10)
    help_blob = b"\n".join([main_help, comments.stdout, comments.stderr])
    normalized_help = help_blob.decode("utf-8", errors="replace").lower()

    structured_names: set[str] = set()
    structured_authoritative = False
    structured_probe: CommandResult | None = None
    structured_samples: list[CommandResult] = []
    if re.search(r"\bmargin\s+capabilities\b", normalized_help):
        with tempfile.TemporaryDirectory(prefix="margin-collab-cap-a-") as first, tempfile.TemporaryDirectory(
            prefix="margin-collab-cap-b-"
        ) as second:
            roots = [Path(first), Path(second)]
            for index in range(4):
                structured_samples.append(
                    run_command(binary, ["capabilities", "--json"], cwd=roots[index % 2], timeout=10)
                )
        structured_probe = structured_samples[0]
        structured_names, structured_authoritative = _structured_capability_names(structured_probe.json)

    capabilities: dict[str, Any] = {}
    aliases = {
        "context": "bounded_context",
        "collaborators": "collaborator_activity",
        "cas": "compare_and_swap",
        "transactions": "staged_transactions",
        "merge": "semantic_merge",
    }
    structured_names |= {aliases.get(name, name) for name in structured_names}
    for name, spec in definition.items():
        patterns = spec.get("allHelpPatterns", []) if isinstance(spec, dict) else []
        matched = all(str(pattern).lower() in normalized_help for pattern in patterns)
        available = name in structured_names or (matched and not structured_authoritative)
        capabilities[name] = {
            "available": available,
            "evidence": (
                "structured_available" if name in structured_names
                else ("structured_unsupported" if structured_authoritative else ("static_help" if matched else "absent"))
            ),
        }

    structured_hashes = [sha256_bytes(sample.stdout + sample.stderr) for sample in structured_samples]
    structured_durations = [sample.duration_ms for sample in structured_samples if sample.exit_code == 0]
    structured_json = structured_probe.json if structured_probe else None
    declared_bound = None
    if isinstance(structured_json, dict):
        bounds = structured_json.get("bounds")
        if isinstance(bounds, dict) and isinstance(bounds.get("maxEncodedBytes"), int):
            declared_bound = bounds["maxEncodedBytes"]
    structured_contract = {
        "attempted": structured_probe is not None,
        "byteCount": len(structured_probe.stdout) if structured_probe else None,
        "declaredMaxEncodedBytes": declared_bound,
        "deterministicAcrossDirectories": (
            bool(structured_hashes) and len(set(structured_hashes)) == 1
        ) if structured_probe else None,
        "exitCodes": [sample.exit_code for sample in structured_samples],
        "outputSha256": structured_hashes[0] if structured_hashes else None,
        "p95Ms": round(_percentile(structured_durations, 0.95), 3) if structured_durations else None,
        "schema": structured_json.get("schema") if isinstance(structured_json, dict) else None,
        "valid": (
            structured_authoritative
            and all(sample.exit_code == 0 for sample in structured_samples)
            and len(set(structured_hashes)) == 1
            and (declared_bound is None or len(structured_probe.stdout) <= declared_bound)
        ) if structured_probe else None,
        "withinDeclaredBound": (
            len(structured_probe.stdout) <= declared_bound
            if structured_probe and declared_bound is not None else None
        ),
    }
    help_contract = _build_help_contract(cold_help, help_warmups, warm_help_samples)
    help_contract["structuredCapabilityProbe"] = structured_contract
    static_contract_passed = (
        help_contract["deterministicAcrossDirectories"]
        and help_contract["warmP95WithinBudget"]
        and (not structured_contract["attempted"] or structured_contract["valid"] is True)
    )
    return {
        "capabilities": capabilities,
        "helpContract": help_contract,
        "marginBinarySha256": sha256_file(binary),
        "schema": "urn:margin:collaboration-eval-preflight:v1",
        "staticContractPassed": static_contract_passed,
    }


def missing_capabilities(scenario: Scenario, probe: Mapping[str, Any]) -> list[str]:
    states = probe.get("capabilities", {})
    return [
        name for name in scenario.required_capabilities
        if not isinstance(states.get(name), dict) or not states[name].get("available", False)
    ]


def read_holdout_key(path: Path, *, require_private_mode: bool = True) -> bytes:
    try:
        stat = path.stat()
        raw = path.read_bytes().strip()
    except OSError as error:
        raise EvalError(f"Could not read holdout key: {error}") from error
    if require_private_mode and os.name == "posix" and stat.st_mode & 0o077:
        raise EvalError("Holdout key must not be readable by group or other users (use mode 0600).")
    try:
        decoded = bytes.fromhex(raw.decode("ascii"))
        key = decoded if len(decoded) >= 32 else raw
    except (UnicodeDecodeError, ValueError):
        key = raw
    if len(key) < 32:
        raise EvalError("Holdout key must contain at least 32 bytes of entropy.")
    return key


def create_holdout_key(path: Path) -> str:
    path = path.expanduser().resolve()
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    key = os.urandom(32).hex().encode("ascii") + b"\n"
    try:
        os.write(descriptor, key)
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    return sha256_bytes(bytes.fromhex(key.decode("ascii").strip()))


class HoldoutRandom:
    """Counter-mode HMAC generator; deterministic without exposing its key."""

    def __init__(self, key: bytes, label: str):
        self._key = hmac.new(key, label.encode("utf-8"), hashlib.sha256).digest()
        self._counter = 0

    def bytes(self, count: int) -> bytes:
        result = bytearray()
        while len(result) < count:
            block = hmac.new(
                self._key,
                self._counter.to_bytes(8, "big"),
                hashlib.sha256,
            ).digest()
            self._counter += 1
            result.extend(block)
        return bytes(result[:count])

    def integer(self, lower: int, upper: int) -> int:
        if upper < lower:
            raise ValueError("upper must be >= lower")
        width = upper - lower + 1
        return lower + int.from_bytes(self.bytes(8), "big") % width

    def choice(self, values: Sequence[Any]) -> Any:
        if not values:
            raise ValueError("cannot choose from an empty sequence")
        return values[self.integer(0, len(values) - 1)]

    def shuffled(self, values: Sequence[Any]) -> list[Any]:
        result = list(values)
        for index in range(len(result) - 1, 0, -1):
            other = self.integer(0, index)
            result[index], result[other] = result[other], result[index]
        return result

    def uuid(self) -> str:
        raw = bytearray(self.bytes(16))
        raw[6] = (raw[6] & 0x0F) | 0x40
        raw[8] = (raw[8] & 0x3F) | 0x80
        return str(uuid.UUID(bytes=bytes(raw)))


def holdout_commitment(key: bytes) -> str:
    return sha256_bytes(hmac.new(key, b"margin-collaboration-holdout-v1", hashlib.sha256).digest())


def case_fingerprint(key: bytes, scenario_id: str, repetition: int) -> str:
    message = f"case-v1\0{scenario_id}\0{repetition}".encode("utf-8")
    return "hmac-sha256:" + hmac.new(key, message, hashlib.sha256).hexdigest()


def safe_slug(value: str) -> str:
    result = re.sub(r"[^a-zA-Z0-9_.-]+", "-", value).strip("-.").lower()
    return result[:80] or "eval"


def _redacted_value(value: str) -> str:
    return sha256_text(value)


def sanitize_argv(arguments: Sequence[str], workspace: Path | None = None) -> list[str]:
    workspace_path = workspace.resolve() if workspace else None
    result: list[str] = []
    redact_next = False
    for raw in arguments:
        value = str(raw)
        if redact_next and not value.startswith("-"):
            result.append(_redacted_value(value))
            redact_next = False
            continue
        if redact_next:
            redact_next = False
        option, separator, inline = value.partition("=")
        if option.startswith("-") and separator:
            result.append(option if not separator else f"{option}={_redacted_value(inline)}")
            continue
        if option.startswith("-"):
            result.append(option)
            redact_next = option not in VALUELESS_OPTIONS
            continue
        if workspace_path:
            try:
                supplied = Path(value)
                looks_like_path = (
                    supplied.is_absolute()
                    or value in {".", ".."}
                    or "/" in value
                    or value.endswith((".md", ".markdown", ".json", ".jsonl"))
                    or (workspace_path / supplied).exists()
                )
                if looks_like_path:
                    candidate = supplied.resolve() if supplied.is_absolute() else (workspace_path / supplied).resolve()
                    relative_path = candidate.relative_to(workspace_path)
                    relative = str(relative_path)
                    result.append("$WORKSPACE" if relative == "." else "$WORKSPACE/" + relative)
                    continue
            except (OSError, ValueError):
                pass
        if re.fullmatch(r"(?:urn:uuid:)?[0-9a-fA-F]{8}-[0-9a-fA-F-]{27,}", value) or value.startswith("urn:margin:eval:"):
            result.append(_redacted_value(value))
            continue
        result.append(value)
    return result


def append_jsonl(path: Path, value: Mapping[str, Any]) -> None:
    encoded = canonical_json(value) + b"\n"
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    try:
        os.write(descriptor, encoded)
    finally:
        os.close(descriptor)


def command_evidence(result: CommandResult, workspace: Path | None = None) -> dict[str, Any]:
    return {
        "argv": sanitize_argv(result.argv, workspace),
        "durationMs": round(result.duration_ms, 3),
        "errorCode": result.error_code,
        "exitCode": result.exit_code,
        "stderrBytes": len(result.stderr),
        "stderrSha256": sha256_bytes(result.stderr),
        "stdoutBytes": len(result.stdout),
        "stdoutSha256": sha256_bytes(result.stdout),
    }


def write_json_atomic(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    encoded = json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True).encode("utf-8") + b"\n"
    temporary = path.with_name(path.name + f".tmp-{os.getpid()}-{time.time_ns()}")
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        os.write(descriptor, encoded)
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    os.replace(temporary, path)


def assert_no_raw_values(payload: Any, forbidden: Iterable[str]) -> None:
    encoded = canonical_json(payload).decode("utf-8", errors="replace")
    leaked = [value for value in forbidden if value and value in encoded]
    if leaked:
        raise EvalError(f"Privacy invariant failed: {len(leaked)} raw holdout values reached retained output.")


def weighted_score(results: Sequence[Mapping[str, Any]]) -> float | None:
    weighted = 0.0
    possible = 0.0
    for result in results:
        score = result.get("score")
        weight = result.get("weight", 1.0)
        if isinstance(score, (int, float)) and isinstance(weight, (int, float)):
            weighted += float(score) * float(weight)
            possible += float(weight)
    return round(weighted / possible, 3) if possible else None
