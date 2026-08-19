"""Progressively disclosed Prime tool for the plain-Markdown control."""

from __future__ import annotations

from pathlib import Path
import time

from pydantic import Field
import verifiers.v1 as vf

from marginbench.plain_gateway import (
    PlainCallEvent,
    PlainGatewayError,
    PlainProvenanceLog,
    PlainWorkspaceGateway,
)
from marginbench.schema import Actor, canonical_json


PLAIN_GATEWAY_SCHEMA = "urn:marginbench:plain-gateway:v1"

_GUIDES: dict[str, dict[str, object]] = {
    "basics": {
        "purpose": "Collaborate only through ordinary Markdown files in this workspace.",
        "actions": {
            "list": "List one bounded directory.",
            "read": "Read bounded lines and receive the whole-file SHA-256.",
            "write": "Replace one Markdown file only if its last-read SHA-256 still matches.",
        },
        "workflow": [
            "List only when you do not already know the relevant file.",
            "Read COLLABORATION.md and any source evidence you need.",
            "Preserve every existing fact, edit the ledger, then write with if_sha256.",
            "On PRECONDITION_FAILED, reread, merge by stable fact ID, and retry once.",
            "Reread the changed file to verify durable state before stopping.",
        ],
        "topics": ["facts", "suggestions", "staging"],
    },
    "facts": {
        "file": "COLLABORATION.md",
        "format": "marginbench-neutral-v2",
        "rules": [
            "Keep the exact header and field order shown below.",
            "Sort complete records by fact ID and retain all facts you did not change.",
            "Use literal none for absent optional fields.",
            "Body JSON is one canonical JSON string containing the exact Markdown body; no byte counting is required.",
            "A root has Root equal to its own ID and Parent none.",
            "A reply has Kind reply, Parent equal to its parent ID, and Root equal to the root ID.",
            "Use State open or resolved for discussion facts; resolving a thread changes every member.",
            "Put a recipient in both Next actor and the Audience JSON array for a handoff.",
            "Only names beginning X- are allowed, sorted immediately before Body JSON.",
        ],
        "fieldOrder": [
            "Kind", "File", "Quote", "Author", "State", "Parent", "Root",
            "Next actor", "Assignee", "Priority", "Audience", "Expected text",
            "Replacement text", "Decision by", "Transaction", "Body JSON",
        ],
        "recordTemplate": (
            "## FACT_ID\n\n"
            "Kind: issue\nFile: review.md\nQuote: none\nAuthor: ACTOR_ID\n"
            "State: open\nParent: none\nRoot: FACT_ID\nNext actor: none\n"
            "Assignee: none\nPriority: none\nAudience: none\nExpected text: none\n"
            "Replacement text: none\nDecision by: none\nTransaction: none\n"
            "Body JSON: \"EXACT_BODY\""
        ),
    },
    "suggestions": {
        "rules": [
            "A suggestion root uses Kind suggestion and starts with State open.",
            "Expected text and Replacement text are both required and must be exact source text.",
            "Acceptance sets State accepted and Decision by to the deciding actor, then performs the source edit with its own fresh SHA-256.",
            "Rejection sets State rejected and Decision by without changing source text.",
            "A deciding role must read the open suggestion before recording its decision.",
        ],
    },
    "staging": {
        "rules": [
            "A draft grouped fact uses State none and a shared Transaction ID.",
            "The author records the post-draft COLLABORATION.md SHA-256 in STAGE.md for the next role.",
            "The reviewer first tries that stored SHA-256 once so stale state is observable and no partial write occurs.",
            "After a stale result, reread COLLABORATION.md, preserve intervening facts, change every grouped fact together to its final state and Transaction ID, and make one CAS write.",
            "Keep STAGE.md as durable lineage evidence.",
        ],
    },
}


class PlainGatewayConfig(vf.ToolsetConfig):
    workspace: str
    state_directory: str
    provenance_path: str
    actor_id: str
    actor_name: str
    actor_type: str = "software"
    max_lines: int = Field(2_000, ge=1, le=2_000)


def _payload(value: dict[str, object]) -> str:
    return canonical_json({"schema": PLAIN_GATEWAY_SCHEMA, **value}).decode("utf-8")


