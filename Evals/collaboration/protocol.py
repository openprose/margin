#!/usr/bin/env python3
"""Deterministic, model-free collaboration protocol checks."""

from __future__ import annotations

import json
import tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Any, Callable

from eval_lib import (
    CommandResult,
    EvalError,
    Scenario,
    assert_no_raw_values,
    command_evidence,
    missing_capabilities,
    run_command,
    sha256_bytes,
    sha256_text,
)
from scenarios import GeneratedCase, generate_case


OPENING = b"<!-- margin:comments:v1\n"
CLOSING = b"\n-->"


class ProtocolCase:
    def __init__(self, binary: Path, generated: GeneratedCase, workspace: Path):
        self.binary = binary
        self.generated = generated
        self.workspace = workspace
        self.commands: list[dict[str, Any]] = []

    def call(
        self,
        arguments: list[str],
        timeout: float = 30,
        stdin: bytes | None = None,
    ) -> CommandResult:
        result = run_command(
            self.binary,
            arguments,
            cwd=self.workspace,
            timeout=timeout,
            stdin=stdin,
        )
        self.commands.append(command_evidence(result, self.workspace))
        return result

    def record(self, result: CommandResult) -> None:
        self.commands.append(command_evidence(result, self.workspace))

    def document(self, relative: str = "review.md") -> Path:
        return self.workspace / relative

    @staticmethod
    def actor_flags(actor_id: str, actor_name: str) -> list[str]:
        return ["--actor-id", actor_id, "--actor-name", actor_name, "--actor-type", "software"]

    def add(
        self,
        relative: str,
        body: str,
        identifier: str,
        actor_id: str,
        actor_name: str,
        *,
        quote: str | None = None,
        revision: int | None = None,
        content_sha: str | None = None,
    ) -> CommandResult:
        arguments = ["comments", "add", str(self.document(relative)), "-m", body]
        arguments += ["--quote", quote] if quote else ["--document"]
        arguments += ["--id", identifier, *self.actor_flags(actor_id, actor_name)]
        if revision is not None:
            arguments += ["--if-revision", str(revision)]
        if content_sha is not None:
            arguments += ["--if-content-sha", content_sha]
        return self.call(arguments)

    def list(self, relative: str = "review.md") -> CommandResult:
        return self.call(["comments", "list", str(self.document(relative)), "--status", "all"])

    def read(self, relative: str = "review.md") -> CommandResult:
        return self.call(["read", str(self.document(relative)), "--json"])

    def validate(self, relative: str = "review.md") -> CommandResult:
        return self.call(["comments", "validate", str(self.document(relative))])


def _payload(result: CommandResult) -> dict[str, Any]:
    value = result.json
    return value if isinstance(value, dict) else {}


def _result(result: CommandResult) -> dict[str, Any]:
    value = _payload(result).get("result")
    return value if isinstance(value, dict) else {}


def _comments(result: CommandResult) -> list[dict[str, Any]]:
    value = _result(result).get("comments")
    return [item for item in value if isinstance(item, dict)] if isinstance(value, list) else []


def _annotation(item: dict[str, Any]) -> dict[str, Any]:
    value = item.get("annotation")
    return value if isinstance(value, dict) else {}


def _body(item: dict[str, Any]) -> str:
    body = _annotation(item).get("body")
    return str(body.get("value", "")) if isinstance(body, dict) else ""


def _annotation_id(item: dict[str, Any]) -> str:
    return str(_annotation(item).get("id", ""))


def _creator_id(item: dict[str, Any]) -> str:
    creator = _annotation(item).get("creator")
    return str(creator.get("id", "")) if isinstance(creator, dict) else ""


def _id_matches(actual: str, expected: str) -> bool:
    return actual == expected or actual.endswith(expected.lower())


def _logical_body(result: CommandResult) -> str | None:
    body = _result(result).get("body")
    return body if isinstance(body, str) else None


def _source_hashes(case: ProtocolCase, relatives: list[str]) -> dict[str, str | None]:
    hashes: dict[str, str | None] = {}
    for relative in relatives:
        read = case.read(relative)
        body = _logical_body(read)
        hashes[relative] = sha256_text(body) if body is not None else None
    return hashes


