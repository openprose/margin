"""Verifiers MCP adapter for the provider-neutral Margin gateway."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from pydantic import Field
import verifiers.v1 as vf

from marginbench.gateway import MarginGateway, ToolPolicy
from marginbench.phase_identity import read_phase_identity
from marginbench.schema import Actor


_PATH_FIELDS = frozenset({
    "argv",
    "argvTemplate",
    "directFileTarget",
    "file",
    "arguments",
    "invocationTarget",
    "location",
    "path",
    "writtenTo",
})


def _workspace_relative_path(value: str, workspace: Path) -> str:
    candidate = Path(value)
    if not candidate.is_absolute():
        return value
    try:
        relative = candidate.resolve(strict=False).relative_to(workspace.resolve(strict=True))
    except (OSError, ValueError):
        return value
    rendered = relative.as_posix()
    return rendered if rendered and rendered != "." else "."


def _project_workspace_paths(value: Any, workspace: Path, field: str | None = None) -> Any:
    if isinstance(value, dict):
        return {
            key: _project_workspace_paths(item, workspace, key)
            for key, item in value.items()
        }
    if isinstance(value, list):
        return [_project_workspace_paths(item, workspace, field) for item in value]
    if isinstance(value, str) and field in _PATH_FIELDS:
        return _workspace_relative_path(value, workspace)
    return value


class MarginGatewayConfig(vf.ToolsetConfig):
    margin_binary: str
    workspace: str
    event_log: str
    state_home: str
    role: str
    actor_id: str
    actor_name: str
    actor_type: str = "software"
    identity_binding_file: str | None = None
    timeout_seconds: float = Field(30.0, gt=0, le=120)
    max_output_bytes: int = Field(1_048_576, gt=0, le=4_194_304)


class MarginGatewayToolset(vf.Toolset[MarginGatewayConfig]):
    TOOL_PREFIX = None

    @vf.tool
    def margin(
        self,
        arguments: list[str | int],
        stdin: str | dict[str, Any] | list[Any] | None = None,
    ) -> str:
        """Run one confined Margin CLI command.

        Pass argv after `margin`, for example `["context", ".", "--json"]`.
        A leading literal `"margin"` is also accepted, so copying a command from
        help does not turn an otherwise valid action into a blocked command.
        The collaborator identity is already bound. Absolute paths, parent traversal,
        GUI routes, identity overrides, oversized inputs, and non-Margin commands are
        rejected. Path fields in returned JSON use workspace-relative spelling whenever
        possible, so they can be passed back directly. The returned JSON always includes
        exitCode, stdout, stderr, and an errorCode when available. A nonzero expected
        concurrency/CAS result is data:
        inspect it and recover explicitly. For an existing thread, `context` or
        `inbox` already supplies its reusable actionPath, rootID, body preview, status,
        revision, and bounded workflowGuidance; follow the matching argv or argvTemplate
        rather than deriving a source range or guessing a command. When the reply
        is also authorized to close the concern, add `--resolve` so the reply and root
        resolution succeed or fail together. Otherwise the root remains open and can
        be resolved separately.
        Never guess a multiword command. Choose exactly one initial directory read:
        use `context . --json --max-files 16` when the brief asks for broad context,
        or `inbox . --status open --max-contributions 64` when finding open work.
        They overlap; calling both before acting wastes the agent budget.
        Use a concrete topic such as `man staging` (topics: review, comments,
        suggestions, staging, handoff, merge, safety), a concrete command such as
        `stage --help`, or a small projection such as `capabilities --json --for
        staging`. Never request the full `capabilities --json` catalog during a task:
        it is intentionally comprehensive and can exhaust a small agent budget.
        New typed work starts with `comments
        add`; proposals use `suggest add|list|accept|reject`; transfers use `handoff
        add|list`, and `--next-actor` names the recipient (`--actor-id` never does);
        coherent cross-file work uses `stage create|show|refresh|submit`.
        Read-only verification arguments differ from mutation arguments, so follow a
        successful receipt's `nextActions` rather than carrying mutation flags forward.
        When a workflow hint or next action contains `argv`, pass that complete array
        back verbatim; `arguments` alone deliberately omits the command words.
        A context hint with `executable: false` has no `argv`: it returns an
        `argvTemplate` and `requiredReplacements`. Replace every listed placeholder
        from the brief, source, or a receipt before calling the tool; never submit the
        template itself.
        JSON integer arguments are normalized to their CLI spelling, so bounded numeric
        options may be supplied as either `16` or `"16"`.
        In context output, prefer the first workflowGuidance entry that matches the task.
        """
        if self.config.identity_binding_file is not None:
            binding = read_phase_identity(Path(self.config.identity_binding_file))
            actor, role = binding.actor, binding.seat
        else:
            actor = Actor(self.config.actor_id, self.config.actor_name, self.config.actor_type)
            role = self.config.role
        gateway = MarginGateway(
            Path(self.config.margin_binary),
            Path(self.config.workspace),
            actor,
            role,
            event_log=Path(self.config.event_log),
            state_home=Path(self.config.state_home),
            policy=ToolPolicy(
                timeout_seconds=self.config.timeout_seconds,
                max_output_bytes=self.config.max_output_bytes,
            ),
        )
        # Some model providers preserve JSON-looking stdin as a string while
        # others decode it into an object before tool validation. Accept both
        # representations and normalize structured input back to bounded text.
        normalized_stdin = (
            json.dumps(stdin, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
            if isinstance(stdin, (dict, list))
            else stdin
        )
        normalized_arguments = [str(argument) for argument in arguments]
        if normalized_arguments[:1] == ["margin"]:
            normalized_arguments = normalized_arguments[1:]
        payload = gateway.call(normalized_arguments, stdin=normalized_stdin).tool_payload()
        projected = _project_workspace_paths(payload, Path(self.config.workspace))
        return json.dumps(
            projected,
            ensure_ascii=False,
            separators=(",", ":"),
            sort_keys=True,
        )


if __name__ == "__main__":
    MarginGatewayToolset.run()
