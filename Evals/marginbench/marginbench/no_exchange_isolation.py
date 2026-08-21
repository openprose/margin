"""No-model served proof for independent no-exchange role workspaces."""

from __future__ import annotations

import asyncio
import os
import secrets
import stat
import tempfile
import time
from contextlib import AsyncExitStack, contextmanager
from pathlib import Path
from typing import Iterator

from mcp import ClientSession
from mcp.client.streamable_http import streamable_http_client
from verifiers.v1.mcp import serve_shared

from .entropy import PUBLIC_DEVELOPMENT_KEY
from .no_exchange import NO_EXCHANGE_PROFILE
from .scenarios import SCENARIO_IDS, generate_episode
from .schema import EpisodeDefinition, canonical_json, sha256_bytes
from .servers.no_exchange_gateway import (
    NoExchangeGatewayConfig,
    NoExchangeGatewayToolset,
)


NO_EXCHANGE_ISOLATION_SCHEMA = "urn:marginbench:no-exchange-isolation-preflight:v1"


@contextmanager
def _source_import_path() -> Iterator[None]:
    package_root = Path(__file__).resolve().parent.parent
    previous = os.environ.get("PYTHONPATH")
    values = [str(package_root)]
    if previous:
        values.append(previous)
    os.environ["PYTHONPATH"] = os.pathsep.join(values)
    try:
        yield
    finally:
        if previous is None:
            os.environ.pop("PYTHONPATH", None)
        else:
            os.environ["PYTHONPATH"] = previous


def _secure_tree(root: Path) -> None:
    for path in sorted(root.rglob("*")):
        status = path.lstat()
        if stat.S_ISLNK(status.st_mode):
            raise ValueError("Initial no-exchange workspace contains a symlink.")
        path.chmod(0o700 if path.is_dir() else 0o600)
    root.chmod(0o700)


def _snapshot(episode: EpisodeDefinition, workspace: Path) -> dict[str, tuple[str, int, int]]:
    result: dict[str, tuple[str, int, int]] = {}
    for relative, expected in sorted(episode.files.items()):
        path = workspace / relative
        status = path.lstat()
        if not stat.S_ISREG(status.st_mode) or status.st_nlink != 1:
            raise ValueError("No-exchange initial file is not an independent regular file.")
        raw = path.read_bytes()
        if raw != expected.encode("utf-8"):
            raise ValueError("No-exchange initial file bytes changed during materialization.")
        result[relative] = (sha256_bytes(raw), status.st_dev, status.st_ino)
    return result


def materialize_independent_workspaces(
    episode: EpisodeDefinition,
    root: Path,
) -> tuple[dict[str, Path], dict[str, dict[str, tuple[str, int, int]]]]:
    """Create one inode-independent, private initial workspace for every role."""
    workspaces: dict[str, Path] = {}
    snapshots: dict[str, dict[str, tuple[str, int, int]]] = {}
    for role in sorted(episode.roles, key=lambda item: (item.phase, item.seat)):
        workspace = root / "roles" / role.seat / "workspace"
        episode.materialize(workspace)
        _secure_tree(workspace)
        workspaces[role.seat] = workspace
        snapshots[role.seat] = _snapshot(episode, workspace)
    if len(workspaces) != len(episode.roles):
        raise ValueError("No-exchange roles require unique seats.")
    return workspaces, snapshots


async def _call(session: ClientSession, **arguments: object) -> dict[str, object]:
    result = await session.call_tool("workspace", arguments)
    if result.isError or not result.content:
        raise RuntimeError("No-exchange served tool returned a transport error.")
    import json

    payload = json.loads(result.content[0].text)
    if not isinstance(payload, dict):
        raise RuntimeError("No-exchange served tool returned a non-object payload.")
    return payload


