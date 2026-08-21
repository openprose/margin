"""Counterbalanced, model-free measurement of wide-directory brief context."""

from __future__ import annotations

import hashlib
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
from pathlib import Path
from typing import Any

from .gateway import MarginGateway, binary_sha256
from .schema import Actor


PROBE_SCHEMA = "urn:marginbench:wide-directory-probe:v1"
PROBE_VERSION = 1
_COMMENT_SENTINEL = b"<!-- margin:comments:v1\n"
_COMMENT_END = b"\n-->"
_FIXED_TIME = "2026-01-01T00:00:00Z"
_RFC3339_UTC = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z$")


@dataclass(frozen=True)
class ProbeLimits:
    files: int = 16
    contributions_per_file: int = 4
    warmups: int = 3
    rounds: int = 20
    timeout_seconds: float = 30.0

    def __post_init__(self) -> None:
        if not 8 <= self.files <= 64:
            raise ValueError("Wide-directory probe files must be between 8 and 64.")
        if not 1 <= self.contributions_per_file <= 8:
            raise ValueError("Wide-directory probe contributions must be between 1 and 8 per file.")
        if not 0 <= self.warmups <= 20:
            raise ValueError("Wide-directory probe warmups must be between 0 and 20.")
        if not 4 <= self.rounds <= 200:
            raise ValueError("Wide-directory probe rounds must be between 4 and 200.")
        if not 1 <= self.timeout_seconds <= 120:
            raise ValueError("Wide-directory probe timeout must be between 1 and 120 seconds.")


@dataclass(frozen=True)
class _Sample:
    duration_ms: float
    stdout_bytes: int
    stdout_sha256: str
    file_count: int
    work_count: int
    guidance_count: int
    truncated: bool
    omitted_file_count: int
    omitted_file_count_is_lower_bound: bool
    response_usable: bool


def _document(index: int) -> str:
    lines = [f"# Wide directory note {index:02d}", ""]
    for section in range(1, 9):
        lines.extend([
            f"## Section {section}",
            "",
            (
                f"Document {index:02d} section {section} records a deterministic collaboration "
                "boundary. Durable source remains unchanged while review state evolves."
            ),
            "",
        ])
    return "\n".join(lines)


def _tree_digest(root: Path) -> str:
    digest = hashlib.sha256()
    for path in sorted(item for item in root.rglob("*") if item.is_file()):
        relative = path.relative_to(root).as_posix().encode("utf-8")
        digest.update(len(relative).to_bytes(4, "big"))
        digest.update(relative)
        body = path.read_bytes()
        digest.update(len(body).to_bytes(8, "big"))
        digest.update(body)
    return digest.hexdigest()


def _normalize_value(value: Any, old_document_id: str, new_document_id: str) -> Any:
    if isinstance(value, str):
        if _RFC3339_UTC.fullmatch(value):
            return _FIXED_TIME
        return value.replace(old_document_id, new_document_id)
    if isinstance(value, list):
        return [_normalize_value(item, old_document_id, new_document_id) for item in value]
    if isinstance(value, dict):
        return {
            key: _normalize_value(item, old_document_id, new_document_id)
            for key, item in value.items()
        }
    return value


def _normalize_embedded_metadata(path: Path, index: int) -> None:
    data = path.read_bytes()
    start = data.rfind(_COMMENT_SENTINEL)
    if start < 0:
        raise RuntimeError("Wide-directory fixture omitted its comment metadata block.")
    payload_start = start + len(_COMMENT_SENTINEL)
    payload_end = data.find(_COMMENT_END, payload_start)
    if payload_end < 0 or data[payload_end + len(_COMMENT_END):].strip():
        raise RuntimeError("Wide-directory fixture comment metadata is not terminal.")
    try:
        envelope = json.loads(data[payload_start:payload_end])
        old_document_id = envelope["margin:document"]["id"]
    except (UnicodeDecodeError, json.JSONDecodeError, KeyError, TypeError) as error:
        raise RuntimeError("Wide-directory fixture comment metadata is malformed.") from error
    new_document_id = "urn:uuid:" + str(uuid.uuid5(
        uuid.NAMESPACE_URL,
        f"urn:marginbench:wide-directory-probe:document:{index}",
    ))
    normalized = _normalize_value(envelope, old_document_id, new_document_id)
    encoded = json.dumps(
        normalized,
        ensure_ascii=False,
        indent=2,
        sort_keys=True,
    ).replace("-", "\\u002d").encode("utf-8")
    path.write_bytes(data[:payload_start] + encoded + data[payload_end:])