def _decode_envelope(path: Path) -> tuple[bytes, dict[str, Any]]:
    data = path.read_bytes()
    marker = data.find(OPENING)
    if marker < 0 or not (data.endswith(b"\n-->\n") or data.endswith(b"\n-->")):
        raise EvalError("Expected an embedded Margin envelope.")
    payload_start = marker + len(OPENING)
    closing_start = data.rfind(CLOSING)
    try:
        envelope = json.loads(data[payload_start:closing_start].decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise EvalError("Could not decode embedded Margin envelope.") from error
    if not isinstance(envelope, dict):
        raise EvalError("Embedded Margin envelope is not an object.")
    content_length = envelope.get("margin:contentByteLength")
    if not isinstance(content_length, int) or content_length < 0 or content_length > marker:
        raise EvalError("Embedded Margin envelope has an invalid content length.")
    return data[:content_length], envelope


def _encode_envelope(path: Path, body: bytes, envelope: dict[str, Any]) -> None:
    envelope["margin:contentByteLength"] = len(body)
    envelope["margin:contentSha256"] = sha256_bytes(body)
    payload = json.dumps(envelope, ensure_ascii=False, indent=2, sort_keys=True).encode("utf-8")
    if b"--" in payload:
        raise EvalError("Synthetic envelope unexpectedly contains an unsafe HTML-comment sequence.")
    padding = b"" if body.endswith(b"\n\n") or not body else (b"\n" if body.endswith(b"\n") else b"\n\n")
    path.write_bytes(body + padding + OPENING + payload + b"\n-->\n")


def _inject_unknown_extension(path: Path, fingerprint: str) -> str:
    body, envelope = _decode_envelope(path)
    value = sha256_text(fingerprint)[-24:]
    envelope["urn:margin:eval:unknown"] = {"opaque": value, "version": 7}
    _encode_envelope(path, body, envelope)
    return value


def _unknown_extension(path: Path) -> Any:
    _, envelope = _decode_envelope(path)
    return envelope.get("urn:margin:eval:unknown")


def _rewrite_source(path: Path, old: str, new: str) -> None:
    body, envelope = _decode_envelope(path)
    source = body.decode("utf-8")
    if source.count(old) != 1:
        raise EvalError("Synthetic drift target was not unique.")
    _encode_envelope(path, source.replace(old, new).encode("utf-8"), envelope)


def _rewrite_source_out_of_band(path: Path, old: str, new: str) -> None:
    """Change logical Markdown while preserving the exact stale envelope suffix."""
    data = path.read_bytes()
    body, _ = _decode_envelope(path)
    source = body.decode("utf-8")
    if source.count(old) != 1:
        raise EvalError("Synthetic out-of-band drift target was not unique.")
    replacement = source.replace(old, new).encode("utf-8")
    path.write_bytes(replacement + data[len(body):])


def _all_expected_comments(items: list[dict[str, Any]], bodies: list[str]) -> bool:
    actual = [_body(item) for item in items]
    return all(actual.count(body) == 1 for body in bodies)


def _valid(case: ProtocolCase, relative: str = "review.md") -> bool:
    result = case.validate(relative)
    return result.exit_code == 0 and _result(result).get("valid") is True


def _human_agent_relay(case: ProtocolCase) -> dict[str, bool]:
    setup = case.generated.human_setup[0]
    human = case.add(
        "review.md", setup["body"], setup["id"], setup["actorID"], setup["actorName"],
        quote=setup["quote"], revision=0,
    )
    if human.exit_code != 0:
        return {"human_seed": False}
    root_id = str(_result(human).get("rootID", ""))
    unknown_value = _inject_unknown_extension(case.document(), case.generated.fingerprint)
    listed = case.list()
    revision = _payload(listed).get("revision")
    agent = case.generated.tasks[0]
    body = case.generated.expected["commentBodies"][1]
    reply_id = case.generated.expected.get("commentIDs", [None, None])[-1]
    if not isinstance(reply_id, str) or reply_id == setup["id"]:
        reply_id = case.generated.fingerprint[-36:].replace(":", "0")[:36]
    reply = case.call([
        "comments", "reply", str(case.document()), root_id, "-m", body,
        "--id", reply_id, *case.actor_flags(agent.actor_id, agent.actor_name),
        "--if-revision", str(revision),
    ])
    reply_revision = _payload(reply).get("revision")
    resolved = case.call([
        "comments", "resolve", str(case.document()), root_id,
        *case.actor_flags(agent.actor_id, agent.actor_name),
        "--if-revision", str(reply_revision),
    ])
    stale = case.add(
        "review.md", "stale mutation probe", "00000000-0000-4000-8000-00000000cafe",
        agent.actor_id, agent.actor_name, revision=0,
    )
    final = case.list()
    items = _comments(final)
    source = _source_hashes(case, ["review.md"])["review.md"]
    extension = _unknown_extension(case.document())
    return {
        "cas_rejects_stale": stale.error_code == "REVISION_CONFLICT",
        "embedded_tree": reply.exit_code == 0 and len(items) == 2 and _all_expected_comments(items, case.generated.expected["commentBodies"]),
        "ordinary_markdown": source == case.generated.expected["logicalSourceSha256"]["review.md"],
        "resolved": resolved.exit_code == 0 and all(item.get("threadStatus") == "resolved" for item in items),
        "unknown_fields_round_trip": extension == {"opaque": unknown_value, "version": 7},
        "valid": _valid(case),
    }


def _agent_agent_handoff(case: ProtocolCase) -> dict[str, bool]:
    first, second = case.generated.tasks
    first_body, second_body = case.generated.expected["commentBodies"]
    first_id, second_id = case.generated.expected["commentIDs"]
    request_id = f"{first_id}-handoff"
    handoff_arguments = [
        "handoff", "add", str(case.document()), "-m", first_body,
        "--id", first_id,
        "--next-actor", second.actor_id,
        "--request-id", request_id,
        *case.actor_flags(first.actor_id, first.actor_name),
    ]
    added = case.call(handoff_arguments)
    replay = case.call(handoff_arguments)
    projected = case.call(["handoff", "list", str(case.document()), "--json"])
    handoffs = _result(projected).get("handoffs")
    listed_before_reply = case.list()
    listed_items = _comments(listed_before_reply)
    root_id = next(
        (_annotation_id(item) for item in listed_items if _id_matches(_annotation_id(item), first_id)),
        "",
    )
    revision = _payload(listed_before_reply).get("revision")
    replied = case.call([
        "comments", "reply", str(case.document()), root_id, "-m", second_body,
        "--id", second_id, *case.actor_flags(second.actor_id, second.actor_name),
        "--if-revision", str(revision),
    ])
    reply_revision = _payload(replied).get("revision")
    resolved = case.call([
        "comments", "resolve", str(case.document()), root_id,
        *case.actor_flags(second.actor_id, second.actor_name), "--if-revision", str(reply_revision),
    ])
    final = case.list()
    items = _comments(final)
    creators = {_creator_id(item) for item in items}
    handoff = next((
        item for item in handoffs
        if isinstance(item, dict) and _id_matches(str(item.get("id", "")), first_id)
    ), {}) if isinstance(handoffs, list) else {}
    replay_transaction = _result(replay).get("transaction")
    return {
        "distinct_actors": first.actor_id in creators and second.actor_id in creators,
        "typed_handoff_projection": (
            added.exit_code == 0
            and projected.exit_code == 0
            and isinstance(handoff, dict)
            and second.actor_id in handoff.get("intendedNextActors", [])
            and str(handoff.get("startingCursor", "")).startswith("mcur1:")
        ),
        "handoff_tree": len(items) == 2 and _all_expected_comments(items, [first_body, second_body]),
        "idempotent_replay": (
            replay.exit_code == 0
            and isinstance(replay_transaction, dict)
            and replay_transaction.get("disposition") == "already-applied"
            and len(listed_items) == 1
        ),
        "resolved_with_cas": resolved.exit_code == 0,
        "source_preserved": _source_hashes(case, ["review.md"])["review.md"] == case.generated.expected["logicalSourceSha256"]["review.md"],
        "valid": _valid(case),
    }


def _concurrent_agents(case: ProtocolCase) -> dict[str, bool]:
    first, second = case.generated.tasks
    bodies = case.generated.expected["commentBodies"]
    identifiers = case.generated.expected["commentIDs"]

    def invoke(index: int) -> CommandResult:
        task = (first, second)[index]
        arguments = [
            "comments", "add", str(case.document()), "-m", bodies[index], "--document",
            "--id", identifiers[index], *case.actor_flags(task.actor_id, task.actor_name),
            "--if-revision", "0",
        ]
        return run_command(case.binary, arguments, cwd=case.workspace, timeout=30)

    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(invoke, (0, 1)))
    for result in results:
        case.record(result)
    successes = [index for index, result in enumerate(results) if result.exit_code == 0]
    conflicts = [index for index, result in enumerate(results) if result.error_code in {"REVISION_CONFLICT", "CONCURRENT_MODIFICATION"}]
    recovered = True
    if len(successes) == 1 and len(conflicts) == 1:
        current = case.list()
        revision = _payload(current).get("revision")
        loser = conflicts[0]
        task = (first, second)[loser]
        retry = case.add(
            "review.md", bodies[loser], identifiers[loser], task.actor_id, task.actor_name,
            revision=int(revision),
        )
        recovered = retry.exit_code == 0
    final = case.list()
    items = _comments(final)
    sources = _source_hashes(case, ["review.md", "notes/companion.md"])
    return {
        "concurrent_conflict_observed": len(successes) == 1 and len(conflicts) == 1,
        "no_lost_update": recovered and len(items) == 2 and _all_expected_comments(items, bodies),
        "other_file_untouched": sources["notes/companion.md"] == case.generated.expected["logicalSourceSha256"]["notes/companion.md"],
        "source_preserved": sources["review.md"] == case.generated.expected["logicalSourceSha256"]["review.md"],
        "valid": _valid(case),
    }


