"""Strict, human-readable interchange for representation-neutral controls."""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from typing import Any

from .schema import EpisodeDefinition, canonical_json, safe_relative_path


NEUTRAL_FACTS_SCHEMA = "urn:marginbench:neutral-facts:v1"
NEUTRAL_FORMAT = "marginbench-neutral-v2"
PREAMBLE = b"# Collaboration\n\nFormat: marginbench-neutral-v2\n"
RECORD_PREFIX = b"\n## "
RECORD_SEPARATOR = b"\n\n## "
MAX_LEDGER_BYTES = 1_048_576
MAX_FACTS = 512
MAX_BODY_BYTES = 65_536
MAX_SCALAR_BYTES = 4_096
FACT_ID_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,255}$")
KINDS = {
    "approval",
    "comment",
    "decision",
    "handoff",
    "issue",
    "question",
    "reply",
    "suggestion",
    "task",
}
STATES = {"open", "resolved", "accepted", "rejected", "none"}
PRIORITIES = {"low", "normal", "high", "urgent"}
FIELD_ORDER = (
    "Kind",
    "File",
    "Quote",
    "Author",
    "State",
    "Parent",
    "Root",
    "Next actor",
    "Assignee",
    "Priority",
    "Audience",
    "Expected text",
    "Replacement text",
    "Decision by",
    "Transaction",
    "Body JSON",
)


class NeutralFormatError(ValueError):
    """A bounded failure that never includes document or body content."""

    def __init__(self, code: str, offset: int = 0) -> None:
        super().__init__(f"Neutral collaboration ledger is invalid ({code}) at byte {offset}.")
        self.code = code
        self.offset = max(0, offset)


def _scalar(value: str, *, optional: bool = False) -> str | None:
    if value == "none" and optional:
        return None
    if (
        not isinstance(value, str)
        or not value
        or value == "none"
        or "\n" in value
        or "\r" in value
        or "\x00" in value
        or len(value.encode("utf-8")) > MAX_SCALAR_BYTES
    ):
        raise ValueError("Neutral fact contains an invalid scalar field.")
    return value


def _optional(value: str | None) -> str:
    return "none" if value is None else value


def _audience(value: tuple[str, ...]) -> str:
    return "none" if not value else canonical_json(list(value)).decode("utf-8")


def _parse_audience(value: str) -> tuple[str, ...]:
    if value == "none":
        return ()
    try:
        decoded = json.loads(value)
    except json.JSONDecodeError as error:
        raise ValueError("Neutral audience must be canonical JSON or none.") from error
    if (
        not isinstance(decoded, list)
        or not decoded
        or len(decoded) > 64
        or any(not isinstance(item, str) for item in decoded)
        or canonical_json(decoded).decode("utf-8") != value
    ):
        raise ValueError("Neutral audience must be a bounded canonical string list.")
    result = tuple(_scalar(item) for item in decoded)
    if len(result) != len(set(result)):
        raise ValueError("Neutral audience contains duplicate actors.")
    return result