class PlainGatewayToolset(vf.Toolset[PlainGatewayConfig]):
    TOOL_PREFIX = None

    @vf.tool
    def workspace(
        self,
        action: str,
        path: str = ".",
        start_line: int = 1,
        max_lines: int = 200,
        if_sha256: str | None = None,
        text: str | None = None,
        topic: str | None = None,
    ) -> str:
        """Use one confined ordinary-Markdown workspace.

        Actions are `guide`, `list`, `read`, and `write`. Begin with the smallest
        relevant guide topic (`basics`, `facts`, `suggestions`, or `staging`). A
        guide may include a path as a harmless context hint. Reads
        return a whole-file SHA-256 even when their line view is truncated. Writes
        replace exactly one existing Markdown file and require that last-read digest
        in `if_sha256`; preserve other collaborators' facts. A stale write is expected
        concurrency data: reread, merge by stable fact ID, and retry. The active actor
        identity is already bound and cannot be supplied by the caller.
        """
        provenance: PlainProvenanceLog | None = None
        started = time.perf_counter_ns()
        request_byte_count = len(canonical_json({
            "action": action,
            "path": path,
            "startLine": start_line,
            "maxLines": max_lines,
            "ifSha256": if_sha256,
            "text": text,
            "topic": topic,
        }))

        def finish(value: dict[str, object], *, error_code: str | None = None) -> str:
            rendered = _payload(value)
            if provenance is not None:
                normalized_action = (
                    action
                    if isinstance(action, str) and action in {"guide", "list", "read", "write"}
                    else "invalid"
                )
                try:
                    provenance.append_call(PlainCallEvent(
                        sequence=0,
                        actor_id=self.config.actor_id,
                        actor_type=self.config.actor_type,
                        action=normalized_action,
                        succeeded=error_code is None,
                        error_code=error_code,
                        request_byte_count=request_byte_count,
                        response_byte_count=len(rendered.encode("utf-8")),
                        duration_microseconds=min(
                            600_000_000,
                            max(0, (time.perf_counter_ns() - started) // 1_000),
                        ),
                    ))
                except PlainGatewayError as log_error:
                    if error_code is None:
                        return _payload({
                            "ok": False,
                            "action": normalized_action,
                            "error": {
                                "code": log_error.code,
                                "message": "Trusted call accounting failed.",
                            },
                        })
            return rendered

        try:
            provenance = PlainProvenanceLog(Path(self.config.provenance_path))
            provenance.call_snapshot()
            if action == "guide":
                selected = "basics" if topic is None else topic
                if (
                    selected not in _GUIDES
                    or start_line != 1
                    or max_lines != 200
                    or if_sha256 is not None
                    or text is not None
                ):
                    raise PlainGatewayError(
                        "USAGE",
                        "guide accepts only an optional known topic.",
                    )
                return finish({"ok": True, "action": action, "result": _GUIDES[selected]})

            if topic is not None:
                raise PlainGatewayError("USAGE", "topic is available only for guide.")
            gateway = PlainWorkspaceGateway(
                Path(self.config.workspace),
                Actor(self.config.actor_id, self.config.actor_name, self.config.actor_type),
                Path(self.config.state_directory),
                provenance,
            )
            if action == "list":
                if start_line != 1 or max_lines != 200 or if_sha256 is not None or text is not None:
                    raise PlainGatewayError("USAGE", "list accepts only a directory path.")
                result = gateway.list(path)
            elif action == "read":
                if if_sha256 is not None or text is not None:
                    raise PlainGatewayError("USAGE", "read does not accept write fields.")
                result = gateway.read(
                    path,
                    start_line=start_line,
                    max_lines=min(max_lines, self.config.max_lines),
                )
            elif action == "write":
                if (
                    not isinstance(text, str)
                    or not isinstance(if_sha256, str)
                    or start_line != 1
                    or max_lines != 200
                ):
                    raise PlainGatewayError(
                        "USAGE",
                        "write requires text and if_sha256 and accepts no line range.",
                    )
                result = gateway.write(path, text, if_sha256=if_sha256)
            else:
                raise PlainGatewayError(
                    "USAGE",
                    "action must be guide, list, read, or write.",
                )
            return finish({"ok": True, "action": action, "result": result})
        except PlainGatewayError as error:
            error_value: dict[str, object] = {
                "code": error.code,
                "message": str(error),
            }
            if error.details is not None:
                error_value["details"] = error.details
            return finish({
                "ok": False,
                "action": action if isinstance(action, str) else "invalid",
                "error": error_value,
            }, error_code=error.code)
        except (TypeError, ValueError):
            return finish({
                "ok": False,
                "action": action if isinstance(action, str) else "invalid",
                "error": {"code": "USAGE", "message": "Workspace request is invalid."},
            }, error_code="USAGE")


if __name__ == "__main__":
    PlainGatewayToolset.run()
