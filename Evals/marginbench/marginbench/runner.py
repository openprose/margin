"""Provider-neutral episode orchestration and a no-model reference policy."""

from __future__ import annotations

import json
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Protocol

from .controls import DEFAULT_CONTROL_PROFILE, require_implemented_profile
from .gateway import CommandRendezvous, GatewayResponse, MarginGateway, ToolPolicy
from .schema import Actor, EpisodeDefinition, EpisodeResult, HarnessEvent, RoleTask
from .scorer import score_episode


class AgentDriver(Protocol):
    def run(self, episode: EpisodeDefinition, role: RoleTask, gateway: MarginGateway) -> None: ...


def _payload(response: GatewayResponse) -> dict:
    value = response.json
    return value if isinstance(value, dict) else {}


def _result(response: GatewayResponse) -> dict:
    value = _payload(response).get("result")
    return value if isinstance(value, dict) else {}


def _revision(response: GatewayResponse) -> int:
    value = _payload(response).get("revision")
    if not isinstance(value, int):
        raise RuntimeError("Margin response omitted a revision.")
    return value


def _actual_annotation_id(response: GatewayResponse, expected: str) -> str:
    comments = _result(response).get("comments")
    for item in comments if isinstance(comments, list) else []:
        if not isinstance(item, dict):
            continue
        annotation = item.get("annotation")
        identifier = annotation.get("id") if isinstance(annotation, dict) else item.get("id")
        if isinstance(identifier, str) and (identifier == expected or identifier.endswith(expected)):
            return identifier
    raise RuntimeError(f"Expected annotation {expected} was not found.")


