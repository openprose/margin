"""Confined ordinary-Markdown gateway for a future neutral control profile."""

from __future__ import annotations

import errno
import fcntl
import hashlib
import json
import os
import secrets
import stat
import threading
from contextlib import contextmanager
from dataclasses import dataclass, replace
from pathlib import Path, PurePosixPath
from typing import Iterator, cast

from .neutral import FACT_ID_PATTERN, MAX_FACTS, NeutralFormatError, NeutralLedger
from .schema import Actor, canonical_json, safe_relative_path, sha256_bytes


MAX_FILE_BYTES = 1_048_576
MAX_READ_BYTES = 65_536
MAX_LIST_ENTRIES = 256
MAX_LINE_COUNT = 2_000
MAX_PROVENANCE_BYTES = 4_194_304
MAX_PROVENANCE_EVENTS = 10_000


class PlainGatewayError(ValueError):
    def __init__(
        self,
        code: str,
        message: str,
        *,
        details: dict[str, object] | None = None,
    ) -> None:
        super().__init__(message)
        self.code = code
        self.details = details


@dataclass(frozen=True)
class PlainWriteEvent:
    sequence: int
    actor_id: str
    actor_type: str
    path: str
    before_sha256: str
    after_sha256: str
    byte_count: int
    introduced_fact_ids: tuple[str, ...] = ()
    removed_fact_ids: tuple[str, ...] = ()
    changed_fact_ids: tuple[str, ...] = ()
    decided_fact_ids: tuple[str, ...] = ()
    visible_fact_ids: tuple[str, ...] = ()

    def to_dict(self) -> dict[str, object]:
        return {
            "sequence": self.sequence,
            "actorID": self.actor_id,
            "actorType": self.actor_type,
            "path": self.path,
            "beforeSha256": self.before_sha256,
            "afterSha256": self.after_sha256,
            "byteCount": self.byte_count,
            "introducedFactIDs": list(self.introduced_fact_ids),
            "removedFactIDs": list(self.removed_fact_ids),
            "changedFactIDs": list(self.changed_fact_ids),
            "decidedFactIDs": list(self.decided_fact_ids),
            "visibleFactIDs": list(self.visible_fact_ids),
        }


@dataclass(frozen=True)
class PlainReadEvent:
    sequence: int
    actor_id: str
    actor_type: str
    path: str
    sha256: str
    byte_count: int
    visible_fact_ids: tuple[str, ...] = ()


@dataclass(frozen=True)
class PlainFailureEvent:
    sequence: int
    actor_id: str
    actor_type: str
    action: str
    path: str
    error_code: str


@dataclass(frozen=True)
class PlainCallEvent:
    sequence: int
    actor_id: str
    actor_type: str
    action: str
    succeeded: bool
    error_code: str | None = None
    request_byte_count: int = 0
    response_byte_count: int = 0
    duration_microseconds: int = 0


_WRITE_FIELDS = {
    "type", "sequence", "actor_id", "actor_type", "path", "before_sha256",
    "after_sha256", "byte_count", "introduced_fact_ids", "removed_fact_ids",
    "changed_fact_ids", "decided_fact_ids", "visible_fact_ids",
}
_READ_FIELDS = {
    "type", "sequence", "actor_id", "actor_type", "path", "sha256",
    "byte_count", "visible_fact_ids",
}
_FAILURE_FIELDS = {
    "type", "sequence", "actor_id", "actor_type", "action", "path", "error_code",
}
_CALL_FIELDS = {
    "type", "sequence", "actor_id", "actor_type", "action", "succeeded", "error_code",
    "request_byte_count", "response_byte_count", "duration_microseconds",
}


def _invalid_provenance() -> PlainGatewayError:
    return PlainGatewayError(
        "INVALID_PROVENANCE",
        "Provenance log contains an invalid event record.",
    )


def _unique_json_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise _invalid_provenance()
        result[key] = value
    return result


def _reject_json_constant(_: str) -> None:
    raise _invalid_provenance()