async def _probe_role(
    episode: EpisodeDefinition,
    role,
    workspace: Path,
    state: Path,
    transcript_path: Path,
    other_workspace: Path | None,
) -> dict[str, bool]:
    escape = workspace / "escape.md"
    if other_workspace is not None:
        first_other = other_workspace / sorted(episode.files)[0]
        escape.symlink_to(first_other)
    toolset = NoExchangeGatewayToolset(NoExchangeGatewayConfig(
        workspace=str(workspace),
        state_directory=str(state),
        actor_id=role.actor.id,
        actor_name=role.actor.name,
        actor_type=role.actor.type,
    ))
    async with serve_shared([toolset], harness_is_local=True) as servers:
        async with AsyncExitStack() as stack:
            read, write, *_ = await stack.enter_async_context(
                streamable_http_client(servers[""].url)
            )
            session = await stack.enter_async_context(ClientSession(read, write))
            await session.initialize()
            tools = await session.list_tools()
            names = [tool.name for tool in tools.tools]
            guide = await _call(session, action="guide")
            listing = await _call(session, action="list")
            opened = await _call(session, action="read", path=sorted(episode.files)[0])
            traversal = await _call(
                session, action="read", path="../control/transcripts/private.md",
            )
            absolute = await _call(session, action="read", path=str(transcript_path))
            forbidden = await _call(session, action="write")
            symlink = (
                await _call(session, action="read", path="escape.md")
                if other_workspace is not None
                else {"ok": False, "error": {"code": "SYMLINK_BLOCKED"}}
            )
    escape.unlink(missing_ok=True)
    return {
        "singleReadOnlyTool": names == ["workspace"],
        "guideAvailable": guide.get("ok") is True,
        "initialFilesReadable": (
            listing.get("ok") is True and opened.get("ok") is True
        ),
        "pathEscapeBlocked": (
            traversal.get("ok") is False
            and traversal.get("error", {}).get("code") == "UNSAFE_PATH"
            and absolute.get("ok") is False
            and absolute.get("error", {}).get("code") == "UNSAFE_PATH"
        ),
        "writeChannelAbsent": (
            forbidden.get("ok") is False
            and forbidden.get("error", {}).get("code") == "READ_ONLY"
        ),
        "symlinkEscapeBlocked": (
            symlink.get("ok") is False
            and symlink.get("error", {}).get("code") == "SYMLINK_BLOCKED"
        ),
    }