class ReferenceDriver:
    """A deterministic, no-model policy proving each generated task is solvable."""

    def run(self, episode: EpisodeDefinition, role: RoleTask, gateway: MarginGateway) -> None:
        reference = episode.oracle.get("reference", {})
        scenario = episode.scenario_id
        if scenario == "human_agent_relay":
            gateway.call(["review", "review.md", "--json"])
            listed = gateway.call(["comments", "list", "review.md", "--status", "all"])
            root = _actual_annotation_id(listed, reference["rootID"])
            replied = gateway.call([
                "comments", "reply", "review.md", root,
                "-m", reference["replyBody"], "--id", reference["replyID"],
                "--if-revision", str(_revision(listed)),
            ])
            gateway.call([
                "comments", "resolve", "review.md", root,
                "--if-revision", str(_revision(replied)),
            ])
            gateway.call(["comments", "list", "review.md", "--status", "all"])
            gateway.call(["comments", "validate", "review.md"])
            return

        if scenario == "agent_agent_handoff":
            if role.seat == "author":
                gateway.call([
                    "handoff", "add", "review.md", "-m", reference["handoffBody"],
                    "--id", reference["handoffID"], "--request-id", reference["requestID"],
                    "--next-actor", reference["nextActorID"],
                ])
                gateway.call(["handoff", "list", "review.md", "--json"])
            else:
                gateway.call(["handoff", "list", "review.md", "--json"])
                listed = gateway.call(["comments", "list", "review.md", "--status", "all"])
                root = _actual_annotation_id(listed, reference["handoffID"])
                replied = gateway.call([
                    "comments", "reply", "review.md", root,
                    "-m", reference["replyBody"], "--id", reference["replyID"],
                    "--if-revision", str(_revision(listed)),
                ])
                gateway.call([
                    "comments", "resolve", "review.md", root,
                    "--if-revision", str(_revision(replied)),
                ])
                gateway.call(["comments", "list", "review.md", "--status", "all"])
            return

        if scenario == "concurrent_review":
            contribution = reference[role.actor.id]
            for _ in range(3):
                added = gateway.call([
                    "comments", "add", "review.md", "-m", contribution["body"],
                    "--document", "--kind", "issue", "--id", contribution["id"],
                ])
                if added.exit_code == 0:
                    break
                if added.error_code not in {"COLLABORATION_PRECONDITION_FAILED", "REVISION_CONFLICT"}:
                    raise RuntimeError(f"Unexpected concurrent add error: {added.error_code}")
                gateway.call(["comments", "list", "review.md", "--status", "all"])
            else:
                raise RuntimeError("Concurrent comment did not converge after three attempts.")
            gateway.call(["comments", "list", "review.md", "--status", "all"])
            return

        if scenario == "suggestion_decision":
            suggestions = reference["suggestions"]
            if role.seat == "author":
                for item in suggestions:
                    gateway.call([
                        "suggest", "add", "review.md", "--quote", item["exact"],
                        "--expect", item["exact"], "--replacement", item["replacement"],
                        "-m", item["body"], "--id", item["id"],
                    ])
                gateway.call(["suggest", "list", "review.md", "--json"])
            else:
                gateway.call(["suggest", "list", "review.md", "--json"])
                gateway.call(["suggest", "accept", "review.md", suggestions[0]["id"]])
                gateway.call(["suggest", "reject", "review.md", suggestions[1]["id"]])
                gateway.call(["read", "review.md", "--json"])
                gateway.call(["comments", "validate", "review.md"])
            return

        if scenario == "suggestion_contention":
            assignments = reference["assignments"][role.actor.id]
            for item in assignments:
                for _ in range(8):
                    added = gateway.call([
                        "suggest", "add", "review.md", "--quote", item["exact"],
                        "--expect", item["exact"], "--replacement", item["replacement"],
                        "-m", item["body"], "--id", item["id"],
                    ])
                    if added.exit_code == 0:
                        break
                    if added.error_code not in {
                        "COLLABORATION_PRECONDITION_FAILED", "REVISION_CONFLICT",
                    }:
                        raise RuntimeError(
                            f"Unexpected concurrent suggestion error: {added.error_code}"
                        )
                    gateway.call(["suggest", "list", "review.md", "--json"])
                else:
                    raise RuntimeError(
                        "Concurrent suggestion did not converge after eight attempts."
                    )
            gateway.call(["suggest", "list", "review.md", "--json"])
            gateway.call(["read", "review.md", "--json"])
            return

        if scenario == "staged_multifile":
            if role.seat == "author":
                gateway.call(["workspace", "init", "."])
                gateway.call([
                    "stage", "create", ".", "--operations-file", "-",
                    "--stage-id", reference["stageID"],
                    "--request-id", reference["requestID"],
                ], stdin=json.dumps(reference["plan"], ensure_ascii=False, separators=(",", ":"), sort_keys=True))
                gateway.call(["stage", "show", ".", reference["stageID"]])
            else:
                gateway.call(["stage", "show", ".", reference["stageID"]])
                stale = gateway.call(["stage", "submit", ".", reference["stageID"]])
                if stale.error_code != "COLLABORATION_PRECONDITION_FAILED":
                    raise RuntimeError("The staged recovery fixture did not become stale.")
                gateway.call([
                    "stage", "refresh", ".", reference["stageID"],
                    "--id", reference["refreshedStageID"],
                ])
                gateway.call(["stage", "submit", ".", reference["refreshedStageID"]])
                gateway.call(["comments", "validate", "review.md"])
                gateway.call(["comments", "validate", "notes/decision.md"])
            return

        if scenario == "wide_directory_triage":
            gateway.call(["context", ".", "--json", "--brief"])
            inbox_response = gateway.call([
                "inbox", ".", "--kind", "question", "--status", "open", "--json", "--brief",
            ])
            items = _result(inbox_response).get("items")
            if not isinstance(items, list) or len(items) != 1 or not isinstance(items[0], dict):
                raise RuntimeError("The wide-directory inbox did not return exactly one item.")
            item = items[0]
            path = item.get("actionPath")
            root = item.get("rootID")
            revision = item.get("annotationRevision")
            if not isinstance(path, str) or not isinstance(root, str) or not isinstance(revision, int):
                raise RuntimeError("The wide-directory inbox item omitted an action coordinate.")
            gateway.call([
                "comments", "reply", path, root,
                "-m", reference["replyBody"], "--id", reference["replyID"],
                "--if-revision", str(revision), "--resolve",
            ])
            gateway.call(["comments", "list", path, "--thread", root, "--status", "all"])
            gateway.call(["comments", "validate", path])
            return

        if scenario == "directory_handoff":
            tradeoff_path = reference["tradeoffPath"]
            status_path = reference["statusPath"]
            if role.seat == "author":
                gateway.call(["context", ".", "--json"])
                listed = gateway.call(["comments", "list", tradeoff_path, "--status", "all"])
                human_root = _actual_annotation_id(listed, reference["humanID"])
                replied = gateway.call([
                    "comments", "reply", tradeoff_path, human_root,
                    "-m", reference["analysisBody"], "--id", reference["analysisID"],
                    "--if-revision", str(_revision(listed)),
                ])
                gateway.call([
                    "comments", "resolve", tradeoff_path, human_root,
                    "--if-revision", str(_revision(replied)),
                ])
                gateway.call([
                    "handoff", "add", status_path, "-m", reference["handoffBody"],
                    "--id", reference["handoffID"], "--request-id", reference["requestID"],
                    "--next-actor", reference["nextActorID"],
                ])
                gateway.call(["handoff", "list", ".", "--json"])
            else:
                gateway.call(["inbox", ".", "--kind", "handoff", "--status", "open", "--json"])
                listed = gateway.call(["comments", "list", status_path, "--status", "all"])
                handoff_root = _actual_annotation_id(listed, reference["handoffID"])
                replied = gateway.call([
                    "comments", "reply", status_path, handoff_root,
                    "-m", reference["acknowledgementBody"],
                    "--id", reference["acknowledgementID"],
                    "--if-revision", str(_revision(listed)),
                ])
                gateway.call([
                    "comments", "resolve", status_path, handoff_root,
                    "--if-revision", str(_revision(replied)),
                ])
                gateway.call(["context", ".", "--json"])
                gateway.call(["comments", "validate", tradeoff_path])
                gateway.call(["comments", "validate", status_path])
            return

        if scenario == "parallel_shards":
            assignment = reference[role.actor.id]
            gateway.call([
                "comments", "add", assignment["path"], "-m", assignment["body"],
                "--document", "--kind", "issue", "--id", assignment["id"],
            ])
            gateway.call(["comments", "list", assignment["path"], "--status", "all"])
            gateway.call(["comments", "validate", assignment["path"]])
            return

        if scenario == "specialist_audit":
            path = reference["path"]
            gateway.call(["read", path, "--json"])
            if role.seat == "author":
                gateway.call([
                    "comments", "add", path, "-m", reference["decisionBody"],
                    "--document", "--kind", "decision", "--id", reference["decisionID"],
                ])
            else:
                gateway.call(["comments", "list", path, "--status", "all"])
                gateway.call([
                    "comments", "add", path, "-m", reference["issueBody"],
                    "--document", "--kind", "issue", "--id", reference["issueID"],
                ])
            gateway.call(["comments", "list", path, "--status", "all"])
            gateway.call(["comments", "validate", path])
            return

        if scenario == "distributed_synthesis":
            path = reference["path"]
            if role.seat == "author":
                gateway.call([
                    "handoff", "add", path, "-m", reference["handoffBody"],
                    "--id", reference["handoffID"], "--request-id", reference["requestID"],
                    "--next-actor", reference["nextActorID"],
                ])
                gateway.call(["handoff", "list", path, "--json"])
            else:
                gateway.call(["handoff", "list", path, "--json"])
                listed = gateway.call(["comments", "list", path, "--status", "all"])
                root = _actual_annotation_id(listed, reference["handoffID"])
                replied = gateway.call([
                    "comments", "reply", path, root,
                    "-m", reference["replyBody"], "--id", reference["replyID"],
                    "--if-revision", str(_revision(listed)),
                ])
                gateway.call([
                    "comments", "resolve", path, root,
                    "--if-revision", str(_revision(replied)),
                ])
                gateway.call(["comments", "list", path, "--thread", root, "--status", "all"])
                gateway.call(["comments", "validate", path])
            return
        raise ValueError(f"Reference policy does not support {scenario}.")