def _bounded_scalar(value: object, *, maximum: int = 4_096) -> str:
    if (
        not isinstance(value, str)
        or not value
        or "\x00" in value
        or "\n" in value
        or "\r" in value
        or len(value.encode("utf-8")) > maximum
    ):
        raise _invalid_provenance()
    return value


def _sequence(value: object) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or not 1 <= value <= MAX_PROVENANCE_EVENTS:
        raise _invalid_provenance()
    return value


def _byte_count(value: object) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or not 0 <= value <= MAX_FILE_BYTES:
        raise _invalid_provenance()
    return value


def _bounded_count(value: object, maximum: int) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or not 0 <= value <= maximum:
        raise _invalid_provenance()
    return value


def _actor_type(value: object) -> str:
    if not isinstance(value, str) or value not in {"person", "software", "organization"}:
        raise _invalid_provenance()
    return cast(str, value)


def _digest(value: object) -> str:
    if not re_full_sha256(value):
        raise _invalid_provenance()
    return cast(str, value)


def _event_path(value: object) -> str:
    path = _bounded_scalar(value, maximum=1_024)
    try:
        normalized = safe_relative_path(path)
    except ValueError as error:
        raise _invalid_provenance() from error
    parts = PurePosixPath(path).parts
    if (
        normalized != path
        or "\\" in path
        or any(part.startswith(".") for part in parts)
        or not path.lower().endswith(".md")
    ):
        raise _invalid_provenance()
    return path


def _fact_ids(value: object) -> tuple[str, ...]:
    if (
        not isinstance(value, list)
        or len(value) > MAX_FACTS
        or any(not isinstance(item, str) or FACT_ID_PATTERN.fullmatch(item) is None for item in value)
        or value != sorted(set(value))
    ):
        raise _invalid_provenance()
    return tuple(value)


def _record_for(
    kind: str,
    event: PlainWriteEvent | PlainReadEvent | PlainFailureEvent | PlainCallEvent,
) -> dict[str, object]:
    payload: dict[str, object] = {"type": kind}
    for key, value in event.__dict__.items():
        payload[key] = list(value) if isinstance(value, tuple) else value
    return payload


def _event_from_record(
    record: dict[str, object],
) -> PlainWriteEvent | PlainReadEvent | PlainFailureEvent | PlainCallEvent:
    kind = record.get("type")
    expected = (
        {
            "write": _WRITE_FIELDS,
            "read": _READ_FIELDS,
            "failure": _FAILURE_FIELDS,
            "call": _CALL_FIELDS,
        }.get(kind)
        if isinstance(kind, str)
        else None
    )
    if expected is None or set(record) != expected:
        raise _invalid_provenance()
    actor = {
        "sequence": _sequence(record["sequence"]),
        "actor_id": _bounded_scalar(record["actor_id"]),
        "actor_type": _actor_type(record["actor_type"]),
    }
    if kind == "call":
        action = _bounded_scalar(record["action"], maximum=64)
        succeeded = record["succeeded"]
        error_code = record["error_code"]
        if (
            action not in {"guide", "list", "read", "write", "invalid"}
            or not isinstance(succeeded, bool)
            or (error_code is not None and not isinstance(error_code, str))
            or (succeeded and error_code is not None)
            or (not succeeded and error_code is None)
        ):
            raise _invalid_provenance()
        return PlainCallEvent(
            **actor,
            action=action,
            succeeded=succeeded,
            error_code=(
                None if error_code is None else _bounded_scalar(error_code, maximum=128)
            ),
            request_byte_count=_bounded_count(record["request_byte_count"], 4_194_304),
            response_byte_count=_bounded_count(record["response_byte_count"], 4_194_304),
            duration_microseconds=_bounded_count(record["duration_microseconds"], 600_000_000),
        )
    common = {**actor, "path": _event_path(record["path"])}
    if kind == "write":
        introduced = _fact_ids(record["introduced_fact_ids"])
        removed = _fact_ids(record["removed_fact_ids"])
        changed = _fact_ids(record["changed_fact_ids"])
        decided = _fact_ids(record["decided_fact_ids"])
        visible = _fact_ids(record["visible_fact_ids"])
        sets = tuple(map(set, (introduced, removed, changed)))
        if any(left & right for index, left in enumerate(sets) for right in sets[index + 1 :]) or not set(decided) <= set(changed):
            raise _invalid_provenance()
        before = _digest(record["before_sha256"])
        after = _digest(record["after_sha256"])
        if before == after:
            raise _invalid_provenance()
        return PlainWriteEvent(
            **common,
            before_sha256=before,
            after_sha256=after,
            byte_count=_byte_count(record["byte_count"]),
            introduced_fact_ids=introduced,
            removed_fact_ids=removed,
            changed_fact_ids=changed,
            decided_fact_ids=decided,
            visible_fact_ids=visible,
        )
    if kind == "read":
        return PlainReadEvent(
            **common,
            sha256=_digest(record["sha256"]),
            byte_count=_byte_count(record["byte_count"]),
            visible_fact_ids=_fact_ids(record["visible_fact_ids"]),
        )
    action = _bounded_scalar(record["action"], maximum=64)
    error_code = _bounded_scalar(record["error_code"], maximum=128)
    if action != "write" or error_code != "PRECONDITION_FAILED":
        raise _invalid_provenance()
    return PlainFailureEvent(**common, action=action, error_code=error_code)


