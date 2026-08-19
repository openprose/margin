"""Oracle-free scripted policy for zero-cost plain-control served preflight."""

from __future__ import annotations

import re
from dataclasses import replace
from typing import Any, Awaitable, Callable

from .neutral import NeutralFact, NeutralLedger


ToolCall = Callable[..., Awaitable[dict[str, Any]]]


def _match(pattern: str, prompt: str) -> re.Match[str]:
    matched = re.search(pattern, prompt, re.DOTALL)
    if matched is None:
        raise ValueError("Plain scripted preflight could not parse its public role brief.")
    return matched


def _actor(prompt: str) -> str:
    return _match(r"trusted actor ID is `([^`]+)`", prompt).group(1)


async def _successful(call: ToolCall, **arguments: Any) -> dict[str, Any]:
    result = await call(**arguments)
    if not result.get("ok"):
        raise RuntimeError("Plain scripted preflight received an unexpected tool failure.")
    value = result.get("result")
    if not isinstance(value, dict):
        raise RuntimeError("Plain scripted preflight received an invalid tool result.")
    return value


async def _read_ledger(call: ToolCall) -> tuple[NeutralLedger, str, str]:
    result = await _successful(
        call,
        action="read",
        path="COLLABORATION.md",
        max_lines=2_000,
    )
    text = str(result["text"])
    return NeutralLedger.parse(text.encode("utf-8")), str(result["sha256"]), text


async def _mutate_ledger(
    call: ToolCall,
    mutation: Callable[[dict[str, NeutralFact]], None],
) -> dict[str, Any]:
    for _ in range(4):
        ledger, digest, _ = await _read_ledger(call)
        facts = {fact.id: fact for fact in ledger.facts}
        mutation(facts)
        replacement = NeutralLedger(tuple(sorted(facts.values(), key=lambda fact: fact.id)))
        result = await call(
            action="write",
            path="COLLABORATION.md",
            text=replacement.encode().decode("utf-8"),
            if_sha256=digest,
        )
        if result.get("ok"):
            value = result.get("result")
            if isinstance(value, dict):
                await _successful(
                    call,
                    action="read",
                    path="COLLABORATION.md",
                    max_lines=2_000,
                )
                return value
            raise RuntimeError("Plain scripted write receipt is invalid.")
        error = result.get("error")
        if not isinstance(error, dict) or error.get("code") != "PRECONDITION_FAILED":
            raise RuntimeError("Plain scripted ledger mutation failed unexpectedly.")
    raise RuntimeError("Plain scripted ledger mutation did not converge.")


def _resolved_thread(
    facts: dict[str, NeutralFact],
    root: NeutralFact,
    reply: NeutralFact,
) -> None:
    for identifier, fact in tuple(facts.items()):
        if fact.root == root.id:
            facts[identifier] = replace(fact, state="resolved")
    facts[root.id] = replace(root, state="resolved")
    facts[reply.id] = reply


async def _reply_to_open_root(
    prompt: str,
    call: ToolCall,
    *,
    kind: str | None = None,
) -> None:
    actor = _actor(prompt)
    body, identifier = _match(
        r"exactly\s+(?:this\s+Markdown\s+|this\s+)?body:\s*\n(.+?)\n"
        r"Use reply fact id ([0-9a-f-]+)[.,]",
        prompt,
    ).groups()

    def mutate(facts: dict[str, NeutralFact]) -> None:
        roots = [
            fact for fact in facts.values()
            if fact.parent is None and fact.state == "open" and (kind is None or fact.kind == kind)
        ]
        if len(roots) != 1:
            raise RuntimeError("Plain scripted preflight did not find one open root.")
        root = roots[0]
        _resolved_thread(facts, root, NeutralFact(
            id=identifier,
            kind="reply",
            file=root.file,
            author=actor,
            state="resolved",
            parent=root.id,
            root=root.id,
            body=body.strip(),
        ))

    await _mutate_ledger(call, mutate)