def apply_harness_event(
    event: HarnessEvent,
    binary: Path,
    workspace: Path,
    event_log: Path,
    state_root: Path,
    policy: ToolPolicy,
) -> None:
    payload = event.payload
    if event.kind == "comment_add":
        actor = Actor(**payload["actor"])
        gateway = MarginGateway(
            binary, workspace, actor, "human",
            event_log=event_log,
            state_home=state_root / "shared",
            policy=policy,
        )
        arguments = [
            "comments", "add", payload["path"], "-m", payload["body"],
            "--id", payload["id"],
        ]
        if payload.get("quote"):
            arguments += ["--quote", payload["quote"]]
        else:
            arguments += ["--document"]
        if payload.get("kind"):
            arguments += ["--kind", payload["kind"]]
        response = gateway.call(arguments)
        if response.exit_code != 0:
            raise RuntimeError(f"Harness event failed: {response.error_code}")
        return
    if event.kind == "source_replace":
        path = workspace / payload["path"]
        source = path.read_text(encoding="utf-8")
        old, new = payload["old"], payload["new"]
        if source.count(old) != 1:
            raise RuntimeError("Source hook target was not unique.")
        path.write_text(source.replace(old, new), encoding="utf-8", newline="")
        return
    raise ValueError(f"Unknown harness event: {event.kind}")


