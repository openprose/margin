"""Provider-neutral data contracts for MarginBench v1."""

from __future__ import annotations

import hashlib
import json
import math
from dataclasses import asdict, dataclass, field
from pathlib import Path, PurePosixPath
from typing import Any

from .controls import DEFAULT_CONTROL_PROFILE


SCHEMA_VERSION = "urn:marginbench:episode:v1"
RESULT_SCHEMA_VERSION = "urn:marginbench:result:v1"


def canonical_json(value: Any) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def safe_relative_path(value: str) -> str:
    path = PurePosixPath(value)
    if not value or path.is_absolute() or ".." in path.parts or "\x00" in value:
        raise ValueError(f"Unsafe workspace path: {value!r}")
    normalized = path.as_posix()
    if normalized in {".", ""}:
        raise ValueError("A document path must name a file.")
    return normalized


@dataclass(frozen=True)
class Actor:
    id: str
    name: str
    type: str = "software"

    def __post_init__(self) -> None:
        if not self.id or not self.name or self.type not in {"person", "software", "organization"}:
            raise ValueError("Invalid actor identity.")


@dataclass(frozen=True)
class RoleTask:
    seat: str
    actor: Actor
    phase: int
    prompt: str
    workflow: str

    def __post_init__(self) -> None:
        if self.seat not in {"author", "reviewer"}:
            raise ValueError(f"Unsupported role seat: {self.seat}")
        if self.phase < 0 or not self.prompt or not self.workflow:
            raise ValueError("Invalid role task.")


@dataclass(frozen=True)
class HarnessEvent:
    phase: int
    timing: str
    kind: str
    payload: dict[str, Any]

    def __post_init__(self) -> None:
        if self.phase < 0 or self.timing not in {"before", "after"}:
            raise ValueError("Invalid harness event timing.")
        if self.kind not in {"comment_add", "source_replace"}:
            raise ValueError(f"Unsupported harness event: {self.kind}")


@dataclass(frozen=True)
class EpisodeDefinition:
    scenario_id: str
    repetition: int
    fingerprint: str
    files: dict[str, str]
    roles: tuple[RoleTask, ...]
    events: tuple[HarnessEvent, ...]
    oracle: dict[str, Any]
    controls: tuple[str, ...] = (DEFAULT_CONTROL_PROFILE,)
    schema: str = SCHEMA_VERSION

    def __post_init__(self) -> None:
        if self.schema != SCHEMA_VERSION or not self.scenario_id or self.repetition < 0:
            raise ValueError("Invalid episode identity.")
        if len(self.fingerprint) != 64:
            raise ValueError("Episode fingerprint must be a SHA-256 digest.")
        if not self.files or not self.roles:
            raise ValueError("An episode needs files and roles.")
        for path, body in self.files.items():
            safe_relative_path(path)
            body.encode("utf-8")
        phases = {role.phase for role in self.roles}
        if phases != set(range(max(phases) + 1)):
            raise ValueError("Role phases must be contiguous from zero.")

    @property
    def public_id(self) -> str:
        return f"{self.scenario_id}:{self.repetition}:{self.fingerprint[:12]}"

    def materialize(self, workspace: Path) -> None:
        workspace.mkdir(parents=True, exist_ok=True)
        for relative, body in self.files.items():
            destination = workspace / safe_relative_path(relative)
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_text(body, encoding="utf-8", newline="")

    def public_manifest(self) -> dict[str, Any]:
        return {
            "schema": self.schema,
            "id": self.public_id,
            "scenario": self.scenario_id,
            "repetition": self.repetition,
            "fingerprint": self.fingerprint,
            "fileCount": len(self.files),
            "roles": [
                {
                    "seat": role.seat,
                    "phase": role.phase,
                    "workflow": role.workflow,
                }
                for role in self.roles
            ],
            "controls": list(self.controls),
        }