def _source_drift(case: ProtocolCase) -> dict[str, bool]:
    first, second = case.generated.tasks
    first_body, second_body = case.generated.expected["commentBodies"]
    first_id, second_id = case.generated.expected["commentIDs"]
    old = case.generated.expected["driftFrom"]
    new = case.generated.expected["driftTo"]
    added = case.add("review.md", first_body, first_id, first.actor_id, first.actor_name, quote=old, revision=0)
    root_id = str(_result(added).get("rootID", ""))
    previous = case.document("previous.md")
    previous.write_bytes(case.document().read_bytes())
    _rewrite_source_out_of_band(case.document(), old, new)
    drifted_bytes = case.document().read_bytes()
    analysis_result = case.call([
        "reconcile", str(case.document()), "--from", str(previous), "--json",
    ])
    analysis = _result(analysis_result).get("analysis")
    anchors = analysis.get("anchors") if isinstance(analysis, dict) else None
    strict = case.call([
        "reconcile", str(case.document()), "--from", str(previous),
        "--apply", "--policy", "require-all", "--json",
    ])
    strict_preserved_bytes = case.document().read_bytes() == drifted_bytes
    preserve = case.call([
        "reconcile", str(case.document()), "--from", str(previous),
        "--apply", "--policy", "preserve-unresolved", "--json",
    ])
    drifted = case.list()
    drift_items = _comments(drifted)
    anchor_states = [
        item.get("anchor", {}).get("state")
        for item in drift_items
        if isinstance(item.get("anchor"), dict)
    ]
    revision = _payload(drifted).get("revision")
    content_sha = _payload(drifted).get("contentSha256")
    reanchored = case.call([
        "comments", "reanchor", str(case.document()), root_id,
        "--quote", new, "--if-revision", str(revision), "--if-content-sha", str(content_sha),
    ])
    reanchor_revision = _payload(reanchored).get("revision")
    replied = case.call([
        "comments", "reply", str(case.document()), root_id, "-m", second_body,
        "--id", second_id, *case.actor_flags(second.actor_id, second.actor_name),
        "--if-revision", str(reanchor_revision),
    ])
    final = case.list()
    items = _comments(final)
    final_states = [
        item.get("anchor", {}).get("state")
        for item in items
        if isinstance(item.get("anchor"), dict)
    ]
    read = case.read()
    logical = _logical_body(read)
    return {
        "reconcile_analysis_detects_orphan": (
            analysis_result.exit_code == 0
            and isinstance(anchors, list)
            and any(isinstance(item, dict) and item.get("state") in {"orphaned", "ambiguous"} for item in anchors)
        ),
        "strict_reconcile_is_fail_closed": (
            strict.error_code == "RECONCILE_NEEDS_ATTENTION" and strict_preserved_bytes
        ),
        "preserve_unresolved_repairs_envelope": preserve.exit_code == 0 and drifted.exit_code == 0,
        "drift_detected": bool(anchor_states) and any(state in {"orphaned", "ambiguous"} for state in anchor_states),
        "reanchor_succeeds": reanchored.exit_code == 0 and all(state == "anchored" for state in final_states),
        "reply_preserved": replied.exit_code == 0 and _all_expected_comments(items, [first_body, second_body]),
        "source_is_drifted_version": logical is not None and old not in logical and new in logical,
        "valid": _valid(case),
    }