def _materialize_fixture(root: Path, binary: Path, limits: ProbeLimits) -> str:
    documents = root / "documents"
    documents.mkdir(parents=True)
    for index in range(1, limits.files + 1):
        (documents / f"note-{index:02d}.md").write_text(
            _document(index),
            encoding="utf-8",
            newline="",
        )
    actor = Actor(
        id="urn:marginbench:wide-directory-probe",
        name="MarginBench wide-directory fixture",
        type="software",
    )
    gateway = MarginGateway(
        binary,
        root,
        actor,
        "fixture",
        state_home=root.parent / ".fixture-state",
    )
    for index in range(1, limits.files + 1):
        path = f"documents/note-{index:02d}.md"
        for contribution in range(1, limits.contributions_per_file + 1):
            identifier = str(uuid.uuid5(
                uuid.NAMESPACE_URL,
                f"urn:marginbench:wide-directory-probe:{index}:{contribution}",
            ))
            response = gateway.call([
                "comments", "add", path,
                "-m", f"Open review item {index:02d}.{contribution}.",
                "--document", "--id", identifier,
            ])
            if response.exit_code != 0:
                raise RuntimeError(
                    "Wide-directory fixture creation failed with "
                    f"{response.error_code or response.exit_code}."
                )
        file = root / path
        _normalize_embedded_metadata(file, index)
        validated = gateway.call(["comments", "validate", path])
        if validated.exit_code != 0:
            raise RuntimeError("Normalized wide-directory fixture metadata is invalid.")
    return _tree_digest(root)


def _controlled_environment(home: Path) -> dict[str, str]:
    home.mkdir(parents=True, exist_ok=True)
    return {
        "HOME": str(home),
        "LANG": os.environ.get("LANG", "C.UTF-8"),
        "LC_ALL": os.environ.get("LC_ALL", "C.UTF-8"),
        "PATH": os.environ.get("PATH", "/usr/local/bin:/usr/bin:/bin"),
        "MARGIN_ACTOR_ID": "urn:marginbench:wide-directory-probe",
        "MARGIN_ACTOR_NAME": "MarginBench wide-directory probe",
        "MARGIN_ACTOR_TYPE": "software",
    }


def _sample(binary: Path, workspace: Path, state_home: Path, timeout: float) -> _Sample:
    started = time.perf_counter_ns()
    completed = subprocess.run(
        [str(binary), "context", ".", "--json", "--brief"],
        cwd=workspace,
        env=_controlled_environment(state_home),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
        timeout=timeout,
    )
    duration_ms = (time.perf_counter_ns() - started) / 1_000_000
    if completed.returncode != 0:
        raise RuntimeError(
            "Wide-directory context failed with exit "
            f"{completed.returncode}; output is intentionally not retained."
        )
    try:
        payload = json.loads(completed.stdout)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise RuntimeError("Wide-directory context did not return UTF-8 JSON.") from error
    result = payload.get("result") if isinstance(payload, dict) else None
    if payload.get("ok") is not True or not isinstance(result, dict):
        raise RuntimeError("Wide-directory context did not return a successful command envelope.")
    files = result.get("files")
    work = result.get("work")
    guidance = result.get("workflowGuidance")
    truncation = result.get("truncation")
    if not all(isinstance(value, list) for value in (files, work, guidance)):
        raise RuntimeError("Wide-directory context omitted a bounded result collection.")
    if not isinstance(truncation, dict):
        raise RuntimeError("Wide-directory context omitted truncation metadata.")
    omitted = truncation.get("omittedFileCount", 0)
    if not isinstance(omitted, int) or isinstance(omitted, bool) or omitted < 0:
        raise RuntimeError("Wide-directory context returned invalid omission metadata.")
    files_usable = bool(files) and all(
        isinstance(item, dict)
        and isinstance(item.get("actionPath"), str)
        and isinstance(item.get("annotationRevision"), int)
        and not isinstance(item.get("annotationRevision"), bool)
        for item in files
    )
    work_usable = bool(work) and all(
        isinstance(item, dict)
        and isinstance(item.get("actionPath"), str)
        and isinstance(item.get("rootID"), str)
        and isinstance(item.get("annotationRevision"), int)
        and not isinstance(item.get("annotationRevision"), bool)
        for item in work
    )
    guidance_usable = bool(guidance) and all(
        isinstance(item, dict)
        and isinstance(item.get("purpose"), str)
        and (
            isinstance(item.get("argv"), list)
            or isinstance(item.get("argvTemplate"), list)
        )
        for item in guidance
    )
    return _Sample(
        duration_ms=duration_ms,
        stdout_bytes=len(completed.stdout),
        stdout_sha256=hashlib.sha256(completed.stdout).hexdigest(),
        file_count=len(files),
        work_count=len(work),
        guidance_count=len(guidance),
        truncated=truncation.get("isTruncated") is True,
        omitted_file_count=omitted,
        omitted_file_count_is_lower_bound=(
            truncation.get("omittedFileCountIsLowerBound") is True
        ),
        response_usable=files_usable and work_usable and guidance_usable,
    )


def _p95(values: list[float]) -> float:
    ordered = sorted(values)
    return ordered[max(0, math.ceil(len(ordered) * 0.95) - 1)]


