# Margin command-line guide

The `margin` command is both the Mac app launcher and a deterministic interface
to Margin's file-native review protocol. The review and collaboration commands
run on macOS and Linux and do not require an account, daemon, database, network
connection, or graphical app.

For exact grammar, use the executable itself:

```sh
margin man
margin man review
margin man status.md
margin COMMAND --help
margin capabilities --json --for review
```

`margin man` teaches safe workflows. Command help is the exact leaf syntax,
and `capabilities` is the versioned machine-readable contract. Natural manual
topics such as `directory`, `folder`, `workspace`, `context`, and `inbox` lead
to the corresponding workflow. A simple relative Markdown filename leads to a
bounded target-oriented page without opening or inspecting that file; unsafe,
absolute, parent-traversing, or option-like strings still fail closed.

## Platform support

| Capability | macOS | Linux |
| --- | --- | --- |
| Read, inspect, outline, slice, and review Markdown | Yes | Yes |
| Create and manage comments and typed contributions | Yes | Yes |
| Context, inbox, collaborators, suggestions, and handoffs | Yes | Yes |
| Workspaces, stages, transactions, reconciliation, and merge | Yes | Yes |
| Watch a document for comment changes | Yes | Yes |
| Launch the native Margin editor | Yes | No |

Bare `margin`, `margin FILE`, `margin DIRECTORY`, and `margin open ...` are app
launcher forms. On Linux they fail with the stable `APP_UNAVAILABLE` error; they
are not aliases for reading a file. Use an explicit operation such as
`margin read FILE` or `margin context DIRECTORY --json` on Linux.

## Read without exposing metadata

The default text read prints only the logical Markdown body. It omits the
terminal embedded annotation envelope:

```sh
margin inspect README.md --json --pretty
margin outline README.md --json --pretty
margin read README.md
margin slice README.md --heading "Architecture" --context 2
margin review README.md --json --pretty
```

Reads are bounded where their result can grow with a document or directory.
Structured results report truncation rather than silently presenting an
unbounded partial view.

## Review and comment

Start with a bounded review, then attach a question to an exact quote:

```sh
margin review architecture.md --json --pretty

margin comments add architecture.md \
  --kind question \
  --quote "The queue is the source of truth." \
  -m "What guarantees ordering during replay?" \
  --actor-type software \
  --actor-name architecture-reviewer \
  --id 0af41cb0-63c6-4f1c-aab6-a0e1726278da
```

List the thread, reply, and validate the resulting document:

```sh
margin comments list architecture.md --status all --pretty

margin comments reply architecture.md COMMENT_ID \
  -m "Verified against the recovery path." \
  --resolve \
  --if-revision OBSERVED_REVISION \
  --actor-type software \
  --actor-name implementation-agent \
  --id UUID

margin comments validate architecture.md --pretty
```

`comment`, `question`, `issue`, `decision`, `task`, and `approval` use the same
thread and anchor model. Mutations emit one JSON object on standard output.
Errors leave standard output empty, emit structured details on standard error,
and use stable codes with sysexits-compatible statuses.

Independent typed additions without `--if-revision` retry a bounded number of
annotation-only races inside one CLI call. Margin first proves that the logical
Markdown has not changed. A source edit or an explicit revision guard still
fails closed, so agents must reread rather than weakening the precondition.

## Directory collaboration

A Markdown file is already a collaboration root. Initialize a directory only
when stable workspace identity and cross-file staging are useful:

```sh
margin workspace init .
margin context . --json --brief
margin inbox . --status open --brief --pretty
margin collaborators . --pretty
```

`context --brief` is the normal agent entry point. It uses a 512-byte source
preview by default and orients on at most four files, one work item per file,
four headings per file, 2 MiB of discovered Markdown, and eight directory
levels. It omits the cursor, activity history, repeated explanatory prose, and
extended metadata while keeping concrete reply, resolve, verification,
suggestion, and handoff actions. Truncation is explicit; use `inbox`, a targeted
`--path`, or an explicit limit override for omitted work. Use full `context`
only when the next operation needs its cursor, activity, or extended metadata.

`inbox --brief` still filters across the normal bounded directory search; it
only removes the large workspace cursor from the response. Each returned item
keeps its exact action path and annotation revision. Use full `inbox` when the
next operation specifically needs the cursor.

An initialized workspace stores coordination data under `.margin/`. Comments
and other document annotations remain embedded in their Markdown files and
remain portable when those files are copied elsewhere.

## Suggestions and handoffs

Suggestions propose source changes without applying them:

```sh
printf '%s' '[
    {"id":"UUID-1","exact":"at least once","replacement":"exactly once",
     "body":"Make the delivery guarantee explicit"},
    {"id":"UUID-2","exact":"best effort","replacement":"bounded retry",
     "body":"Name the actual recovery behavior"}
]' | margin suggest add architecture.md

margin suggest add architecture.md \
  --quote "at least once" \
  --replacement "exactly once after durable acknowledgement" \
  -m "Make the delivery guarantee explicit" \
  --actor-type software \
  --actor-name architecture-reviewer \
  --id UUID

margin suggest list architecture.md --pretty
margin suggest wait architecture.md UUID-1 UUID-2 --timeout 20
margin suggest accept architecture.md SUGGESTION_ID \
  --actor-type person --actor-name reviewer
```

Use bare standard input or `suggest add --items-file` when one collaborator
already has several exact assignments for one file. Margin validates every
quoted passage first, then commits all 1 to 256 proposals in one document
revision. One missing or changed
passage rejects the whole batch. Stable item IDs make exact replay safe, and
literal Markdown is never changed by creation. `suggest batch` remains an exact
alias. Use directory staging instead when one all-or-none decision spans files.

When collaborators already share a complete public set of expected suggestion
IDs, `suggest wait FILE ID... --timeout 20` replaces repeated list polling. It
watches that one file only while the command is running and returns the observed
revision, source digest, and up to 64 compact ID/status pairs (with an explicit
omitted count) once all named suggestions are durable. Success says nothing about
whether another collaborator is online, finished with unrelated work, or free of
additional assignments. With no complete ID set, use `suggest list` instead.

Independent suggestion additions retry bounded annotation-only races inside one
CLI call when the logical Markdown is unchanged. Independent rejections do the
same only while both the source and the exact reviewed suggestion are unchanged.
Accepting a suggestion changes source and never silently rebases: a concurrent
change remains a visible conflict that must be reread. This makes metadata-only
collaboration convenient without weakening source decisions.

A durable handoff carries the current state without requiring the next agent to
receive the previous agent's transcript:

```sh
margin handoff add . --path architecture.md \
  -m "Recovery is verified; ordering remains unresolved." \
  --touched COMMENT_ID \
  --unresolved ISSUE_ID \
  --next-actor urn:agent:verification \
  --actor-id urn:agent:architecture \
  --actor-type software \
  --id UUID
```

Handoffs remain bound to the state the author actually observed. Margin does not
hide a concurrent root change by silently refreshing that state; reread and
reauthor the handoff so its provenance remains truthful. A precondition failure
now states that no handoff was written and returns structured fields:
`automaticRetrySafe:false`, `recoveryTarget`, the recovery command
`margin context TARGET --json`, and the review command
`margin handoff list TARGET`. Reconsider touched and unresolved work, audience,
and recipients before intentionally repeating the stable mutation ID. Do not put
a provenance-sensitive handoff into a blind retry loop.

## Safe automation

Agents and scripts should:

- start with `margin man TOPIC --json` or a workflow-specific capability
  projection instead of parsing source code or the raw annotation envelope;
- copy observed revisions and cursors exactly—zero is valid—and use them as
  compare-and-swap preconditions;
- give actors and retryable mutations stable IDs;
- let independent additions and rejections use Margin's bounded internal retry,
  but treat accept and handoff conflicts as instructions to reread;
- follow returned actions and truncation metadata rather than guessing paths;
- validate a document after an unfamiliar workflow;
- use `--request-id` only for commands whose help advertises it.

For a long-lived process, watch changes without polling:

```sh
margin comments watch architecture.md --jsonl --since-revision 12
```

For an all-or-none update across files, use an immutable stage and inspect it
before submission:

```sh
margin stage create . --operations-file plan.json \
  --request-id urn:request:recovery-plan \
  --actor-id urn:agent:architecture \
  --actor-type software
margin stage show . STAGE_ID --pretty
margin stage submit . STAGE_ID --pretty
```

If the base cursor is stale, `margin stage refresh` creates a new immutable
stage only when the authored intent is still safe to replay. It refuses source
drift and broken selectors rather than silently rebasing them.

## macOS launcher

On macOS, the same executable can open one or more documents in the native app:

```sh
margin README.md
margin brief.md architecture.md
margin .
margin architecture.md --wait
```

The CLI searches for `Margin.app` in `~/Applications` and `/Applications`.
Set `MARGIN_APP_PATH` when the bundle is stored elsewhere. These launcher forms
are deliberately separate from the cross-platform collaboration commands.

See the [embedded comment protocol](../COMMENT_PROTOCOL.md) and
[directory collaboration protocol](COLLABORATION_PROTOCOL.md) for the durable
data contracts.