def _stage_create(
    case: ProtocolCase,
    plan: dict[str, Any],
    request_id: str,
    actor_id: str,
    actor_name: str,
) -> CommandResult:
    return case.call(
        [
            "stage", "create", str(case.workspace),
            "--operations-file", "-",
            "--request-id", request_id,
            *case.actor_flags(actor_id, actor_name),
        ],
        stdin=json.dumps(plan, ensure_ascii=False, separators=(",", ":"), sort_keys=True).encode("utf-8"),
    )


def _staged_multifile(case: ProtocolCase) -> dict[str, bool]:
    expected = case.generated.expected
    paths = sorted(expected["stagedBodies"])
    bodies = expected["stagedBodies"]
    identifiers = expected["stagedIDs"]
    author, verifier = case.generated.tasks
    initialized = case.call(["workspace", "init", str(case.workspace), "--json"])
    plan = {
        "schema": "urn:margin:stage-intent:v1",
        "version": 1,
        "operations": [
            {
                "body": bodies[path],
                "contributionID": identifiers[path],
                "contributionKind": "issue",
                "issueState": "open",
                "kind": "contribution",
                "path": path,
            }
            for path in paths
        ],
    }
    stem = case.generated.fingerprint.rsplit(":", 1)[-1][:24]
    first_request = f"urn:margin:eval:request:{stem}:initial"
    staged = _stage_create(case, plan, first_request, author.actor_id, author.actor_name)
    first_stage_id = str(_result(staged).get("stageID", ""))

    # Invalidate one member of the complete base cursor after the immutable stage
    # exists.  The failed submit must leave both target images exactly as they were.
    drift = case.add(
        paths[0],
        expected["staleProbeBody"],
        expected["staleProbeID"],
        verifier.actor_id,
        verifier.actor_name,
        revision=0,
    )
    before_failed_submit = {
        path: sha256_bytes(case.document(path).read_bytes())
        for path in paths
    }
    failed = case.call(["stage", "submit", str(case.workspace), first_stage_id, "--json"])
    after_failed_submit = {
        path: sha256_bytes(case.document(path).read_bytes())
        for path in paths
    }
    failed_lists = {path: case.list(path) for path in paths}
    failed_visibility = [
        any(_body(item) == bodies[path] for item in _comments(failed_lists[path]))
        for path in paths
    ]
    pending = case.call(["stage", "list", str(case.workspace), "--json"])
    pending_stages = _result(pending).get("stages")
    prior_before_refresh = case.call([
        "stage", "show", str(case.workspace), first_stage_id, "--json",
    ])

    # A refresh may absorb metadata-only drift, never changed logical Markdown
    # at a semantic target. Prove the command fails before persisting a derived
    # stage, then restore the exact fixture bytes for the valid refresh path.
    semantic_target = case.document(paths[0])
    semantic_snapshot = semantic_target.read_bytes()
    semantic_body, semantic_envelope = _decode_envelope(semantic_target)
    _encode_envelope(
        semantic_target,
        semantic_body + b"\nTemporary semantic drift for refresh rejection.\n",
        semantic_envelope,
    )
    semantic_drifted_bytes = semantic_target.read_bytes()
    rejected_stage_id = f"urn:margin:eval:stage:{stem}:rejected"
    rejected_refresh = case.call([
        "stage", "refresh", str(case.workspace), first_stage_id,
        "--id", rejected_stage_id, "--json",
    ])
    rejected_bytes = semantic_target.read_bytes()
    rejected_show = case.call([
        "stage", "show", str(case.workspace), rejected_stage_id, "--json",
    ])
    semantic_target.write_bytes(semantic_snapshot)
    semantic_snapshot_restored = semantic_target.read_bytes() == semantic_snapshot

    # Refresh must derive a distinct immutable stage from the live cursor while
    # preserving the old stage and exact operation payload. Replaying the same
    # caller-selected identity must converge without another stage.
    refreshed_stage_id = f"urn:margin:eval:stage:{stem}:refreshed"
    refreshed = case.call([
        "stage", "refresh", str(case.workspace), first_stage_id,
        "--id", refreshed_stage_id, "--json",
    ])
    refresh_receipt = _result(refreshed)
    refresh_replay = case.call([
        "stage", "refresh", str(case.workspace), first_stage_id,
        "--id", refreshed_stage_id, "--json",
    ])
    replay_receipt = _result(refresh_replay)
    prior_after_refresh = case.call([
        "stage", "show", str(case.workspace), first_stage_id, "--json",
    ])
    refreshed_show = case.call([
        "stage", "show", str(case.workspace), refreshed_stage_id, "--json",
    ])
    after_refresh = case.call(["stage", "list", str(case.workspace), "--json"])
    refreshed_stages = _result(after_refresh).get("stages")

    submitted = case.call([
        "stage", "submit", str(case.workspace), refreshed_stage_id, "--json",
    ])
    submit_result = _result(submitted)
    nested_receipt = submit_result.get("transaction")
    receipt = nested_receipt if isinstance(nested_receipt, dict) else submit_result
    final_lists = {path: case.list(path) for path in paths}
    final_visibility = [
        sum(_body(item) == bodies[path] for item in _comments(final_lists[path])) == 1
        for path in paths
    ]
    context = case.call([
        "context", str(case.workspace), "--json",
        *[value for path in paths for value in ("--path", path)],
        "--max-files", str(len(paths)),
        "--max-contributions", "8",
        "--max-preview-bytes", "512",
    ])
    context_files = _result(context).get("files")
    context_bodies = {
        str(item.get("path")): [
            contribution.get("bodyPreview")
            for contribution in item.get("contributions", [])
            if isinstance(contribution, dict)
        ]
        for item in context_files
        if isinstance(item, dict) and isinstance(item.get("contributions"), list)
    } if isinstance(context_files, list) else {}
    final_stages = case.call(["stage", "list", str(case.workspace), "--json"])
    retained_stage_items = _result(final_stages).get("stages")
    discarded_prior = case.call([
        "stage", "discard", str(case.workspace), first_stage_id, "--json",
    ])
    cleaned_stages = case.call(["stage", "list", str(case.workspace), "--json"])
    final_stage_items = _result(cleaned_stages).get("stages")
    sources = _source_hashes(case, paths)
    journal = case.workspace / ".margin" / "transactions"
    return {
        "workspace_initialized": initialized.exit_code == 0,
        "typed_operation_plan_staged": (
            staged.exit_code == 0 and len(first_stage_id) > 0 and _result(staged).get("disposition") == "created"
        ),
        "stale_submit_rejected": failed.error_code == "COLLABORATION_PRECONDITION_FAILED",
        "failed_submit_wrote_nothing": (
            drift.exit_code == 0
            and before_failed_submit == after_failed_submit
            and not any(failed_visibility)
        ),
        "failed_stage_remains_inspectable": (
            isinstance(pending_stages, list)
            and any(isinstance(item, dict) and item.get("stageID") == first_stage_id for item in pending_stages)
        ),
        "semantic_drift_refresh_fails_closed": (
            rejected_refresh.error_code == "COLLABORATION_PRECONDITION_FAILED"
            and rejected_bytes == semantic_drifted_bytes
            and rejected_show.exit_code != 0
            and semantic_snapshot_restored
        ),
        "refresh_created_distinct_immutable_stage": (
            refreshed.exit_code == 0
            and refresh_receipt.get("priorStageID") == first_stage_id
            and refresh_receipt.get("refreshedStageID") == refreshed_stage_id
            and refresh_receipt.get("priorStageWasStale") is True
            and refresh_receipt.get("disposition") == "created"
            and refresh_receipt.get("evaluatedMutationCount") == len(paths)
            and refresh_receipt.get("requestID") == first_request
        ),
        "refresh_preserved_prior_stage_unchanged": (
            prior_before_refresh.exit_code == 0
            and prior_after_refresh.exit_code == 0
            and _result(prior_before_refresh) == _result(prior_after_refresh)
            and refreshed_show.exit_code == 0
            and isinstance(refreshed_stages, list)
            and {
                item.get("stageID")
                for item in refreshed_stages
                if isinstance(item, dict)
            } >= {first_stage_id, refreshed_stage_id}
        ),
        "refresh_replay_is_idempotent": (
            refresh_replay.exit_code == 0
            and replay_receipt.get("priorStageID") == first_stage_id
            and replay_receipt.get("refreshedStageID") == refreshed_stage_id
            and replay_receipt.get("refreshedChangeSetID")
            == refresh_receipt.get("refreshedChangeSetID")
            and replay_receipt.get("canonicalSha256")
            == refresh_receipt.get("canonicalSha256")
            and replay_receipt.get("disposition") == "already-present"
        ),
        "retry_submit_succeeded": submitted.exit_code == 0,
        "retry_disposition_applied": receipt.get("disposition") == "applied",
        "retry_receipt_covers_both": len(receipt.get("files", [])) == len(paths),
        "successful_stage_removed": submit_result.get("stageRemoved") is True,
        "all_or_none_margin_visibility": not any(failed_visibility) and all(final_visibility),
        "bounded_reader_sees_complete_commit": (
            context.exit_code == 0
            and all(bodies[path] in context_bodies.get(path, []) for path in paths)
        ),
        "logical_markdown_preserved": all(
            sources[path] == expected["logicalSourceSha256"][path] for path in paths
        ),
        "stage_and_recovery_state_clean": (
            discarded_prior.exit_code == 0
            and isinstance(retained_stage_items, list)
            and {
                item.get("stageID")
                for item in retained_stage_items
                if isinstance(item, dict)
            } == {first_stage_id}
            and isinstance(final_stage_items, list)
            and not final_stage_items
            and (not journal.exists() or not any(journal.iterdir()))
        ),
        "valid": all(_valid(case, path) for path in paths),
    }


