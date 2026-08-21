"""Read-only served workspace for the no-exchange control."""

from __future__ import annotations

from pathlib import Path

from pydantic import Field
import verifiers.v1 as vf

from marginbench.plain_gateway import PlainGatewayError, PlainWorkspaceGateway
from marginbench.schema import Actor, canonical_json


NO_EXCHANGE_GATEWAY_SCHEMA = "urn:marginbench:no-exchange-gateway:v1"

_GUIDE = {
    "purpose": "Inspect only your independent copy of the initial Markdown files.",
    "actions": {
        "list": "List one bounded directory in this copy.",
        "read": "Read bounded lines from one Markdown file.",
    },
    "rules": [
        "No collaborator transcript, write, comment, handoff, or later state is available.",
        "Do not infer that another role acted; answer only from your brief and initial files.",
        "This control is read-only. Submit conclusions through the benchmark response channel.",
    ],
}


class NoExchangeGatewayConfig(vf.ToolsetConfig):
    workspace: str
    state_directory: str
    actor_id: str
    actor_name: str
    actor_type: str = "software"
    max_lines: int = Field(2_000, ge=1, le=2_000)


def _payload(value: dict[str, object]) -> str:
    return canonical_json({"schema": NO_EXCHANGE_GATEWAY_SCHEMA, **value}).decode("utf-8")


class NoExchangeGatewayToolset(vf.Toolset[NoExchangeGatewayConfig]):
    TOOL_PREFIX = None

    @vf.tool
    def workspace(
        self,
        action: str,
        path: str = ".",
        start_line: int = 1,
        max_lines: int = 200,
    ) -> str:
        """Inspect one independent read-only Markdown workspace.

        Actions are `guide`, `list`, and `read`. This role receives only its own
        copy of the initial files. There is no write action and no collaborator
        state, transcript, presence, comments, suggestions, stages, or handoffs.
        """
        try:
            if action == "guide":
                if path != "." or start_line != 1 or max_lines != 200:
                    raise PlainGatewayError("USAGE", "guide accepts no additional fields.")
                return _payload({"ok": True, "action": action, "result": _GUIDE})
            gateway = PlainWorkspaceGateway(
                Path(self.config.workspace),
                Actor(
                    self.config.actor_id,
                    self.config.actor_name,
                    self.config.actor_type,
                ),
                Path(self.config.state_directory),
            )
            if action == "list":
                if start_line != 1 or max_lines != 200:
                    raise PlainGatewayError("USAGE", "list accepts only a directory path.")
                result = gateway.list(path)
            elif action == "read":
                result = gateway.read(
                    path,
                    start_line=start_line,
                    max_lines=min(max_lines, self.config.max_lines),
                )
            elif action == "write":
                raise PlainGatewayError(
                    "READ_ONLY",
                    "The no-exchange control has no write or collaboration channel.",
                )
            else:
                raise PlainGatewayError("USAGE", "action must be guide, list, or read.")
            return _payload({"ok": True, "action": action, "result": result})
        except PlainGatewayError as error:
            return _payload({
                "ok": False,
                "action": action if isinstance(action, str) else "invalid",
                "error": {"code": error.code, "message": str(error)},
            })
        except (TypeError, ValueError):
            return _payload({
                "ok": False,
                "action": action if isinstance(action, str) else "invalid",
                "error": {"code": "USAGE", "message": "Workspace request is invalid."},
            })


if __name__ == "__main__":
    NoExchangeGatewayToolset.run()