async def _handoff_author(prompt: str, call: ToolCall) -> None:
    actor = _actor(prompt)
    next_actor, identifier, body = _match(
        r"for\s+actor (urn:\S+?)[,.]\s+(?:Use|using) handoff fact id ([0-9a-f-]+).*?"
        r"(?:exactly this body:\n|exact\nbody `)(.+?)(?:\nLeave it open|` Leave it open)",
        prompt,
    ).groups()

    def mutate(facts: dict[str, NeutralFact]) -> None:
        facts[identifier] = NeutralFact(
            id=identifier,
            kind="handoff",
            file=(
                _match(r"handoff fact in (\S+?) for", prompt).group(1)
                if "handoff fact in" in prompt
                else "synthesis.md"
            ),
            author=actor,
            state="open",
            root=identifier,
            body=body.strip(),
            next_actor=next_actor,
            audience=(next_actor,),
        )

    await _mutate_ledger(call, mutate)


async def _issue_author(prompt: str, call: ToolCall) -> None:
    actor = _actor(prompt)
    path, identifier, body = _match(
        r"document-level issue(?: fact about| to) (\S+) with\s*id ([0-9a-f-]+) and exactly this body:\n(.+?)\n"
        r"(?:If a concurrent|Do not wait)",
        prompt,
    ).groups()

    def mutate(facts: dict[str, NeutralFact]) -> None:
        facts[identifier] = NeutralFact(
            id=identifier,
            kind="issue",
            file=path,
            author=actor,
            state="open",
            root=identifier,
            body=body.strip(),
        )

    await _mutate_ledger(call, mutate)


async def _suggestion_author(prompt: str, call: ToolCall) -> None:
    actor = _actor(prompt)
    values = re.findall(
        r"replacing\s*`([^`]+)` with\s*`([^`]+)` using id ([0-9a-f-]+) and message exactly\s*`([^`]+)`",
        prompt,
        re.DOTALL,
    )
    if len(values) != 2:
        raise ValueError("Plain scripted preflight did not find two suggestions.")

    def mutate(facts: dict[str, NeutralFact]) -> None:
        for exact, replacement, identifier, body in values:
            facts[identifier] = NeutralFact(
                id=identifier,
                kind="suggestion",
                file="review.md",
                author=actor,
                state="open",
                root=identifier,
                body=body,
                expected_text=exact,
                replacement_text=replacement,
            )

    await _mutate_ledger(call, mutate)


async def _suggestion_reviewer(prompt: str, call: ToolCall) -> None:
    actor = _actor(prompt)
    accepted, rejected = _match(
        r"Accept ([0-9a-f-]+).*?reject ([0-9a-f-]+)",
        prompt,
    ).groups()

    def mutate(facts: dict[str, NeutralFact]) -> None:
        facts[accepted] = replace(facts[accepted], state="accepted", decision_by=actor)
        facts[rejected] = replace(facts[rejected], state="rejected", decision_by=actor)

    await _mutate_ledger(call, mutate)
    ledger, _, _ = await _read_ledger(call)
    suggestion = next(fact for fact in ledger.facts if fact.id == accepted)
    source = await _successful(call, action="read", path=suggestion.file, max_lines=2_000)
    text = str(source["text"])
    if suggestion.expected_text is None or suggestion.replacement_text is None:
        raise RuntimeError("Plain scripted suggestion is incomplete.")
    if text.count(suggestion.expected_text) != 1:
        raise RuntimeError("Plain scripted suggestion target is not unique.")
    await _successful(
        call,
        action="write",
        path=suggestion.file,
        text=text.replace(suggestion.expected_text, suggestion.replacement_text),
        if_sha256=str(source["sha256"]),
    )
    await _successful(call, action="read", path=suggestion.file, max_lines=2_000)