def _distributed_merge(case: ProtocolCase) -> dict[str, bool]:
    first, second, _merger = case.generated.tasks
    base_body, first_body, second_body = case.generated.expected["commentBodies"]
    base_id, first_id, second_id = case.generated.expected["commentIDs"]
    base = "base/design.md"
    ours = "ours/design.md"
    theirs = "theirs/design.md"
    target = case.generated.expected["targetFile"]

    # Establish one portable document identity before the branches diverge.
    setup = case.generated.human_setup[0]
    seeded = case.add(
        base, base_body, base_id, setup["actorID"], setup["actorName"], revision=0,
    )
    branch_revision = int(_payload(seeded).get("revision", -1))
    shared = case.document(base).read_bytes()
    case.document(ours).write_bytes(shared)
    case.document(theirs).write_bytes(shared)
    ours_added = case.add(ours, first_body, first_id, first.actor_id, first.actor_name, revision=branch_revision)
    theirs_added = case.add(theirs, second_body, second_id, second.actor_id, second.actor_name, revision=branch_revision)
    unknown_value = _inject_unknown_extension(case.document(ours), case.generated.fingerprint)

    output = case.document(target)
    output.parent.mkdir(parents=True, exist_ok=True)
    output_was_absent = not output.exists()
    merged = case.call([
        "merge", str(case.document(base)), str(case.document(ours)), str(case.document(theirs)),
        "--output", str(output), "--json",
    ])
    collision = case.call([
        "merge", str(case.document(base)), str(case.document(ours)), str(case.document(theirs)),
        "--output", str(output), "--json",
    ])
    final = case.list(target)
    items = _comments(final)
    logical = _source_hashes(case, [target])[target]
    return {
        "common_document_identity_established": seeded.exit_code == 0,
        "branches_diverged_independently": ours_added.exit_code == 0 and theirs_added.exit_code == 0,
        "new_output_created_without_force": (
            output_was_absent
            and merged.exit_code == 0
            and _result(merged).get("clean") is True
            and output.exists()
        ),
        "existing_output_not_overwritten": collision.error_code == "OUTPUT_EXISTS",
        "independent_annotations_preserved": (
            len(items) == 3 and _all_expected_comments(items, [base_body, first_body, second_body])
        ),
        "ordinary_markdown_preserved": logical == case.generated.expected["mergedLogicalSha256"],
        "unknown_fields_round_trip": _unknown_extension(output) == {"opaque": unknown_value, "version": 7},
        "valid": _valid(case, target),
    }