@dataclass(frozen=True)
class CommandEvent:
    role: str
    command: str
    exit_code: int
    duration_ms: float
    stdin_bytes: int
    stdout_bytes: int
    stderr_bytes: int
    error_code: str | None = None
    blocked: bool = False

    def __post_init__(self) -> None:
        if not self.role or not self.command:
            raise ValueError("Command events require a role and command path.")
        if not isinstance(self.exit_code, int) or isinstance(self.exit_code, bool):
            raise ValueError("Command event exit_code must be an integer.")
        if not isinstance(self.duration_ms, (int, float)) or not math.isfinite(self.duration_ms) or self.duration_ms < 0:
            raise ValueError("Command event duration must be finite and nonnegative.")
        for field_name, value in (
            ("stdin_bytes", self.stdin_bytes),
            ("stdout_bytes", self.stdout_bytes),
            ("stderr_bytes", self.stderr_bytes),
        ):
            if not isinstance(value, int) or isinstance(value, bool) or value < 0:
                raise ValueError(f"Command event {field_name} must be a nonnegative integer.")
        if self.error_code is not None and not isinstance(self.error_code, str):
            raise ValueError("Command event error_code must be null or text.")
        if not isinstance(self.blocked, bool):
            raise ValueError("Command event blocked must be boolean.")


@dataclass(frozen=True)
class EpisodeResult:
    episode_id: str
    candidate_id: str
    score: float
    dimensions: dict[str, float]
    checks: dict[str, bool]
    command_count: int
    invalid_command_count: int
    duration_ms: float
    safety_passed: bool
    source_preserved: bool
    margin_sha256: str
    events: tuple[CommandEvent, ...] = field(default_factory=tuple)
    schema: str = RESULT_SCHEMA_VERSION

    def __post_init__(self) -> None:
        if self.schema != RESULT_SCHEMA_VERSION:
            raise ValueError("Unsupported episode result schema.")
        if not self.episode_id or len(self.episode_id.encode("utf-8")) > 512:
            raise ValueError("Episode result id must contain between 1 and 512 UTF-8 bytes.")
        if not self.candidate_id or len(self.candidate_id.encode("utf-8")) > 256:
            raise ValueError("Candidate id must contain between 1 and 256 UTF-8 bytes.")
        if (
            not isinstance(self.score, (int, float))
            or isinstance(self.score, bool)
            or not math.isfinite(self.score)
            or not 0 <= self.score <= 100
        ):
            raise ValueError("Episode score must be finite and between 0 and 100.")
        for field_name, value in (
            ("command_count", self.command_count),
            ("invalid_command_count", self.invalid_command_count),
        ):
            if not isinstance(value, int) or isinstance(value, bool) or value < 0:
                raise ValueError(f"{field_name} must be a nonnegative integer.")
        if self.invalid_command_count > self.command_count:
            raise ValueError("invalid_command_count cannot exceed command_count.")
        if (
            not isinstance(self.duration_ms, (int, float))
            or isinstance(self.duration_ms, bool)
            or not math.isfinite(self.duration_ms)
            or self.duration_ms < 0
        ):
            raise ValueError("Episode duration must be finite and nonnegative.")
        if not isinstance(self.safety_passed, bool) or not isinstance(self.source_preserved, bool):
            raise ValueError("Episode safety and source-preservation flags must be boolean.")
        if (not self.safety_passed or not self.source_preserved) and self.score > 25:
            raise ValueError("Unsafe or source-corrupt episode scores must be capped at 25.")
        if (
            len(self.margin_sha256) != 64
            or any(character not in "0123456789abcdef" for character in self.margin_sha256)
        ):
            raise ValueError("margin_sha256 must be a lowercase SHA-256 digest.")
        if not isinstance(self.dimensions, dict) or any(
            not isinstance(name, str)
            or not isinstance(value, (int, float))
            or isinstance(value, bool)
            or not math.isfinite(value)
            or not 0 <= value <= 100
            for name, value in self.dimensions.items()
        ):
            raise ValueError("Episode dimensions must contain finite scores between 0 and 100.")
        if not isinstance(self.checks, dict) or any(
            not isinstance(name, str) or not isinstance(value, bool)
            for name, value in self.checks.items()
        ):
            raise ValueError("Episode checks must contain boolean values.")
        if not isinstance(self.events, tuple) or any(
            not isinstance(event, CommandEvent) for event in self.events
        ):
            raise ValueError("Episode events must be a tuple of CommandEvent values.")
        if self.events and len(self.events) != self.command_count:
            raise ValueError("A populated event tuple must match command_count.")

    def to_dict(self) -> dict[str, Any]:
        value = asdict(self)
        value["events"] = [asdict(event) for event in self.events]
        return value

    def canonical_sha256(self) -> str:
        return sha256_bytes(canonical_json(self.to_dict()))