async def _stage_author(prompt: str, call: ToolCall) -> None:
    actor = _actor(prompt)
    transaction, request = _match(
        r"Transaction\n`([^`]+)`, and extension `X-Request ID: ([^`]+)`",
        prompt,
    ).groups()
    values = re.findall(
        r"- file `([^`]+)`\n  fact ID `([^`]+)`\n  exact body `([^`]+)`",
        prompt,
    )
    if len(values) != 2:
        raise ValueError("Plain scripted preflight did not find two staged facts.")

    def mutate(facts: dict[str, NeutralFact]) -> None:
        for path, identifier, body in values:
            facts[identifier] = NeutralFact(
                id=identifier,
                kind="issue",
                file=path,
                author=actor,
                state="none",
                root=identifier,
                body=body,
                transaction=transaction,
                extensions=(("X-Request ID", request),),
            )

    await _mutate_ledger(call, mutate)
    ledger = await _successful(
        call,
        action="read",
        path="COLLABORATION.md",
        max_lines=2_000,
    )
    stage = await _successful(call, action="read", path="STAGE.md")
    await _successful(
        call,
        action="write",
        path="STAGE.md",
        text=f"# Stage cursor\n\nBase ledger SHA-256: {ledger['sha256']}\n",
        if_sha256=str(stage["sha256"]),
    )
    await _successful(call, action="read", path="STAGE.md")


async def _stage_reviewer(prompt: str, call: ToolCall) -> None:
    refreshed = _match(r"Transaction `([^`]+)`", prompt).group(1)
    stage = await _successful(call, action="read", path="STAGE.md")
    stored = _match(r"Base ledger SHA-256: ([0-9a-f]{64})", str(stage["text"])).group(1)
    _, _, current_text = await _read_ledger(call)
    stale = await call(
        action="write",
        path="COLLABORATION.md",
        text=current_text,
        if_sha256=stored,
    )
    error = stale.get("error")
    if stale.get("ok") or not isinstance(error, dict) or error.get("code") != "PRECONDITION_FAILED":
        raise RuntimeError("Plain scripted staged preflight did not observe stale state.")

    def mutate(facts: dict[str, NeutralFact]) -> None:
        drafts = [identifier for identifier, fact in facts.items() if fact.state == "none"]
        if len(drafts) != 2:
            raise RuntimeError("Plain scripted preflight did not find the grouped draft.")
        for identifier in drafts:
            facts[identifier] = replace(facts[identifier], state="open", transaction=refreshed)

    await _mutate_ledger(call, mutate)
    await _successful(call, action="read", path="STAGE.md")


async def _directory_author(prompt: str, call: ToolCall) -> None:
    await _successful(call, action="list", path=".")
    actor = _actor(prompt)
    reply_body, reply_id, handoff_path, next_actor, handoff_id, handoff_body = _match(
        r"Reply with exactly this Markdown body:\n(.+?)\nUse reply fact id ([0-9a-f-]+).*?"
        r"handoff fact in (\S+) for actor (urn:\S+)\. Use handoff fact id\n"
        r"([0-9a-f-]+).*?exactly this handoff body:\n(.+?)\nVerify",
        prompt,
    ).groups()

    def mutate(facts: dict[str, NeutralFact]) -> None:
        human_roots = [fact for fact in facts.values() if fact.parent is None and fact.state == "open"]
        if len(human_roots) != 1:
            raise RuntimeError("Plain scripted directory preflight did not find the human root.")
        root = human_roots[0]
        _resolved_thread(facts, root, NeutralFact(
            id=reply_id,
            kind="reply",
            file=root.file,
            author=actor,
            state="resolved",
            parent=root.id,
            root=root.id,
            body=reply_body.strip(),
        ))
        facts[handoff_id] = NeutralFact(
            id=handoff_id,
            kind="handoff",
            file=handoff_path,
            author=actor,
            state="open",
            root=handoff_id,
            body=handoff_body.strip(),
            next_actor=next_actor,
            audience=(next_actor,),
        )

    await _mutate_ledger(call, mutate)


def _candidate_rows(source: str) -> list[tuple[str, int, str, str]]:
    return [
        (name.strip(), int(latency), encrypted, isolated)
        for name, latency, encrypted, isolated in re.findall(
            r"^- ([^|\n]+) \| latency=(\d+) \| encrypted=(yes|no) \| isolated=(yes|no)$",
            source,
            re.MULTILINE,
        )
    ]