class PlainProvenanceLog:
    """Shared trusted memory; public run artifacts must project/redact it."""

    def __init__(self, path: Path | None = None) -> None:
        self._lock = threading.Lock()
        self._sequence = 0
        self._events: list[PlainWriteEvent] = []
        self._reads: list[PlainReadEvent] = []
        self._failures: list[PlainFailureEvent] = []
        self._calls: list[PlainCallEvent] = []
        self.path = None if path is None else path.expanduser().absolute()
        if self.path is not None:
            try:
                self.path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
                parent_status = os.lstat(self.path.parent)
            except OSError as error:
                raise PlainGatewayError(
                    "INVALID_PROVENANCE",
                    "Provenance directory is unavailable.",
                ) from error
            if stat.S_ISLNK(parent_status.st_mode) or not stat.S_ISDIR(parent_status.st_mode):
                raise PlainGatewayError(
                    "INVALID_PROVENANCE",
                    "Provenance directory must be a non-symlink directory.",
                )
            if stat.S_IMODE(parent_status.st_mode) & 0o077:
                raise PlainGatewayError(
                    "INVALID_PROVENANCE",
                    "Provenance directory must be private to the current user.",
                )

    @contextmanager
    def _records(self, *, exclusive: bool) -> Iterator[tuple[int, list[dict[str, object]]]]:
        if self.path is None:
            raise RuntimeError("Durable provenance path is not configured.")
        flags = os.O_RDWR | os.O_CREAT
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        try:
            descriptor = os.open(self.path, flags, 0o600)
            os.fchmod(descriptor, 0o600)
            status = os.fstat(descriptor)
            if not stat.S_ISREG(status.st_mode) or status.st_nlink != 1:
                raise PlainGatewayError(
                    "INVALID_PROVENANCE",
                    "Provenance target must be one regular file.",
                )
            fcntl.flock(descriptor, fcntl.LOCK_EX if exclusive else fcntl.LOCK_SH)
            os.lseek(descriptor, 0, os.SEEK_SET)
            chunks: list[bytes] = []
            remaining = MAX_PROVENANCE_BYTES + 1
            while remaining:
                chunk = os.read(descriptor, min(65_536, remaining))
                if not chunk:
                    break
                chunks.append(chunk)
                remaining -= len(chunk)
            raw = b"".join(chunks)
            if len(raw) > MAX_PROVENANCE_BYTES:
                raise PlainGatewayError(
                    "INVALID_PROVENANCE",
                    "Provenance log exceeds its byte bound.",
                )
            if raw and not raw.endswith(b"\n"):
                raise PlainGatewayError(
                    "INVALID_PROVENANCE",
                    "Provenance log has an incomplete record.",
                )
            records: list[dict[str, object]] = []
            for line in raw.splitlines():
                try:
                    value = json.loads(
                        line.decode("utf-8"),
                        object_pairs_hook=_unique_json_object,
                        parse_constant=_reject_json_constant,
                    )
                except (UnicodeDecodeError, json.JSONDecodeError) as error:
                    raise PlainGatewayError(
                        "INVALID_PROVENANCE",
                        "Provenance log contains an invalid record.",
                    ) from error
                if not isinstance(value, dict):
                    raise PlainGatewayError(
                        "INVALID_PROVENANCE",
                        "Provenance log record must be an object.",
                    )
                if canonical_json(value) != line:
                    raise PlainGatewayError(
                        "INVALID_PROVENANCE",
                        "Provenance log record is not canonical.",
                    )
                _event_from_record(value)
                records.append(value)
            if len(records) > MAX_PROVENANCE_EVENTS or any(
                record.get("sequence") != index
                for index, record in enumerate(records, start=1)
            ):
                raise PlainGatewayError(
                    "INVALID_PROVENANCE",
                    "Provenance log sequence or count is invalid.",
                )
            yield descriptor, records
        except PlainGatewayError:
            raise
        except OSError as error:
            raise PlainGatewayError(
                "INVALID_PROVENANCE",
                "Provenance log is unavailable.",
            ) from error
        finally:
            if "descriptor" in locals():
                try:
                    fcntl.flock(descriptor, fcntl.LOCK_UN)
                finally:
                    os.close(descriptor)

    def _recorded(
        self,
        kind: str,
        event: PlainWriteEvent | PlainReadEvent | PlainFailureEvent | PlainCallEvent,
        sequence: int,
    ) -> PlainWriteEvent | PlainReadEvent | PlainFailureEvent | PlainCallEvent:
        return _event_from_record(_record_for(kind, replace(event, sequence=sequence)))

    def _append_durable(
        self,
        kind: str,
        event: PlainWriteEvent | PlainReadEvent | PlainFailureEvent | PlainCallEvent,
    ) -> PlainWriteEvent | PlainReadEvent | PlainFailureEvent | PlainCallEvent:
        with self._records(exclusive=True) as (descriptor, records):
            if len(records) >= MAX_PROVENANCE_EVENTS:
                raise PlainGatewayError(
                    "PROVENANCE_LIMIT",
                    "Provenance log reached its event bound.",
                )
            sequence = len(records) + 1
            recorded = self._recorded(kind, event, sequence)
            payload = _record_for(kind, recorded)
            encoded = canonical_json(payload) + b"\n"
            size = os.lseek(descriptor, 0, os.SEEK_END)
            if size + len(encoded) > MAX_PROVENANCE_BYTES:
                raise PlainGatewayError(
                    "PROVENANCE_LIMIT",
                    "Provenance log reached its byte bound.",
                )
            position = 0
            while position < len(encoded):
                position += os.write(descriptor, encoded[position:])
            os.fsync(descriptor)
            return recorded

    def _durable_snapshots(
        self,
    ) -> tuple[
        list[PlainWriteEvent],
        list[PlainReadEvent],
        list[PlainFailureEvent],
        list[PlainCallEvent],
    ]:
        writes: list[PlainWriteEvent] = []
        reads: list[PlainReadEvent] = []
        failures: list[PlainFailureEvent] = []
        calls: list[PlainCallEvent] = []
        with self._records(exclusive=False) as (_, records):
            for record in records:
                event = _event_from_record(record)
                if isinstance(event, PlainWriteEvent):
                    writes.append(event)
                elif isinstance(event, PlainReadEvent):
                    reads.append(event)
                elif isinstance(event, PlainFailureEvent):
                    failures.append(event)
                else:
                    calls.append(event)
        return writes, reads, failures, calls

    def append(self, event: PlainWriteEvent) -> PlainWriteEvent:
        if self.path is not None:
            return cast(PlainWriteEvent, self._append_durable("write", event))
        with self._lock:
            self._sequence += 1
            recorded = cast(PlainWriteEvent, self._recorded("write", event, self._sequence))
            self._events.append(recorded)
            return recorded

    def append_read(self, event: PlainReadEvent) -> PlainReadEvent:
        if self.path is not None:
            return cast(PlainReadEvent, self._append_durable("read", event))
        with self._lock:
            self._sequence += 1
            recorded = cast(PlainReadEvent, self._recorded("read", event, self._sequence))
            self._reads.append(recorded)
            return recorded

    def snapshot(self) -> tuple[PlainWriteEvent, ...]:
        if self.path is not None:
            return tuple(self._durable_snapshots()[0])
        with self._lock:
            return tuple(self._events)

    def read_snapshot(self) -> tuple[PlainReadEvent, ...]:
        if self.path is not None:
            return tuple(self._durable_snapshots()[1])
        with self._lock:
            return tuple(self._reads)

    def append_failure(self, event: PlainFailureEvent) -> PlainFailureEvent:
        if self.path is not None:
            return cast(PlainFailureEvent, self._append_durable("failure", event))
        with self._lock:
            self._sequence += 1
            recorded = cast(PlainFailureEvent, self._recorded("failure", event, self._sequence))
            self._failures.append(recorded)
            return recorded

    def failure_snapshot(self) -> tuple[PlainFailureEvent, ...]:
        if self.path is not None:
            return tuple(self._durable_snapshots()[2])
        with self._lock:
            return tuple(self._failures)

    def append_call(self, event: PlainCallEvent) -> PlainCallEvent:
        if self.path is not None:
            return cast(PlainCallEvent, self._append_durable("call", event))
        with self._lock:
            self._sequence += 1
            recorded = cast(PlainCallEvent, self._recorded("call", event, self._sequence))
            self._calls.append(recorded)
            return recorded

    def call_snapshot(self) -> tuple[PlainCallEvent, ...]:
        if self.path is not None:
            return tuple(self._durable_snapshots()[3])
        with self._lock:
            return tuple(self._calls)