@dataclass(frozen=True)
class NeutralFact:
    id: str
    kind: str
    file: str
    author: str
    state: str
    root: str
    body: str
    quote: str | None = None
    parent: str | None = None
    next_actor: str | None = None
    assignee: str | None = None
    priority: str | None = None
    audience: tuple[str, ...] = ()
    expected_text: str | None = None
    replacement_text: str | None = None
    decision_by: str | None = None
    transaction: str | None = None
    extensions: tuple[tuple[str, str], ...] = field(default_factory=tuple)

    def __post_init__(self) -> None:
        if FACT_ID_PATTERN.fullmatch(self.id) is None:
            raise ValueError("Neutral fact id is invalid.")
        if self.kind not in KINDS or self.state not in STATES:
            raise ValueError("Neutral fact kind or state is invalid.")
        try:
            normalized_file = safe_relative_path(self.file)
        except ValueError as error:
            raise ValueError("Neutral fact file must be a canonical Markdown path.") from error
        if normalized_file != self.file or not self.file.lower().endswith(".md"):
            raise ValueError("Neutral fact file must be a canonical Markdown path.")
        _scalar(self.author)
        if FACT_ID_PATTERN.fullmatch(self.root) is None:
            raise ValueError("Neutral fact root id is invalid.")
        for value in (
            self.quote,
            self.next_actor,
            self.assignee,
            self.expected_text,
            self.replacement_text,
            self.decision_by,
            self.transaction,
        ):
            if value is not None:
                _scalar(value)
        if self.parent is not None and FACT_ID_PATTERN.fullmatch(self.parent) is None:
            raise ValueError("Neutral fact parent id is invalid.")
        if self.priority is not None and self.priority not in PRIORITIES:
            raise ValueError("Neutral fact priority is invalid.")
        if len(self.audience) > 64 or len(self.audience) != len(set(self.audience)):
            raise ValueError("Neutral fact audience is invalid.")
        for actor in self.audience:
            _scalar(actor)
        if not isinstance(self.body, str) or not 1 <= len(self.body.encode("utf-8")) <= MAX_BODY_BYTES:
            raise ValueError("Neutral fact body size is invalid.")
        if self.kind == "reply" and self.parent is None:
            raise ValueError("Neutral replies require a parent.")
        if self.kind != "reply" and self.parent is not None:
            raise ValueError("Only neutral replies may have a parent.")
        suggestion_values = (self.expected_text, self.replacement_text)
        if self.kind == "suggestion":
            if any(value is None for value in suggestion_values):
                raise ValueError("Neutral suggestions require expected and replacement text.")
            if self.state not in {"open", "accepted", "rejected"}:
                raise ValueError("Neutral suggestion state is invalid.")
            if self.state in {"accepted", "rejected"} and self.decision_by is None:
                raise ValueError("Decided neutral suggestions require a decision actor.")
        elif any(value is not None for value in (*suggestion_values, self.decision_by)):
            raise ValueError("Suggestion-only fields appear on another neutral fact kind.")
        extension_names = [name for name, _ in self.extensions]
        if extension_names != sorted(extension_names) or len(extension_names) != len(set(extension_names)):
            raise ValueError("Neutral extensions must have unique canonical order.")
        for name, value in self.extensions:
            if re.fullmatch(r"X-[A-Za-z0-9][A-Za-z0-9 -]{0,61}", name) is None:
                raise ValueError("Neutral extension name is invalid.")
            _scalar(value)

    def fields(self) -> dict[str, str]:
        return {
            "Kind": self.kind,
            "File": self.file,
            "Quote": _optional(self.quote),
            "Author": self.author,
            "State": self.state,
            "Parent": _optional(self.parent),
            "Root": self.root,
            "Next actor": _optional(self.next_actor),
            "Assignee": _optional(self.assignee),
            "Priority": _optional(self.priority),
            "Audience": _audience(self.audience),
            "Expected text": _optional(self.expected_text),
            "Replacement text": _optional(self.replacement_text),
            "Decision by": _optional(self.decision_by),
            "Transaction": _optional(self.transaction),
            "Body JSON": canonical_json(self.body).decode("utf-8"),
        }

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "kind": self.kind,
            "file": self.file,
            "quote": self.quote,
            "author": self.author,
            "state": self.state,
            "parent": self.parent,
            "root": self.root,
            "nextActor": self.next_actor,
            "assignee": self.assignee,
            "priority": self.priority,
            "audience": list(self.audience),
            "expectedText": self.expected_text,
            "replacementText": self.replacement_text,
            "decisionBy": self.decision_by,
            "transaction": self.transaction,
            "body": self.body,
            "extensions": {name: value for name, value in self.extensions},
        }

    @classmethod
    def from_dict(cls, value: dict[str, Any]) -> NeutralFact:
        if not isinstance(value, dict):
            raise ValueError("Neutral fact must be an object.")
        extensions = value.get("extensions", {})
        if not isinstance(extensions, dict) or any(
            not isinstance(key, str) or not isinstance(item, str)
            for key, item in extensions.items()
        ):
            raise ValueError("Neutral fact extensions must be a string map.")
        audience = value.get("audience", [])
        if not isinstance(audience, list) or any(not isinstance(item, str) for item in audience):
            raise ValueError("Neutral fact audience must be a string list.")
        return cls(
            id=value["id"],
            kind=value["kind"],
            file=value["file"],
            quote=value.get("quote"),
            author=value["author"],
            state=value["state"],
            parent=value.get("parent"),
            root=value["root"],
            next_actor=value.get("nextActor"),
            assignee=value.get("assignee"),
            priority=value.get("priority"),
            audience=tuple(audience),
            expected_text=value.get("expectedText"),
            replacement_text=value.get("replacementText"),
            decision_by=value.get("decisionBy"),
            transaction=value.get("transaction"),
            body=value["body"],
            extensions=tuple(sorted(extensions.items())),
        )