async def _specialist(prompt: str, call: ToolCall) -> None:
    actor = _actor(prompt)
    path = _match(r"for (architecture/proposal\.md)|Read (architecture/proposal\.md)", prompt)
    source_path = next(value for value in path.groups() if value is not None)
    source = await _successful(call, action="read", path=source_path, max_lines=2_000)
    rows = _candidate_rows(str(source["text"]))
    identifier = _match(r"id ([0-9a-f-]+)", prompt).group(1)
    if "performance specialist" in prompt:
        choice = min(rows, key=lambda item: item[1])[0]
        kind = "decision"
        body = f"Performance choice: {choice}."
    else:
        ledger, _, _ = await _read_ledger(call)
        decision = next(fact for fact in ledger.facts if fact.kind == "decision")
        performance = _match(r"Performance choice: (.+)\.", decision.body).group(1)
        secure = min(
            (row for row in rows if row[2:] == ("yes", "yes")),
            key=lambda item: item[1],
        )[0]
        kind = "issue"
        body = f"Security correction: {performance} is ineligible; choose {secure}."

    def mutate(facts: dict[str, NeutralFact]) -> None:
        facts[identifier] = NeutralFact(
            id=identifier,
            kind=kind,
            file=source_path,
            author=actor,
            state="open",
            root=identifier,
            body=body,
        )

    await _mutate_ledger(call, mutate)


async def run_plain_scripted_role(prompt: str, call: ToolCall) -> None:
    """Execute one public role brief without an oracle or another role's prompt."""
    topic = (
        "staging"
        if "coherent two-file draft" in prompt or "multi-file draft" in prompt
        else "suggestions"
        if "suggestions" in prompt
        else "facts"
    )
    await _successful(call, action="guide", topic=topic)
    if "A human left one open thread in review.md" in prompt:
        await _reply_to_open_root(prompt, call)
    elif "Create one handoff fact in review.md" in prompt:
        await _handoff_author(prompt, call)
    elif "Find the durable handoff in review.md" in prompt:
        await _reply_to_open_root(prompt, call, kind="handoff")
    elif "Another agent is acting at the same time" in prompt or "low-coupling parallel review" in prompt:
        await _issue_author(prompt, call)
    elif (
        "Create two resilient suggestions" in prompt
        or "record two resilient suggestion facts" in prompt
    ):
        await _suggestion_author(prompt, call)
    elif "Review the two durable suggestions" in prompt:
        await _suggestion_reviewer(prompt, call)
    elif "Create, but do not finalize, one coherent two-file draft" in prompt:
        await _stage_author(prompt, call)
    elif "A prior agent left a coherent multi-file draft" in prompt:
        await _stage_reviewer(prompt, call)
    elif "Begin with bounded directory context" in prompt:
        await _directory_author(prompt, call)
    elif "find the open handoff in notes/status.md" in prompt:
        await _reply_to_open_root(prompt, call, kind="handoff")
    elif "performance specialist" in prompt or "independent security specialist" in prompt:
        await _specialist(prompt, call)
    elif "Your role-private evidence token" in prompt:
        await _handoff_author(prompt, call)
    elif "your role-private evidence token" in prompt:
        actor = _actor(prompt)
        evidence_b, reply_id = _match(
            r"token is `([^`]+)`.*?reply with reply fact id\n([0-9a-f-]+)",
            prompt,
        ).groups()

        def mutate(facts: dict[str, NeutralFact]) -> None:
            roots = [fact for fact in facts.values() if fact.kind == "handoff" and fact.state == "open"]
            if len(roots) != 1:
                raise RuntimeError("Plain scripted synthesis did not find one handoff.")
            root = roots[0]
            evidence_a = _match(r"Evidence A: ([^.]+)\.", root.body).group(1)
            _resolved_thread(facts, root, NeutralFact(
                id=reply_id,
                kind="reply",
                file=root.file,
                author=actor,
                state="resolved",
                parent=root.id,
                root=root.id,
                body=f"Synthesis: {evidence_a} + {evidence_b}.",
            ))

        await _mutate_ledger(call, mutate)
    else:
        raise ValueError("Plain scripted preflight received an unknown role brief.")
