"""No-model feasibility policy for the still-gated plain-Markdown control."""

from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
from dataclasses import replace
from pathlib import Path
from typing import Callable

from .neutral import NeutralFact, NeutralLedger, expected_neutral_ledger
from .neutral_scorer import score_neutral_state
from .plain_gateway import PlainGatewayError, PlainProvenanceLog, PlainWorkspaceGateway
from .schema import Actor, EpisodeDefinition, HarnessEvent, RoleTask


def _read_ledger(gateway: PlainWorkspaceGateway) -> tuple[NeutralLedger, str]:
    result = gateway.read("COLLABORATION.md", max_lines=2000)
    if result["truncatedBefore"] or result["truncatedAfter"]:
        raise RuntimeError("Reference ledger exceeded the bounded tool view.")
    return NeutralLedger.parse(str(result["text"]).encode("utf-8")), str(result["sha256"])


def _cas_ledger(
    gateway: PlainWorkspaceGateway,
    mutation: Callable[[dict[str, NeutralFact]], None],
) -> None:
    for _ in range(4):
        current, digest = _read_ledger(gateway)
        facts = {fact.id: fact for fact in current.facts}
        mutation(facts)
        replacement = NeutralLedger(tuple(sorted(facts.values(), key=lambda fact: fact.id)))
        try:
            gateway.write(
                "COLLABORATION.md",
                replacement.encode().decode("utf-8"),
                if_sha256=digest,
            )
            return
        except PlainGatewayError as error:
            if error.code != "PRECONDITION_FAILED":
                raise
    raise RuntimeError("Plain reference ledger did not converge after four attempts.")


def _initial_fact(fact: NeutralFact, expected: NeutralLedger, scenario: str) -> NeutralFact:
    has_later_reply = any(item.parent == fact.id for item in expected.facts)
    if fact.kind == "suggestion":
        return replace(fact, state="open", decision_by=None)
    if scenario == "staged_multifile" and fact.transaction is not None:
        return replace(fact, state="none")
    if has_later_reply and fact.state == "resolved":
        return replace(fact, state="open")
    return fact


def apply_plain_harness_event(
    episode: EpisodeDefinition,
    event: HarnessEvent,
    gateway: PlainWorkspaceGateway,
) -> None:
    if event.kind == "comment_add":
        expected = expected_neutral_ledger(episode)
        identifier = str(event.payload["id"])
        fact = next(item for item in expected.facts if item.id == identifier)
        initial = _initial_fact(fact, expected, episode.scenario_id)
        _cas_ledger(gateway, lambda facts: facts.__setitem__(identifier, initial))
        return
    if event.kind == "source_replace":
        relative = str(event.payload["path"])
        current = gateway.read(relative, max_lines=2000)
        if current["truncatedBefore"] or current["truncatedAfter"]:
            raise RuntimeError("Reference source exceeded the bounded tool view.")
        source = str(current["text"])
        old = str(event.payload["old"])
        if source.count(old) != 1:
            raise RuntimeError("Plain harness source target was not unique.")
        gateway.write(
            relative,
            source.replace(old, str(event.payload["new"])),
            if_sha256=str(current["sha256"]),
        )
        return
    raise ValueError(f"Unsupported plain harness event: {event.kind}")


