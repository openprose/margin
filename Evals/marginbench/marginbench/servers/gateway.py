"""Verifiers MCP adapter for the provider-neutral Margin gateway."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from pydantic import Field
import verifiers.v1 as vf

from marginbench.gateway import CommandRendezvous, MarginGateway, ToolPolicy
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
    rendezvous_directory: str | None = None
    rendezvous_command: str | None = None
    rendezvous_alternate_commands: list[str] = Field(default_factory=list, max_length=8)
    rendezvous_target: str | None = None
    rendezvous_participant_count: int = Field(0, ge=0, le=32)
    rendezvous_coordinator_role: str = "author"


class MarginGatewayToolset(vf.Toolset[MarginGatewayConfig]):
    TOOL_PREFIX = None

    @vf.tool
    def margin(
        self,
        arguments: list[str | int],
        stdin: str | dict[str, Any] | list[Any] | None = None,
    ) -> str:
        """Run one confined Margin CLI command.

        Pass argv after `margin`. A leading literal `"margin"` is also accepted,
        so a command copied from help remains valid. Start with `["--help"]` or
        `["man", "agents"]` when the candidate's interface is unfamiliar, then
        follow that candidate's own focused help, returned guidance, and receipts.
        The collaborator identity is already bound. Absolute paths, parent traversal,
        GUI routes, identity overrides, oversized inputs, and non-Margin commands are
        rejected. Path fields in returned JSON use workspace-relative spelling whenever
        possible, so they can be passed back directly. The returned JSON always includes
        exitCode, stdout, stderr, and an errorCode when available. A nonzero expected
        concurrency result is data: inspect it and use the candidate's documented
        recovery path. Never guess a multiword command or submit an unfilled template.
        When output contains executable `argv`, pass that complete array back verbatim;
        replace every declared placeholder in an `argvTemplate` before using it.
        JSON integer arguments are normalized to their CLI spelling, so bounded numeric
        options may be supplied as either `16` or `"16"`.
        """
        if self.config.identity_binding_file is not None:
            binding = read_phase_identity(Path(self.config.identity_binding_file))
            actor, role = binding.actor, binding.seat
        else:
            actor = Actor(self.config.actor_id, self.config.actor_name, self.config.actor_type)
            role = self.config.role
        rendezvous = (
            CommandRendezvous(
                directory=Path(self.config.rendezvous_directory),
                command=self.config.rendezvous_command,
                target=self.config.rendezvous_target,
                participant_count=self.config.rendezvous_participant_count,
                alternate_commands=tuple(self.config.rendezvous_alternate_commands),
                coordinator_role=self.config.rendezvous_coordinator_role,
            )
            if (
                self.config.rendezvous_directory is not None
                and self.config.rendezvous_command is not None
                and self.config.rendezvous_target is not None
                and self.config.rendezvous_participant_count > 0
            )
            else None
        )
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
            rendezvous=rendezvous,
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