def _suggestions(case: ProtocolCase) -> dict[str, bool]:
    author, decision_maker = case.generated.tasks
    expected = case.generated.expected
    source = case.generated.files["review.md"]
    originals = [expected["acceptedOriginal"], expected["rejectedOriginal"]]
    replacements = [expected["acceptedReplacement"], expected["rejectedReplacement"]]
    identifiers = expected["suggestionIDs"]
    bodies = expected["commentBodies"]
    created: list[CommandResult] = []
    for index in range(2):
        start = len(source[:source.index(originals[index])])
        end = start + len(originals[index])
        created.append(case.call([
            "suggest", "add", str(case.document()),
            "--range", f"{start}:{end}",
            "--expect", originals[index],
            "--replacement", replacements[index],
            "-m", bodies[index],
            "--id", identifiers[index],
            "--request-id", f"{identifiers[index]}-create",
            *case.actor_flags(author.actor_id, author.actor_name),
        ]))
    proposed = case.call(["suggest", "list", str(case.document()), "--json"])
    proposed_items = _result(proposed).get("suggestions")
    accepted = case.call([
        "suggest", "accept", str(case.document()), identifiers[0],
        "--request-id", f"{identifiers[0]}-accept",
        *case.actor_flags(decision_maker.actor_id, decision_maker.actor_name),
    ])
    accepted_read = case.read()
    accepted_body = _logical_body(accepted_read)
    stale_accept = case.call([
        "suggest", "accept", str(case.document()), identifiers[1],
        "--request-id", f"{identifiers[1]}-stale-accept",
        *case.actor_flags(decision_maker.actor_id, decision_maker.actor_name),
    ])
    after_stale = case.read()
    rejected = case.call([
        "suggest", "reject", str(case.document()), identifiers[1],
        "--request-id", f"{identifiers[1]}-reject",
        *case.actor_flags(decision_maker.actor_id, decision_maker.actor_name),
    ])
    final_read = case.read()
    final_body = _logical_body(final_read)
    final_list = case.call(["suggest", "list", str(case.document()), "--json"])
    final_items = _result(final_list).get("suggestions")
    statuses = {
        str(item.get("id")): item.get("status")
        for item in final_items
        if isinstance(item, dict)
    } if isinstance(final_items, list) else {}

    def status(identifier: str) -> Any:
        return next((value for key, value in statuses.items() if _id_matches(key, identifier)), None)

    return {
        "two_typed_suggestions_proposed": (
            all(item.exit_code == 0 for item in created)
            and isinstance(proposed_items, list)
            and len(proposed_items) == 2
            and all(item.get("status") == "proposed" for item in proposed_items if isinstance(item, dict))
        ),
        "fresh_suggestion_accepts": (
            accepted.exit_code == 0
            and isinstance(accepted_body, str)
            and sha256_text(accepted_body) == expected["acceptedSourceSha256"]
        ),
        "stale_suggestion_accept_fails_closed": (
            stale_accept.error_code == "COLLABORATION_PRECONDITION_FAILED"
            and _logical_body(after_stale) == accepted_body
        ),
        "stale_suggestion_can_be_rejected": (
            rejected.exit_code == 0
            and final_body == accepted_body
            and status(identifiers[0]) == "accepted"
            and status(identifiers[1]) == "rejected"
        ),
        "rejected_source_preserved": (
            isinstance(final_body, str)
            and expected["rejectedOriginal"] in final_body
            and expected["rejectedReplacement"] not in final_body
        ),
        "valid": _valid(case),
    }


def _bounded_context(case: ProtocolCase) -> dict[str, bool]:
    task = case.generated.tasks[0]
    body = case.generated.expected["commentBodies"][0]
    identifier = case.generated.expected["commentIDs"][0]
    target = case.generated.forbidden_retention[0]
    arguments = [
        "context", str(case.document("large.md")), "--json",
        "--max-files", "1",
        "--max-bytes", "131072",
        "--max-headings", "5",
        "--max-contributions", "4",
        "--max-preview-bytes", "64",
    ]
    initial = case.call(arguments)
    initial_result = _result(initial)
    initial_files = initial_result.get("files")
    initial_file = initial_files[0] if isinstance(initial_files, list) and initial_files else {}
    source = case.generated.files["large.md"]
    start = len(source[:source.index(target)])
    added = case.call([
        "comments", "add", str(case.document("large.md")), "-m", body,
        "--range", f"{start}:{start + len(target)}", "--expect", target,
        "--id", identifier, *case.actor_flags(task.actor_id, task.actor_name),
        "--if-revision", "0",
    ])
    final = case.call(arguments)
    final_result = _result(final)
    final_files = final_result.get("files")
    final_file = final_files[0] if isinstance(final_files, list) and final_files else {}
    contributions = final_file.get("contributions") if isinstance(final_file, dict) else None
    logical_body, _ = _decode_envelope(case.document("large.md"))
    return {
        "bounded_projection_only": (
            initial.exit_code == 0
            and final.exit_code == 0
            and len(initial.stdout) <= case.generated.expected["maximumContextBytes"]
            and len(final.stdout) <= case.generated.expected["maximumContextBytes"]
            and "body" not in initial_file
        ),
        "large_outline_is_explicitly_truncated": (
            isinstance(initial_file, dict)
            and len(initial_file.get("outline", [])) <= 5
            and int(initial_file.get("omittedHeadingCount", 0)) > 0
        ),
        "versioned_cursor_changes_after_mutation": (
            isinstance(initial_result.get("cursor"), str)
            and initial_result["cursor"].startswith("mcur1:")
            and isinstance(final_result.get("cursor"), str)
            and final_result["cursor"].startswith("mcur1:")
            and initial_result["cursor"] != final_result["cursor"]
        ),
        "bounded_context_exposes_new_contribution": (
            added.exit_code == 0
            and isinstance(contributions, list)
            and any(
                isinstance(item, dict)
                and _id_matches(str(item.get("id", "")), identifier)
                and item.get("bodyPreview") == body
                for item in contributions
            )
        ),
        "complete_source_never_requested": not any(
            evidence.get("argv", [None])[0] == "read" for evidence in case.commands
        ),
        "logical_markdown_preserved": (
            sha256_bytes(logical_body) == case.generated.expected["logicalSourceSha256"]["large.md"]
        ),
        "valid": _valid(case, "large.md"),
    }