def _arm_summary(samples: list[_Sample], source_preserved: bool) -> dict[str, Any]:
    durations = [sample.duration_ms for sample in samples]
    byte_counts = [sample.stdout_bytes for sample in samples]
    return {
        "sampleCount": len(samples),
        "durationMs": {
            "median": round(statistics.median(durations), 3),
            "p95": round(_p95(durations), 3),
        },
        "stdoutBytes": {
            "min": min(byte_counts),
            "median": int(statistics.median(byte_counts)),
            "max": max(byte_counts),
        },
        "responseDeterministic": len({sample.stdout_sha256 for sample in samples}) == 1,
        "responseUsable": all(sample.response_usable for sample in samples),
        "responseShape": {
            "fileCounts": sorted({sample.file_count for sample in samples}),
            "workCounts": sorted({sample.work_count for sample in samples}),
            "workflowGuidanceCounts": sorted({sample.guidance_count for sample in samples}),
            "truncatedValues": sorted({sample.truncated for sample in samples}),
            "omittedFileCounts": sorted({sample.omitted_file_count for sample in samples}),
            "omittedFileCountLowerBoundValues": sorted({
                sample.omitted_file_count_is_lower_bound for sample in samples
            }),
        },
        "sourcePreserved": source_preserved,
    }


def run_wide_directory_probe(
    baseline_binary: Path,
    candidate_binary: Path,
    *,
    limits: ProbeLimits | None = None,
) -> dict[str, Any]:
    """Measure two binaries on byte-identical wide workspaces without inference."""
    limits = limits or ProbeLimits()
    binaries = {
        "baseline": baseline_binary.expanduser().resolve(),
        "candidate": candidate_binary.expanduser().resolve(),
    }
    for label, binary in binaries.items():
        if not binary.is_file() or not os.access(binary, os.X_OK):
            raise ValueError(f"Wide-directory {label} executable is unavailable: {binary}")

    with tempfile.TemporaryDirectory(prefix="marginbench-wide-probe-") as temporary:
        root = Path(temporary)
        seed = root / "seed"
        seed.mkdir()
        fixture_digest = _materialize_fixture(seed, binaries["candidate"], limits)
        workspaces = {"baseline": root / "arm-a", "candidate": root / "arm-b"}
        for workspace in workspaces.values():
            shutil.copytree(seed, workspace)
            if _tree_digest(workspace) != fixture_digest:
                raise RuntimeError("Wide-directory fixture copies are not byte-identical.")

        state_homes = {"baseline": root / "state-a", "candidate": root / "state-b"}
        for _ in range(limits.warmups):
            for label in ("baseline", "candidate"):
                _sample(
                    binaries[label], workspaces[label], state_homes[label], limits.timeout_seconds,
                )

        samples: dict[str, list[_Sample]] = {"baseline": [], "candidate": []}
        for round_index in range(limits.rounds):
            order = ("baseline", "candidate") if round_index % 2 == 0 else ("candidate", "baseline")
            for label in order:
                samples[label].append(_sample(
                    binaries[label],
                    workspaces[label],
                    state_homes[label],
                    limits.timeout_seconds,
                ))

        arms = {
            label: {
                "binarySha256": binary_sha256(binaries[label]),
                **_arm_summary(samples[label], _tree_digest(workspaces[label]) == fixture_digest),
            }
            for label in ("baseline", "candidate")
        }
        baseline_bytes = arms["baseline"]["stdoutBytes"]["median"]
        candidate_bytes = arms["candidate"]["stdoutBytes"]["median"]
        baseline_duration = arms["baseline"]["durationMs"]["median"]
        candidate_duration = arms["candidate"]["durationMs"]["median"]
        passed = all(
            arms[label]["responseDeterministic"]
            and arms[label]["responseUsable"]
            and arms[label]["sourcePreserved"]
            for label in arms
        )
        return {
            "schema": PROBE_SCHEMA,
            "version": PROBE_VERSION,
            "paidModelsInvoked": False,
            "passed": passed,
            "fixture": {
                "sha256": fixture_digest,
                "fileCount": limits.files,
                "contributionsPerFile": limits.contributions_per_file,
                "totalContributionCount": limits.files * limits.contributions_per_file,
            },
            "method": {
                "command": "context --json --brief",
                "warmupCountPerArm": limits.warmups,
                "roundCountPerArm": limits.rounds,
                "counterbalanced": True,
                "timeoutSeconds": limits.timeout_seconds,
            },
            "arms": arms,
            "comparison": {
                "candidateMinusBaselineBytes": candidate_bytes - baseline_bytes,
                "candidateToBaselineByteRatio": round(candidate_bytes / baseline_bytes, 6),
                "candidateToBaselineMedianDurationRatio": round(
                    candidate_duration / baseline_duration, 6,
                ),
            },
        }