def _markdown_bytes(text: str) -> bytes:
    if not isinstance(text, str):
        raise PlainGatewayError("INVALID_CONTENT", "Replacement content must be UTF-8 text.")
    raw = text.encode("utf-8")
    if (
        len(raw) > MAX_FILE_BYTES
        or raw.startswith(b"\xef\xbb\xbf")
        or b"\r" in raw
        or b"\x00" in raw
    ):
        raise PlainGatewayError(
            "INVALID_CONTENT",
            "Replacement must be bounded UTF-8 Markdown with LF line endings.",
        )
    return raw


class PlainWorkspaceGateway:
    def __init__(
        self,
        root: Path,
        actor: Actor,
        state_directory: Path,
        provenance: PlainProvenanceLog | None = None,
    ) -> None:
        self.root = root.expanduser().absolute()
        self.actor = actor
        self.state_directory = state_directory.expanduser().absolute()
        self.provenance = provenance or PlainProvenanceLog()
        try:
            root_status = os.lstat(self.root)
        except OSError as error:
            raise PlainGatewayError("INVALID_ROOT", "Workspace root is unavailable.") from error
        if stat.S_ISLNK(root_status.st_mode) or not stat.S_ISDIR(root_status.st_mode):
            raise PlainGatewayError("INVALID_ROOT", "Workspace root must be a non-symlink directory.")
        try:
            self.state_directory.mkdir(mode=0o700, parents=True, exist_ok=True)
            state_status = os.lstat(self.state_directory)
        except OSError as error:
            raise PlainGatewayError("INVALID_STATE", "Gateway state directory is unavailable.") from error
        if stat.S_ISLNK(state_status.st_mode) or not stat.S_ISDIR(state_status.st_mode):
            raise PlainGatewayError("INVALID_STATE", "Gateway state must be a non-symlink directory.")
        root_digest = hashlib.sha256(os.fsencode(self.root)).hexdigest()
        self.lock_path = self.state_directory / f"plain-{root_digest}.lock"

    @contextmanager
    def _workspace_lock(self, *, exclusive: bool) -> Iterator[None]:
        flags = os.O_RDWR | os.O_CREAT
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        try:
            descriptor = os.open(self.lock_path, flags, 0o600)
            fcntl.flock(descriptor, fcntl.LOCK_EX if exclusive else fcntl.LOCK_SH)
            yield
        except OSError as error:
            raise PlainGatewayError("LOCK_FAILED", "Workspace lock could not be acquired.") from error
        finally:
            if "descriptor" in locals():
                try:
                    fcntl.flock(descriptor, fcntl.LOCK_UN)
                finally:
                    os.close(descriptor)

    def _parts(self, relative: str, *, allow_root: bool = False) -> tuple[str, ...]:
        if allow_root and relative in {"", "."}:
            return ()
        try:
            normalized = safe_relative_path(relative)
        except ValueError as error:
            raise PlainGatewayError("UNSAFE_PATH", "Path is outside the workspace policy.") from error
        parts = PurePosixPath(normalized).parts
        if (
            normalized != relative
            or "\\" in relative
            or any(not part or part.startswith(".") for part in parts)
        ):
            raise PlainGatewayError("UNSAFE_PATH", "Path is outside the workspace policy.")
        return parts

    @contextmanager
    def _directory(self, parts: tuple[str, ...]) -> Iterator[int]:
        flags = os.O_RDONLY | os.O_DIRECTORY
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        descriptors: list[int] = []
        try:
            descriptor = os.open(self.root, flags)
            descriptors.append(descriptor)
            for part in parts:
                descriptor = os.open(part, flags, dir_fd=descriptor)
                descriptors.append(descriptor)
            yield descriptor
        except OSError as error:
            code = "SYMLINK_BLOCKED" if error.errno == errno.ELOOP else "PATH_UNAVAILABLE"
            raise PlainGatewayError(code, "Workspace directory is unavailable.") from error
        finally:
            for descriptor in reversed(descriptors):
                os.close(descriptor)

    @contextmanager
    def _parent(self, relative: str) -> Iterator[tuple[int, str]]:
        parts = self._parts(relative)
        with self._directory(parts[:-1]) as descriptor:
            yield descriptor, parts[-1]

    def _read_file(self, relative: str) -> tuple[bytes, int]:
        if not relative.lower().endswith(".md"):
            raise PlainGatewayError("UNSUPPORTED_FILE", "Only Markdown files are available.")
        with self._parent(relative) as (parent, name):
            flags = os.O_RDONLY
            if hasattr(os, "O_NOFOLLOW"):
                flags |= os.O_NOFOLLOW
            try:
                descriptor = os.open(name, flags, dir_fd=parent)
                status = os.fstat(descriptor)
                if not stat.S_ISREG(status.st_mode) or status.st_nlink != 1:
                    raise PlainGatewayError("UNSUPPORTED_FILE", "Target is not a regular file.")
                chunks: list[bytes] = []
                remaining = MAX_FILE_BYTES + 1
                while remaining:
                    chunk = os.read(descriptor, min(65_536, remaining))
                    if not chunk:
                        break
                    chunks.append(chunk)
                    remaining -= len(chunk)
            except PlainGatewayError:
                raise
            except OSError as error:
                code = "SYMLINK_BLOCKED" if error.errno == errno.ELOOP else "FILE_UNAVAILABLE"
                raise PlainGatewayError(code, "Markdown file is unavailable.") from error
            finally:
                if "descriptor" in locals():
                    os.close(descriptor)
        raw = b"".join(chunks)
        if len(raw) > MAX_FILE_BYTES:
            raise PlainGatewayError("FILE_TOO_LARGE", "Markdown file exceeds the read bound.")
        try:
            raw.decode("utf-8")
        except UnicodeDecodeError as error:
            raise PlainGatewayError("INVALID_MARKDOWN", "Markdown file is not UTF-8.") from error
        if raw.startswith(b"\xef\xbb\xbf") or b"\r" in raw or b"\x00" in raw:
            raise PlainGatewayError("INVALID_MARKDOWN", "Markdown file is not canonical UTF-8/LF text.")
        return raw, stat.S_IMODE(status.st_mode)

    def list(self, relative: str = ".") -> dict[str, object]:
        parts = self._parts(relative, allow_root=True)
        with self._workspace_lock(exclusive=False), self._directory(parts) as descriptor:
            try:
                names = sorted(os.listdir(descriptor))
            except OSError as error:
                raise PlainGatewayError("LIST_FAILED", "Workspace directory could not be listed.") from error
            visible = [name for name in names if name and not name.startswith(".")]
            if len(visible) > MAX_LIST_ENTRIES:
                raise PlainGatewayError("TOO_MANY_ENTRIES", "Directory exceeds the listing bound.")
            entries: list[dict[str, object]] = []
            for name in visible:
                try:
                    status = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
                except OSError:
                    continue
                kind = (
                    "directory"
                    if stat.S_ISDIR(status.st_mode)
                    else "markdown"
                    if stat.S_ISREG(status.st_mode) and name.lower().endswith(".md")
                    else "blocked"
                )
                child = "/".join((*parts, name))
                entries.append({
                    "name": name,
                    "path": child,
                    "kind": kind,
                    "byteCount": status.st_size if kind == "markdown" else None,
                })
        return {"path": "." if not parts else "/".join(parts), "entries": entries}

    def read(
        self,
        relative: str,
        *,
        start_line: int = 1,
        max_lines: int = 200,
    ) -> dict[str, object]:
        if relative.casefold() == "collaboration.md" and relative != "COLLABORATION.md":
            raise PlainGatewayError("UNSAFE_PATH", "The collaboration ledger name is case-sensitive.")
        if not 1 <= start_line <= MAX_LINE_COUNT or not 1 <= max_lines <= MAX_LINE_COUNT:
            raise PlainGatewayError("INVALID_RANGE", "Line range is outside the read bound.")
        with self._workspace_lock(exclusive=False):
            raw, _ = self._read_file(relative)
        text = raw.decode("utf-8")
        lines = text.splitlines(keepends=True)
        selected: list[str] = []
        selected_bytes = 0
        start = min(start_line - 1, len(lines))
        for line in lines[start : start + max_lines]:
            size = len(line.encode("utf-8"))
            if selected_bytes + size > MAX_READ_BYTES:
                if not selected:
                    raise PlainGatewayError("LINE_TOO_LARGE", "One Markdown line exceeds the read bound.")
                break
            selected.append(line)
            selected_bytes += size
        end = start + len(selected)
        result = {
            "path": relative,
            "sha256": sha256_bytes(raw),
            "byteCount": len(raw),
            "startLine": start + 1,
            "endLineExclusive": end + 1,
            "text": "".join(selected),
            "truncatedBefore": start > 0,
            "truncatedAfter": end < len(lines),
        }
        visible: tuple[str, ...] = ()
        if relative == "COLLABORATION.md":
            try:
                visible = tuple(fact.id for fact in NeutralLedger.parse(raw).facts)
            except NeutralFormatError:
                pass
        self.provenance.append_read(PlainReadEvent(
            sequence=0,
            actor_id=self.actor.id,
            actor_type=self.actor.type,
            path=relative,
            sha256=sha256_bytes(raw),
            byte_count=len(raw),
            visible_fact_ids=visible,
        ))
        return result

    def write(self, relative: str, text: str, *, if_sha256: str) -> dict[str, object]:
        if relative.casefold() == "collaboration.md" and relative != "COLLABORATION.md":
            raise PlainGatewayError("UNSAFE_PATH", "The collaboration ledger name is case-sensitive.")
        if not re_full_sha256(if_sha256):
            raise PlainGatewayError("INVALID_PRECONDITION", "A lowercase SHA-256 precondition is required.")
        replacement = _markdown_bytes(text)
        with self._workspace_lock(exclusive=True):
            before, mode = self._read_file(relative)
            before_sha = sha256_bytes(before)
            if before_sha != if_sha256:
                self.provenance.append_failure(PlainFailureEvent(
                    sequence=0,
                    actor_id=self.actor.id,
                    actor_type=self.actor.type,
                    action="write",
                    path=relative,
                    error_code="PRECONDITION_FAILED",
                ))
                raise PlainGatewayError("PRECONDITION_FAILED", "Markdown file changed; reread before writing.")
            if before == replacement:
                return {
                    "path": relative,
                    "beforeSha256": before_sha,
                    "sha256": before_sha,
                    "byteCount": len(before),
                    "changed": False,
                    "eventSequence": None,
                }
            try:
                before_ledger = (
                    NeutralLedger.parse(before) if relative == "COLLABORATION.md" else None
                )
                after_ledger = (
                    NeutralLedger.parse(replacement) if relative == "COLLABORATION.md" else None
                )
            except NeutralFormatError as error:
                raise PlainGatewayError(
                    "INVALID_LEDGER",
                    "Collaboration ledger failed its strict format checks.",
                    details={
                        "formatCode": error.code,
                        "byteOffset": error.offset,
                        "recovery": (
                            "Read COLLABORATION.md again, request guide topic facts, "
                            "and retry one canonical whole-ledger replacement."
                        ),
                    },
                ) from error
            with self._parent(relative) as (parent, name):
                temporary = f".marginbench-write-{secrets.token_hex(12)}.tmp"
                flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
                if hasattr(os, "O_NOFOLLOW"):
                    flags |= os.O_NOFOLLOW
                temporary_created = False
                try:
                    descriptor = os.open(temporary, flags, 0o600, dir_fd=parent)
                    temporary_created = True
                    position = 0
                    while position < len(replacement):
                        position += os.write(descriptor, replacement[position:])
                    os.fchmod(descriptor, mode)
                    os.fsync(descriptor)
                    os.close(descriptor)
                    descriptor = -1
                    os.rename(temporary, name, src_dir_fd=parent, dst_dir_fd=parent)
                    temporary_created = False
                    os.fsync(parent)
                except OSError as error:
                    raise PlainGatewayError("WRITE_FAILED", "Atomic Markdown replacement failed.") from error
                finally:
                    if "descriptor" in locals() and descriptor >= 0:
                        os.close(descriptor)
                    if temporary_created:
                        try:
                            os.unlink(temporary, dir_fd=parent)
                        except OSError:
                            pass
            after_sha = sha256_bytes(replacement)
            event = self._event(
                relative,
                before_sha,
                after_sha,
                len(replacement),
                before_ledger,
                after_ledger,
            )
            recorded = self.provenance.append(event)
        return {
            "path": relative,
            "beforeSha256": before_sha,
            "sha256": after_sha,
            "byteCount": len(replacement),
            "changed": before != replacement,
            "eventSequence": recorded.sequence,
        }

    def _event(
        self,
        relative: str,
        before_sha: str,
        after_sha: str,
        byte_count: int,
        before: NeutralLedger | None,
        after: NeutralLedger | None,
    ) -> PlainWriteEvent:
        if before is None or after is None:
            return PlainWriteEvent(
                sequence=0,
                actor_id=self.actor.id,
                actor_type=self.actor.type,
                path=relative,
                before_sha256=before_sha,
                after_sha256=after_sha,
                byte_count=byte_count,
            )
        old = {fact.id: fact for fact in before.facts}
        new = {fact.id: fact for fact in after.facts}
        introduced = tuple(sorted(new.keys() - old.keys()))
        removed = tuple(sorted(old.keys() - new.keys()))
        changed = tuple(sorted(
            identifier
            for identifier in old.keys() & new.keys()
            if old[identifier] != new[identifier]
        ))
        decided = tuple(sorted(
            identifier
            for identifier in old.keys() & new.keys()
            if old[identifier].state != new[identifier].state
            and new[identifier].state in {"accepted", "rejected"}
        ))
        return PlainWriteEvent(
            sequence=0,
            actor_id=self.actor.id,
            actor_type=self.actor.type,
            path=relative,
            before_sha256=before_sha,
            after_sha256=after_sha,
            byte_count=byte_count,
            introduced_fact_ids=introduced,
            removed_fact_ids=removed,
            changed_fact_ids=changed,
            decided_fact_ids=decided,
            visible_fact_ids=tuple(sorted(new)),
        )


def re_full_sha256(value: object) -> bool:
    return (
        isinstance(value, str)
        and len(value) == 64
        and all(character in "0123456789abcdef" for character in value)
    )