async def _run(
    scenarios: tuple[str, ...], repetitions: int, key: bytes,
) -> dict[str, object]:
    started = time.perf_counter()
    assessments: list[dict[str, object]] = []
    role_workspace_count = 0
    served_session_count = 0
    with _source_import_path():
        for repetition in range(repetitions):
            for scenario in scenarios:
                episode = generate_episode(scenario, key, repetition)
                with tempfile.TemporaryDirectory(prefix="marginbench-no-exchange-") as temporary:
                    root = Path(temporary)
                    control = root / "control"
                    transcripts = control / "transcripts"
                    states = control / "states"
                    transcripts.mkdir(mode=0o700, parents=True)
                    states.mkdir(mode=0o700)
                    workspaces, snapshots = materialize_independent_workspaces(episode, root)
                    roles = sorted(episode.roles, key=lambda item: (item.phase, item.seat))
                    canaries: dict[str, bytes] = {}
                    for role in roles:
                        canary = secrets.token_bytes(32)
                        canaries[role.seat] = canary
                        (transcripts / f"{role.seat}.private.md").write_bytes(canary)
                        (transcripts / f"{role.seat}.private.md").chmod(0o600)

                    inode_sets = {
                        relative: {
                            snapshots[role.seat][relative][1:]
                            for role in roles
                        }
                        for relative in episode.files
                    }
                    checks = {
                        "distinctWorkspaceRoots": len({
                            workspace.resolve() for workspace in workspaces.values()
                        }) == len(workspaces),
                        "distinctFileInodes": all(
                            len(values) == len(workspaces) for values in inode_sets.values()
                        ),
                        "identicalInitialBytes": all(
                            snapshots[role.seat][relative][0]
                            == sha256_bytes(body.encode("utf-8"))
                            for role in roles
                            for relative, body in episode.files.items()
                        ),
                        "privateStateOutsideWorkspaces": all(
                            not str(transcripts.resolve()).startswith(
                                str(workspaces[role.seat].resolve()) + os.sep
                            )
                            and not str(states.resolve()).startswith(
                                str(workspaces[role.seat].resolve()) + os.sep
                            )
                            for role in roles
                        ),
                        "noCollaborationMetadata": all(
                            not (workspace / ".margin").exists()
                            and not (workspace / "COLLABORATION.md").exists()
                            and not (workspace / "STAGE.md").exists()
                            for workspace in workspaces.values()
                        ),
                        "transcriptCanariesAbsent": all(
                            canary not in path.read_bytes()
                            for canary in canaries.values()
                            for workspace in workspaces.values()
                            for path in workspace.rglob("*.md")
                        ),
                    }

                    for role in roles:
                        others = [item for item in roles if item.seat != role.seat]
                        probe = await _probe_role(
                            episode,
                            role,
                            workspaces[role.seat],
                            states / role.seat,
                            transcripts / f"{role.seat}.private.md",
                            workspaces[others[0].seat] if others else None,
                        )
                        for name, value in probe.items():
                            checks[name] = checks.get(name, True) and value
                        served_session_count += 1

                    if len(roles) > 1:
                        first_role, second_role = roles[:2]
                        relative = sorted(episode.files)[0]
                        first_path = workspaces[first_role.seat] / relative
                        second_path = workspaces[second_role.seat] / relative
                        second_before = second_path.read_bytes()
                        first_path.write_bytes(first_path.read_bytes() + b"\n<!-- isolated -->\n")
                        checks["oneSidedMutationIsolated"] = (
                            second_path.read_bytes() == second_before
                            and first_path.read_bytes() != second_before
                        )
                    else:
                        checks["oneSidedMutationIsolated"] = True

                    role_workspace_count += len(roles)
                    assessments.append({
                        "scenario": scenario,
                        "repetition": repetition,
                        "roleWorkspaceCount": len(roles),
                        "fileCopyCount": len(roles) * len(episode.files),
                        "checks": dict(sorted(checks.items())),
                        "passed": all(checks.values()),
                    })

    passed = all(item["passed"] for item in assessments)
    receipt = {
        "schema": NO_EXCHANGE_ISOLATION_SCHEMA,
        "passed": passed,
        "paidModelsInvoked": False,
        "controlProfile": NO_EXCHANGE_PROFILE,
        "controlRunnable": False,
        "component": "served-independent-workspace-proof",
        "toolSurface": ["workspace"],
        "allowedActions": ["guide", "list", "read"],
        "rawPromptsRetained": False,
        "rawTranscriptsRetained": False,
        "scenarioCount": len(scenarios),
        "repetitionCount": repetitions,
        "assessmentCount": len(assessments),
        "roleWorkspaceCount": role_workspace_count,
        "servedSessionCount": served_session_count,
        "durationMs": round((time.perf_counter() - started) * 1_000, 3),
        "assessments": assessments,
        "nextBlockingGate": "integrated-no-exchange-profile-runner",
    }
    canonical_json(receipt)
    return receipt


def run_no_exchange_isolation_preflight(
    *,
    scenarios: list[str] | tuple[str, ...] = SCENARIO_IDS,
    repetitions: int = 1,
    key: bytes = PUBLIC_DEVELOPMENT_KEY,
) -> dict[str, object]:
    selected = tuple(scenarios)
    if (
        not 1 <= repetitions <= 5
        or not selected
        or len(selected) > len(SCENARIO_IDS)
        or len(selected) != len(set(selected))
        or any(scenario not in SCENARIO_IDS for scenario in selected)
        or not isinstance(key, bytes)
        or len(key) < 16
    ):
        raise ValueError("No-exchange isolation preflight selection is invalid.")
    return asyncio.run(_run(selected, repetitions, key))