class PlainReferenceDriver:
    def run(
        self,
        episode: EpisodeDefinition,
        role: RoleTask,
        gateway: PlainWorkspaceGateway,
    ) -> None:
        expected = expected_neutral_ledger(episode)
        authored = [fact for fact in expected.facts if fact.author == role.actor.id]

        if episode.scenario_id == "staged_multifile" and role.seat == "reviewer":
            cursor_file = gateway.read("STAGE.md")
            prefix = "Base ledger SHA-256: "
            lines = str(cursor_file["text"]).splitlines()
            stored = next((line[len(prefix) :] for line in lines if line.startswith(prefix)), "")
            current = gateway.read("COLLABORATION.md", max_lines=2000)
            try:
                gateway.write(
                    "COLLABORATION.md",
                    str(current["text"]),
                    if_sha256=stored,
                )
            except PlainGatewayError as error:
                if error.code != "PRECONDITION_FAILED":
                    raise
            else:
                raise RuntimeError("Plain staged reference did not observe stale state.")

        def mutate(facts: dict[str, NeutralFact]) -> None:
            for fact in authored:
                facts[fact.id] = _initial_fact(fact, expected, episode.scenario_id)
            if role.seat == "reviewer":
                for fact in expected.facts:
                    if fact.id in facts:
                        facts[fact.id] = fact

        _cas_ledger(gateway, mutate)
        if episode.scenario_id == "staged_multifile" and role.seat == "author":
            ledger = gateway.read("COLLABORATION.md", max_lines=2000)
            cursor_file = gateway.read("STAGE.md")
            gateway.write(
                "STAGE.md",
                f"# Stage cursor\n\nBase ledger SHA-256: {ledger['sha256']}\n",
                if_sha256=str(cursor_file["sha256"]),
            )
        if episode.scenario_id == "suggestion_decision" and role.seat == "reviewer":
            accepted = next(fact for fact in expected.facts if fact.state == "accepted")
            source = gateway.read(accepted.file, max_lines=2000)
            if source["truncatedBefore"] or source["truncatedAfter"]:
                raise RuntimeError("Suggestion source exceeded the bounded tool view.")
            text = str(source["text"])
            if accepted.expected_text is None or accepted.replacement_text is None:
                raise RuntimeError("Expected suggestion projection is incomplete.")
            if text.count(accepted.expected_text) != 1:
                raise RuntimeError("Expected suggestion source was not unique.")
            gateway.write(
                accepted.file,
                text.replace(accepted.expected_text, accepted.replacement_text),
                if_sha256=str(source["sha256"]),
            )


def run_plain_reference_episode(
    episode: EpisodeDefinition,
    workspace: Path,
) -> dict[str, object]:
    """Run free feasibility only; this does not make the control executable."""
    episode.materialize(workspace)
    (workspace / "COLLABORATION.md").write_bytes(NeutralLedger(()).encode())
    if episode.scenario_id == "staged_multifile":
        (workspace / "STAGE.md").write_text("# Stage cursor\n\nUninitialized.\n", encoding="utf-8")
    state = workspace.parent / ".marginbench-plain-state"
    provenance_path = state / "provenance.jsonl"

    def provenance() -> PlainProvenanceLog:
        # Each role gets an independent handle to the same locked journal, as it
        # will when the future environment runs tools in separate processes.
        return PlainProvenanceLog(provenance_path)

    driver = PlainReferenceDriver()
    for phase in sorted({role.phase for role in episode.roles}):
        for event in episode.events:
            if event.phase == phase and event.timing == "before":
                actor = Actor(**event.payload["actor"])
                apply_plain_harness_event(
                    episode,
                    event,
                    PlainWorkspaceGateway(workspace, actor, state, provenance()),
                )
        roles = [role for role in episode.roles if role.phase == phase]

        def execute(role: RoleTask) -> None:
            driver.run(
                episode,
                role,
                PlainWorkspaceGateway(workspace, role.actor, state, provenance()),
            )

        if len(roles) > 1:
            with ThreadPoolExecutor(max_workers=len(roles)) as executor:
                futures = [executor.submit(execute, role) for role in roles]
                for future in futures:
                    future.result()
        else:
            execute(roles[0])
        for event in episode.events:
            if event.phase == phase and event.timing == "after":
                actor = Actor(**event.payload["actor"])
                apply_plain_harness_event(
                    episode,
                    event,
                    PlainWorkspaceGateway(workspace, actor, state, provenance()),
                )
    return score_neutral_state(
        episode,
        workspace,
        state,
        PlainProvenanceLog(provenance_path),
    )
