"""Trusted phase-bound identities for a continuing MarginBench interaction."""

from __future__ import annotations

import json
import os
import stat
import tempfile
import threading
from dataclasses import dataclass
from pathlib import Path

from .schema import Actor, RoleTask, canonical_json


MAX_BINDING_BYTES = 4096


@dataclass(frozen=True)
class PhaseIdentityBinding:
    ordinal: int
    phase: int
    seat: str
    actor: Actor


def _decode_binding(raw: bytes) -> PhaseIdentityBinding:
    def unique_object(pairs):
        value = {}
        for key, item in pairs:
            if key in value:
                raise ValueError("Phase identity binding contains a duplicate key.")
            value[key] = item
        return value

    if not raw or len(raw) > MAX_BINDING_BYTES:
        raise ValueError("Phase identity binding is empty or oversized.")
    try:
        payload = json.loads(raw.decode("utf-8"), object_pairs_hook=unique_object)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValueError("Phase identity binding is not valid UTF-8 JSON.") from error
    if not isinstance(payload, dict) or set(payload) != {"actor", "ordinal", "phase", "seat"}:
        raise ValueError("Phase identity binding has an unexpected shape.")
    actor_value = payload["actor"]
    if not isinstance(actor_value, dict) or set(actor_value) != {"id", "name", "type"}:
        raise ValueError("Phase identity actor has an unexpected shape.")
    ordinal, phase, seat = payload["ordinal"], payload["phase"], payload["seat"]
    if (
        not isinstance(ordinal, int)
        or isinstance(ordinal, bool)
        or ordinal < 0
        or not isinstance(phase, int)
        or isinstance(phase, bool)
        or phase < 0
        or not isinstance(seat, str)
        or not seat
    ):
        raise ValueError("Phase identity position is invalid.")
    try:
        actor = Actor(**actor_value)
    except (TypeError, ValueError) as error:
        raise ValueError("Phase identity actor is invalid.") from error
    return PhaseIdentityBinding(ordinal=ordinal, phase=phase, seat=seat, actor=actor)


def read_phase_identity(path: Path) -> PhaseIdentityBinding:
    """Read one atomic binding without following a replaced symlink."""
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise ValueError("Trusted phase identity is unavailable.") from error
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_size > MAX_BINDING_BYTES:
            raise ValueError("Trusted phase identity is not a bounded regular file.")
        chunks = []
        remaining = MAX_BINDING_BYTES + 1
        while remaining:
            chunk = os.read(descriptor, remaining)
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        raw = b"".join(chunks)
    finally:
        os.close(descriptor)
    return _decode_binding(raw)


class PhaseIdentityController:
    """Advance only through a frozen role sequence and publish each identity atomically."""

    def __init__(self, path: Path, roles: list[RoleTask]) -> None:
        if not roles:
            raise ValueError("A phase identity controller needs at least one role.")
        expected = sorted(roles, key=lambda role: role.phase)
        if expected != roles:
            raise ValueError("Phase identity roles must already be in stable phase order.")
        self.path = path
        self.roles = tuple(roles)
        self._next = 0
        self._lock = threading.Lock()

    def advance(self, role: RoleTask) -> PhaseIdentityBinding:
        with self._lock:
            if self._next >= len(self.roles) or role != self.roles[self._next]:
                raise ValueError("Phase identity advance is out of order or already complete.")
            binding = PhaseIdentityBinding(
                ordinal=self._next,
                phase=role.phase,
                seat=role.seat,
                actor=role.actor,
            )
            self._write(binding)
            self._next += 1
            return binding

    def _write(self, binding: PhaseIdentityBinding) -> None:
        parent = self.path.parent.resolve(strict=True)
        target = parent / self.path.name
        payload = canonical_json({
            "actor": {
                "id": binding.actor.id,
                "name": binding.actor.name,
                "type": binding.actor.type,
            },
            "ordinal": binding.ordinal,
            "phase": binding.phase,
            "seat": binding.seat,
        })
        if len(payload) > MAX_BINDING_BYTES:
            raise ValueError("Phase identity binding exceeds its byte limit.")
        descriptor, temporary_name = tempfile.mkstemp(prefix=f".{target.name}.", dir=parent)
        temporary = Path(temporary_name)
        try:
            os.fchmod(descriptor, 0o600)
            with os.fdopen(descriptor, "wb", closefd=True) as handle:
                descriptor = -1
                handle.write(payload)
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temporary, target)
            directory = os.open(parent, os.O_RDONLY)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
        finally:
            if descriptor >= 0:
                os.close(descriptor)
            try:
                temporary.unlink()
            except FileNotFoundError:
                pass