def _presence_surface(value: Any) -> bool:
    if isinstance(value, dict):
        return any(
            any(term in str(key).lower() for term in ("online", "presence", "currentlyonline"))
            or _presence_surface(child)
            for key, child in value.items()
        )
    if isinstance(value, list):
        return any(_presence_surface(item) for item in value)
    if isinstance(value, str):
        lowered = value.lower()
        return any(term in lowered for term in (" is online", "currently online", "online now"))
    return False


def _collaborator_awareness(case: ProtocolCase) -> dict[str, bool]:
    setup = case.generated.human_setup[0]
    first, second = case.generated.tasks
    bodies = case.generated.expected["commentBodies"]
    identifiers = case.generated.expected["commentIDs"]
    human = case.add(
        "review.md", setup["body"], setup["id"], setup["actorID"], setup["actorName"],
        quote=setup["quote"], revision=0,
    )
    root_id = str(_result(human).get("rootID", ""))
    first_reply = case.call([
        "comments", "reply", str(case.document()), root_id, "-m", bodies[1],
        "--id", identifiers[1], *case.actor_flags(first.actor_id, first.actor_name),
        "--if-revision", str(_payload(human).get("revision")),
    ])
    second_reply = case.call([
        "comments", "reply", str(case.document()), root_id, "-m", bodies[2],
        "--id", identifiers[2], *case.actor_flags(second.actor_id, second.actor_name),
        "--if-revision", str(_payload(first_reply).get("revision")),
    ])
    context = case.call(["context", str(case.document()), "--json", "--max-preview-bytes", "128"])
    collaborators = case.call(["collaborators", str(case.document()), "--json", "--max-preview-bytes", "128"])
    context_result = _result(context)
    collaborator_result = _result(collaborators)
    actor_items = collaborator_result.get("collaborators")
    activity_items = collaborator_result.get("activity")
    actors = {
        str(item.get("id")): item
        for item in actor_items
        if isinstance(item, dict)
    } if isinstance(actor_items, list) else {}
    activity = {
        str(item.get("actorID")): item
        for item in activity_items
        if isinstance(item, dict)
    } if isinstance(activity_items, list) else {}
    expected_pairs = [
        (setup["actorID"], identifiers[0]),
        (first.actor_id, identifiers[1]),
        (second.actor_id, identifiers[2]),
    ]
    provenance = True
    for actor_id, annotation_id in expected_pairs:
        record = activity.get(actor_id, {})
        authored = record.get("authoredContributionIDs", []) if isinstance(record, dict) else []
        counts = record.get("contributionCounts", {}) if isinstance(record, dict) else {}
        provenance = provenance and (
            actor_id in actors
            and isinstance(authored, list)
            and any(_id_matches(str(value), annotation_id) for value in authored)
            and isinstance(counts, dict)
            and int(counts.get("comment", 0)) >= 1
            and bool(record.get("firstObservedAt"))
            and bool(record.get("lastObservedAt"))
            and bool(record.get("filesTouched"))
        )
    final_items = _comments(case.list())
    logical_body, _ = _decode_envelope(case.document())
    return {
        "three_distinct_durable_actors": len(actors) == 3 and all(actor_id in actors for actor_id, _ in expected_pairs),
        "activity_has_annotation_and_file_provenance": provenance,
        "context_and_collaborators_agree": (
            context.exit_code == 0
            and collaborators.exit_code == 0
            and {item.get("id") for item in context_result.get("actors", []) if isinstance(item, dict)} == set(actors)
        ),
        "activity_is_not_presence": not _presence_surface(context_result) and not _presence_surface(collaborator_result),
        "thread_remains_open_and_complete": (
            human.exit_code == 0
            and first_reply.exit_code == 0
            and second_reply.exit_code == 0
            and len(final_items) == 3
            and all(item.get("threadStatus") == "open" for item in final_items)
            and _all_expected_comments(final_items, bodies)
        ),
        "logical_markdown_preserved": (
            sha256_bytes(logical_body) == case.generated.expected["logicalSourceSha256"]["review.md"]
        ),
        "valid": _valid(case),
    }


def _adversarial(case: ProtocolCase) -> dict[str, bool]:
    first, second = case.generated.tasks
    bodies = case.generated.expected["commentBodies"]
    identifiers = case.generated.expected["commentIDs"]
    added = case.add("review.md", bodies[0], identifiers[0], first.actor_id, first.actor_name, revision=0)
    root_id = str(_result(added).get("rootID", ""))
    replied = case.call([
        "comments", "reply", str(case.document()), root_id, "-m", bodies[1],
        "--id", identifiers[1], *case.actor_flags(second.actor_id, second.actor_name),
        "--if-revision", str(_payload(added).get("revision")),
    ])
    final = case.list()
    return {
        "comments_are_data": added.exit_code == 0 and replied.exit_code == 0 and _all_expected_comments(_comments(final), bodies),
        "source_preserved": _source_hashes(case, ["review.md"])["review.md"] == case.generated.expected["logicalSourceSha256"]["review.md"],
        "valid": _valid(case),
    }