@dataclass(frozen=True)
class NeutralLedger:
    facts: tuple[NeutralFact, ...]

    def __post_init__(self) -> None:
        if len(self.facts) > MAX_FACTS:
            raise ValueError("Neutral ledger contains too many facts.")
        identifiers = [fact.id for fact in self.facts]
        if len(identifiers) != len(set(identifiers)):
            raise ValueError("Neutral ledger contains duplicate fact ids.")
        by_id = {fact.id: fact for fact in self.facts}
        for fact in self.facts:
            if fact.parent is None:
                if fact.root != fact.id:
                    raise ValueError("Neutral root fact points to another root.")
                continue
            parent = by_id.get(fact.parent)
            if parent is None or parent.root != fact.root or fact.root not in by_id:
                raise ValueError("Neutral reply graph is incomplete or inconsistent.")
            seen = {fact.id}
            cursor = fact
            while cursor.parent is not None:
                if cursor.parent in seen:
                    raise ValueError("Neutral reply graph contains a cycle.")
                seen.add(cursor.parent)
                next_parent = by_id.get(cursor.parent)
                if next_parent is None:
                    raise ValueError("Neutral reply graph contains a missing ancestor.")
                cursor = next_parent
            if cursor.id != fact.root:
                raise ValueError("Neutral reply does not terminate at its declared root.")

    def encode(self) -> bytes:
        records: list[bytes] = []
        for fact in sorted(self.facts, key=lambda item: item.id):
            fields = fact.fields()
            metadata = [
                f"{name}: {fields[name]}"
                for name in FIELD_ORDER
                if name != "Body JSON"
            ]
            metadata.extend(f"{name}: {value}" for name, value in fact.extensions)
            metadata.append(f"Body JSON: {fields['Body JSON']}")
            record = (
                f"## {fact.id}\n\n".encode("utf-8")
                + "\n".join(metadata).encode("utf-8")
            )
            records.append(record)
        raw = PREAMBLE if not records else PREAMBLE + b"\n" + b"\n\n".join(records) + b"\n"
        if len(raw) > MAX_LEDGER_BYTES:
            raise ValueError("Neutral ledger exceeds the byte bound.")
        return raw

    def to_dict(self) -> dict[str, Any]:
        return {
            "schema": NEUTRAL_FACTS_SCHEMA,
            "format": NEUTRAL_FORMAT,
            "facts": [fact.to_dict() for fact in sorted(self.facts, key=lambda item: item.id)],
        }

    @classmethod
    def from_dict(cls, value: dict[str, Any]) -> NeutralLedger:
        if value.get("schema") != NEUTRAL_FACTS_SCHEMA or value.get("format") != NEUTRAL_FORMAT:
            raise ValueError("Neutral fact projection version is unsupported.")
        facts = value.get("facts")
        if not isinstance(facts, list):
            raise ValueError("Neutral fact projection lacks a fact list.")
        ledger = cls(tuple(NeutralFact.from_dict(item) for item in facts))
        if ledger.to_dict() != value:
            raise ValueError("Neutral fact projection is not canonical.")
        return ledger

    @classmethod
    def parse(cls, raw: bytes) -> NeutralLedger:
        if len(raw) > MAX_LEDGER_BYTES:
            raise NeutralFormatError("TOO_LARGE")
        if raw == PREAMBLE:
            return cls(())
        if not raw.startswith(PREAMBLE + RECORD_PREFIX) or not raw.endswith(b"\n"):
            raise NeutralFormatError("INVALID_HEADER")
        facts: list[NeutralFact] = []
        cursor = len(PREAMBLE)
        content_end = len(raw) - 1
        while cursor < content_end:
            if len(facts) >= MAX_FACTS:
                raise NeutralFormatError("TOO_MANY_FACTS", cursor)
            prefix = RECORD_PREFIX if not facts else RECORD_SEPARATOR
            if raw[cursor : cursor + len(prefix)] != prefix:
                raise NeutralFormatError("INVALID_SEPARATOR", cursor)
            heading_start = cursor + len(prefix)
            heading_end = raw.find(b"\n", heading_start)
            if heading_end < 0 or raw[heading_end : heading_end + 2] != b"\n\n":
                raise NeutralFormatError("INVALID_RECORD", heading_start)
            try:
                identifier = raw[heading_start:heading_end].decode("utf-8")
            except UnicodeDecodeError as error:
                raise NeutralFormatError("INVALID_UTF8", heading_start) from error
            metadata_start = heading_end + 2
            next_record = raw.find(RECORD_SEPARATOR, metadata_start, content_end)
            metadata_end = content_end if next_record < 0 else next_record
            metadata_raw = raw[metadata_start:metadata_end]
            try:
                metadata_text = metadata_raw.decode("utf-8")
            except UnicodeDecodeError as error:
                raise NeutralFormatError("INVALID_UTF8", metadata_start) from error
            fields: dict[str, str] = {}
            extensions: dict[str, str] = {}
            for line in metadata_text.split("\n"):
                name, separator, value = line.partition(": ")
                if not separator or not name or not value:
                    raise NeutralFormatError("INVALID_FIELD", metadata_start)
                if name in fields or name in extensions:
                    raise NeutralFormatError("DUPLICATE_FIELD", metadata_start)
                if name in FIELD_ORDER:
                    fields[name] = value
                elif name.startswith("X-"):
                    extensions[name] = value
                else:
                    raise NeutralFormatError("UNKNOWN_FIELD", metadata_start)
            if set(fields) != set(FIELD_ORDER):
                raise NeutralFormatError("MISSING_FIELD", metadata_start)
            try:
                body = json.loads(fields["Body JSON"])
            except (TypeError, json.JSONDecodeError) as error:
                raise NeutralFormatError("BODY_JSON", metadata_start) from error
            if (
                not isinstance(body, str)
                or canonical_json(body).decode("utf-8") != fields["Body JSON"]
            ):
                raise NeutralFormatError("BODY_JSON", metadata_start)
            try:
                fact = NeutralFact(
                    id=identifier,
                    kind=fields["Kind"],
                    file=fields["File"],
                    quote=_scalar(fields["Quote"], optional=True),
                    author=fields["Author"],
                    state=fields["State"],
                    parent=_scalar(fields["Parent"], optional=True),
                    root=fields["Root"],
                    next_actor=_scalar(fields["Next actor"], optional=True),
                    assignee=_scalar(fields["Assignee"], optional=True),
                    priority=(
                        None if fields["Priority"] == "none" else fields["Priority"]
                    ),
                    audience=_parse_audience(fields["Audience"]),
                    expected_text=_scalar(fields["Expected text"], optional=True),
                    replacement_text=_scalar(fields["Replacement text"], optional=True),
                    decision_by=_scalar(fields["Decision by"], optional=True),
                    transaction=_scalar(fields["Transaction"], optional=True),
                    body=body,
                    extensions=tuple(sorted(extensions.items())),
                )
            except (KeyError, TypeError, ValueError) as error:
                raise NeutralFormatError("INVALID_FIELD", metadata_start) from error
            facts.append(fact)
            cursor = metadata_end
        try:
            ledger = cls(tuple(facts))
        except ValueError as error:
            raise NeutralFormatError("INVALID_GRAPH") from error
        if ledger.encode() != raw:
            raise NeutralFormatError("NON_CANONICAL")
        return ledger