def run_episode(
    episode: EpisodeDefinition,
    binary: Path,
    workspace: Path,
    driver: AgentDriver,
    *,
    candidate_id: str = "baseline",
    policy: ToolPolicy | None = None,
    control_profile: str = DEFAULT_CONTROL_PROFILE,
) -> EpisodeResult:
    require_implemented_profile(control_profile)
    started = time.perf_counter()
    policy = policy or ToolPolicy()
    episode.materialize(workspace)
    control_root = workspace.parent / ".marginbench-control"
    event_log = control_root / "events.jsonl"
    state_root = control_root / "state"
    phases = sorted({role.phase for role in episode.roles})
    for phase in phases:
        for event in episode.events:
            if event.phase == phase and event.timing == "before":
                apply_harness_event(event, binary, workspace, event_log, state_root, policy)
        roles = [role for role in episode.roles if role.phase == phase]

        def execute(role: RoleTask) -> None:
            rendezvous_spec = episode.oracle.get("commandRendezvous")
            rendezvous = (
                CommandRendezvous(
                    directory=control_root / "rendezvous",
                    command=str(rendezvous_spec["command"]),
                    target=str(rendezvous_spec["target"]),
                    participant_count=int(rendezvous_spec["participantCount"]),
                    alternate_commands=tuple(
                        str(command) for command in rendezvous_spec.get("alternateCommands", [])
                    ),
                    coordinator_role=str(rendezvous_spec.get("coordinatorRole", "author")),
                )
                if isinstance(rendezvous_spec, dict)
                else None
            )
            gateway = MarginGateway(
                binary,
                workspace,
                role.actor,
                role.seat,
                event_log=event_log,
                state_home=state_root / "shared",
                policy=policy,
                rendezvous=rendezvous,
            )
            driver.run(episode, role, gateway)

        if len(roles) == 1 or control_profile == "single-agent-margin-v1":
            for role in roles:
                execute(role)
        else:
            with ThreadPoolExecutor(max_workers=len(roles)) as pool:
                futures = [pool.submit(execute, role) for role in roles]
                for future in futures:
                    future.result()
        for event in episode.events:
            if event.phase == phase and event.timing == "after":
                apply_harness_event(event, binary, workspace, event_log, state_root, policy)
    elapsed = (time.perf_counter() - started) * 1000
    return score_episode(
        episode,
        workspace,
        binary,
        event_log,
        candidate_id=candidate_id,
        duration_ms=elapsed,
    )