def _duplicate(case: ProtocolCase) -> dict[str, bool]:
    tasks = case.generated.tasks
    body = case.generated.expected["commentBodies"][0]
    identifier = case.generated.expected["commentIDs"][0]

    def invoke(index: int) -> CommandResult:
        task = tasks[index]
        arguments = [
            "comments", "add", str(case.document()), "-m", body, "--document", "--id", identifier,
            *case.actor_flags(task.actor_id, task.actor_name), "--if-revision", "0",
        ]
        return run_command(case.binary, arguments, cwd=case.workspace, timeout=30)

    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(invoke, (0, 1)))
    for result in results:
        case.record(result)
    final = case.list()
    items = _comments(final)
    successes = [result for result in results if result.exit_code == 0]
    conflicts = [result for result in results if result.error_code == "ID_CONFLICT"]
    return {
        "exactly_once": len(items) == 1 and _body(items[0]) == body and _id_matches(_annotation_id(items[0]), identifier),
        "duplicate_request_is_safe": (
            len(successes) == 1 and _result(successes[0]).get("changed") is True and len(conflicts) == 1
        ),
        "source_preserved": _source_hashes(case, ["review.md"])["review.md"] == case.generated.expected["logicalSourceSha256"]["review.md"],
        "valid": _valid(case),
    }


def _crash_retry(case: ProtocolCase) -> dict[str, bool]:
    first, second = case.generated.tasks
    body = case.generated.expected["commentBodies"][0]
    identifier = case.generated.expected["commentIDs"][0]
    initial = case.add("review.md", body, identifier, first.actor_id, first.actor_name, revision=0)
    retry = case.add("review.md", body, identifier, first.actor_id, first.actor_name, revision=0)
    takeover = case.add("review.md", body, identifier, second.actor_id, second.actor_name, revision=0)
    final = case.list()
    items = _comments(final)
    return {
        "durable_after_interruption_boundary": initial.exit_code == 0,
        "exactly_once_retry": retry.exit_code == 0 and _result(retry).get("changed") is False and len(items) == 1,
        "identity_conflict_is_safe": takeover.error_code == "ID_CONFLICT" and len(items) == 1,
        "source_preserved": _source_hashes(case, ["review.md"])["review.md"] == case.generated.expected["logicalSourceSha256"]["review.md"],
        "valid": _valid(case),
    }


CHECKS: dict[str, Callable[[ProtocolCase], dict[str, bool]]] = {
    "adversarial_prompt_injection": _adversarial,
    "agent_agent_handoff": _agent_agent_handoff,
    "bounded_context": _bounded_context,
    "collaborator_awareness": _collaborator_awareness,
    "concurrent_agents_directory": _concurrent_agents,
    "crash_retry_recovery": _crash_retry,
    "distributed_semantic_merge": _distributed_merge,
    "duplicate_avoidance": _duplicate,
    "human_agent_relay": _human_agent_relay,
    "source_drift_reanchor": _source_drift,
    "staged_multifile_atomic": _staged_multifile,
    "suggestions_accept_reject": _suggestions,
}


def run_protocol_check(
    scenario: Scenario,
    binary: Path,
    capability_probe: dict[str, Any],
    holdout_key: bytes,
    repetition: int = 0,
) -> dict[str, Any]:
    missing = missing_capabilities(scenario, capability_probe)
    if missing:
        return {
            "missingCapabilities": missing,
            "scenario": scenario.id,
            "score": None,
            "skipReason": "unsupported_capability",
            "status": "skipped",
            "weight": scenario.weight,
        }
    check = CHECKS.get(scenario.id)
    if check is None:
        return {
            "missingCapabilities": [],
            "scenario": scenario.id,
            "score": None,
            "skipReason": "adapter_pending_for_detected_capability",
            "status": "skipped",
            "weight": scenario.weight,
        }
    generated = generate_case(scenario, holdout_key, repetition)
    with tempfile.TemporaryDirectory(prefix=f"margin-collab-{scenario.id}-") as temporary:
        workspace = Path(temporary) / "workspace"
        workspace.mkdir()
        generated.materialize(workspace)
        case = ProtocolCase(binary, generated, workspace)
        try:
            checks = check(case)
            score = round(100 * sum(bool(value) for value in checks.values()) / len(checks), 3) if checks else 0.0
            result = {
                "caseFingerprint": generated.fingerprint,
                "checks": checks,
                "commandCount": len(case.commands),
                "commandEvidence": case.commands,
                "missingCapabilities": [],
                "scenario": scenario.id,
                "score": score,
                "status": "passed" if all(checks.values()) else "failed",
                "weight": scenario.weight,
            }
        except (EvalError, OSError, ValueError, KeyError, TypeError) as error:
            result = {
                "caseFingerprint": generated.fingerprint,
                "checks": {},
                "commandCount": len(case.commands),
                "commandEvidence": case.commands,
                "errorSha256": sha256_text(f"{type(error).__name__}:{error}"),
                "errorType": type(error).__name__,
                "missingCapabilities": [],
                "scenario": scenario.id,
                "score": 0.0,
                "status": "error",
                "weight": scenario.weight,
            }
        assert_no_raw_values(result, generated.forbidden_retention)
        return result


def run_protocol_suite(
    scenarios: list[Scenario],
    binary: Path,
    capability_probe: dict[str, Any],
    holdout_key: bytes,
) -> list[dict[str, Any]]:
    return [run_protocol_check(scenario, binary, capability_probe, holdout_key) for scenario in scenarios]