def expected_neutral_ledger(episode: EpisodeDefinition) -> NeutralLedger:
    """Project one hidden oracle into the common representation without scoring it."""
    quotes = {
        str(event.payload["id"]): str(event.payload["quote"])
        for event in episode.events
        if event.kind == "comment_add" and event.payload.get("quote") is not None
    }
    facts: list[NeutralFact] = []
    for annotation in episode.oracle.get("annotations", []):
        properties = {
            tuple(item["path"]): item["equals"]
            for item in annotation.get("properties", [])
        }
        identifier = str(annotation["id"])
        parent = annotation.get("parentID")
        kind = "reply" if parent is not None else str(annotation.get("kind", "comment"))
        suggestion_state = properties.get(("margin:suggestion", "status"))
        state = str(annotation.get("status") or suggestion_state or "none")
        intended = properties.get(("margin:handoff", "intendedNextActors"), [])
        if not isinstance(intended, list) or any(not isinstance(item, str) for item in intended):
            raise ValueError("Neutral handoff projection has invalid intended actors.")
        decision_by = None
        if state == "accepted":
            decision_by = properties.get(("margin:suggestion", "acceptedBy", "id"))
        elif state == "rejected":
            decision_by = properties.get(("margin:suggestion", "rejectedBy", "id"))
        request_id = properties.get(("margin:transaction", "requestID"))
        extensions = () if request_id is None else (("X-Request ID", str(request_id)),)
        facts.append(NeutralFact(
            id=identifier,
            kind=kind,
            file=str(annotation["path"]),
            quote=quotes.get(identifier),
            author=str(annotation["creatorID"]),
            state=state,
            parent=None if parent is None else str(parent),
            root=str(annotation.get("rootID", identifier)),
            next_actor=intended[0] if len(intended) == 1 else None,
            assignee=properties.get(("margin:task", "assignee")),
            priority=properties.get(("margin:task", "priority")),
            audience=tuple(intended),
            expected_text=properties.get(("margin:suggestion", "expectedText")),
            replacement_text=properties.get(("margin:suggestion", "replacementText")),
            decision_by=None if decision_by is None else str(decision_by),
            transaction=properties.get(("margin:transaction", "stageID")),
            body=str(annotation["body"]),
            extensions=extensions,
        ))
    return NeutralLedger(tuple(sorted(facts, key=lambda fact: fact.id)))
