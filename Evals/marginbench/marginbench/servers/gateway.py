"""Verifiers MCP adapter for the provider-neutral Margin gateway."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from pydantic import Field
import verifiers.v1 as vf

from marginbench.gateway import MarginGateway, ToolPolicy
from marginbench.schema import Actor


class MarginGatewayConfig(vf.ToolsetConfig):
    margin_binary: str
    workspace: str
    event_log: str
    state_home: str
    role: str
    actor_id: str
    actor_name: str
    actor_type: str = "software"
    timeout_seconds: float = Field(30.0, gt=0, le=120)
    max_output_bytes: int = Field(1_048_576, gt=0, le=4_194_304)


class MarginGatewayToolset(vf.Toolset[MarginGatewayConfig]):
    TOOL_PREFIX = None

    @vf.tool
    def margin(
        self,
        arguments: list[str],
        stdin: str | dict[str, Any] | list[Any] | None = None,
    ) -> str:
        """Run one confined Margin CLI command.

        Pass argv after `margin`, for example `["context", ".", "--json"]`.
        The collaborator identity is already bound. Absolute paths, parent traversal,
        GUI routes, identity overrides, oversized inputs, and non-Margin commands are
        rejected. The returned JSON always includes exitCode, stdout, stderr, and an
        errorCode when available. A nonzero expected concurrency/CAS result is data:
        inspect it and recover explicitly. For an existing thread, `context` or
        `inbox` already supplies its path, rootID, body preview, status, and revision;
        reply with rootID directly rather than deriving a source range. Replying never
        resolves the root, so resolve separately when the assigned work requires it.
        Never guess a multiword command. Use a concrete topic such as `man staging`
        (topics: review, comments, suggestions, staging, handoff, merge, safety), a
        concrete command such as `stage --help`, or `capabilities --json --for staging`.
        New typed work starts with `comments
        add`; proposals use `suggest add|list|accept|reject`; transfers use `handoff
        add|list`; coherent cross-file work uses `stage create|show|refresh|submit`.
        Read-only verification arguments differ from mutation arguments, so follow a
        successful receipt's `nextActions` rather than carrying mutation flags forward.
        """
        gateway = MarginGateway(
            Path(self.config.margin_binary),
            Path(self.config.workspace),
            Actor(self.config.actor_id, self.config.actor_name, self.config.actor_type),
            self.config.role,
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
        return json.dumps(
            gateway.call(arguments, stdin=normalized_stdin).tool_payload(),
            ensure_ascii=False,
            separators=(",", ":"),
            sort_keys=True,
        )


if __name__ == "__main__":
    MarginGatewayToolset.run()
