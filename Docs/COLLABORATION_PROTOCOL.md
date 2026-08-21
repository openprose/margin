# Margin collaboration protocol

Margin treats Markdown as the durable collaboration medium. A file is always a valid standalone collaboration root. A directory can opt into a workspace root by adding `.margin/workspace.json`; individual Markdown files remain portable when copied away from that workspace.

## Invariants

1. The logical Markdown body remains ordinary UTF-8 Markdown.
2. Comments, replies, typed contributions, suggestions, decisions, tasks, and handoffs remain ignorable annotations in the terminal Margin envelope.
3. No collaboration command requires a daemon, database, account, or network request.
4. Directory scans, collaborator aggregation, stage loading, and activity computation occur only when explicitly requested.
5. Every read returns a versioned cursor. Every conditional mutation can use that cursor as its complete compare-and-swap base.
6. Every mutating request has an idempotency identity.
7. A staged change set is immutable once submitted and is applied entirely or not at all for workspace-consistent Margin reads.
8. Unknown namespaced annotation and workspace fields round-trip unchanged.

## Root and workspace

Without a workspace manifest, a file is its own root. An explicit directory target is a transient root whose Markdown files are discovered lazily and within caller-supplied bounds.

`margin workspace init DIRECTORY` creates `.margin/workspace.json` containing a stable workspace UUID, protocol version, creation time, and optional include/exclude rules. `.margin/stages` contains workspace-local pending change-set JSON whose cursor is intentionally bound to that root and exact file state. The Markdown annotations themselves remain portable; a stage should be recreated after moving or copying a workspace. `.margin/transactions` contains short-lived crash-recovery journals and is empty after a successful submit or recovery. `.margin/activity` contains bounded, immutable transaction facts used by explicit collaboration views.

The root is never inferred from the current process directory alone. For a file inside a workspace, Margin walks ancestors only until it finds `.margin/workspace.json`, a filesystem boundary, or the caller's explicit root.

## Cursor

A cursor binds:

- collaboration-root identity;
- protocol version;
- a deterministic ordered set of relative file paths;
- each file's document UUID when present;
- logical Markdown SHA-256;
- annotation revision;
- whole-file SHA-256 for exact recovery.

The command-line token is a `mcur1:` base64url encoding of canonical JSON. It is not secret or trusted merely because it is encoded. Margin validates every field against current state.

## Typed contributions

V1 comments remain W3C Annotation roots with `motivation: commenting`; replies remain `motivation: replying`. Additional collaboration meaning is carried by namespaced extensions so existing readers continue to work:

- `margin:kind`: `comment`, `question`, `issue`, `decision`, `task`, `suggestion`, `handoff`, or `approval`;
- `margin:audience`: actor IDs;
- `margin:assignee`: actor ID;
- `margin:priority`: `low`, `normal`, `high`, or `urgent`;
- `margin:suggestion`: expected text, replacement text, base content digest, and suggestion status;
- `margin:handoff`: starting cursor, finishing cursor, touched annotation IDs, unresolved IDs, and intended next actors;
- `margin:transaction`: request and stage IDs.

Suggestion acceptance verifies the stored base and live anchor, replaces only the intended logical Markdown range, refreshes surviving selectors, records acceptance provenance, and advances the annotation revision in the same document write. Rejection preserves source bytes.

## Context and collaborators

`margin context FILE_OR_DIRECTORY --json` is the canonical bounded agent entry point. It returns root identity, cursor, files, outline summaries, source-ordered open work, anchor health, stable short references, collaborators, truncation details, and structured available actions.

Collaborator activity is factual and durable: first and last observed annotation or transaction time, contribution counts by kind, files touched, open assignments, and authored unresolved work. Margin does not claim an actor is online. A future opt-in live-presence transport must remain separate from durable document truth.

## Staging and transactions

A change set contains a root, base cursor, actor, request ID, ordered operations, and creation time. Operations may span files and may create comments, replies, typed contributions, suggestions, handoffs, status changes, or accepted source replacements.

`margin suggest add FILE` reads a bare item array from standard input when no
single-item selector flags are present; `--items-file ...` reads the same input
from a path. `margin suggest batch` remains an exact alias. The operation
accepts 1 to 256 exact suggestion assignments in at most 1 MiB of JSON,
validates every expected passage against one captured source, and advances the
file's annotation revision once. Any invalid anchor, changed source, duplicate ID, or payload
conflict rejects the entire batch. Independent annotation-only movement may be
retried internally while the logical Markdown hash remains identical. Cross-file
all-or-none work uses an immutable directory stage instead.

`margin suggest wait FILE ID...` is an on-demand durable-state predicate for a
known public suggestion set. It watches one Markdown file until every named
suggestion is embedded or a bounded timeout expires. It starts no daemon and
does not infer live presence, collaborator completion, or unlisted work. This
keeps durable document truth separate from any future opt-in presence transport.

Stage listing is metadata-only and bounded by both entry count and aggregate
canonical bytes. Explicit stage inspection returns bounded semantic previews and
digests for contribution bodies, suggestions, tasks, and handoffs; raw staged
file images and cursor tokens are never projected. Truncation is always reported.

`margin stage refresh` derives a new immutable stage from the exact stored plan
when only collaboration metadata or unrelated cursor state has moved. The old
stage remains unchanged. Refresh preserves authored operations, bodies, actor,
request identity, timestamp, and caller extensions; it adds deterministic parent
stage/change-set provenance and replaces only the base cursor and derived stage
identities. Exact replay returns the same stage. Logical Markdown drift on a
semantic target, a changed direct-file precondition, a broken selector, or a
suggestion text mismatch fails closed and creates nothing.

Submission:

1. resolves every path below the declared root without following an escape symlink;
2. acquires per-file locks in canonical path order plus one workspace submission lock;
3. rereads every input and verifies the complete base cursor;
4. evaluates every operation in memory and validates every resulting document;
5. writes same-directory temporary files and fsyncs them;
6. records a write-ahead recovery journal and fsyncs it;
7. installs replacements in deterministic order;
8. rolls back from exact backups on any ordinary failure;
9. fsyncs affected directories and marks the journal complete;
10. records a bounded immutable activity fact and removes recovery material only after the committed state is durable.

Workspace-consistent Margin operations such as `context`, transaction evaluation, and recovery acquire the workspace submission lock, so they never observe an intermediate multi-file state. Each individual file is always replaced atomically and remains valid. POSIX does not provide one atomic rename across multiple independent files, so an ordinary single-file view or an external reader can theoretically observe the short interval between file installs. A crash leaves a recoverable journal, never a silently ambiguous transaction.

## Distributed merge and reconciliation

`margin reconcile` is an explicit recovery path for Markdown changed outside Margin when a known-good previous copy proves the exact, unchanged terminal envelope bytes. It does not guess a body/envelope boundary from a damaged or missing suffix. Within that fail-closed boundary it resolves quote selectors against the new logical body, refreshes unambiguous positions, reports every ambiguous/orphaned anchor, and writes only with explicit confirmation and policy.

`margin merge` performs a three-way semantic merge of annotation graphs by stable ID, detects competing edits/status transitions/deletions, preserves independent additions, delegates logical Markdown merging to an explicit base/ours/theirs result, and re-resolves anchors against the merged body. It is suitable for an optional Git merge driver but remains useful without Git.

## Performance contract

- Existing file/directory launch performs none of this work before the first window.
- Help and capabilities use static data and perform no filesystem access.
- File context reads one file once. Directory context is explicitly invoked, bounded by file/byte/result budgets, and streams or truncates deterministically.
- Workspace manifests and stages are loaded only by collaboration commands or an explicitly opened collaboration palette.
- Stage lists have count and aggregate-byte budgets; stage detail has a hard output cap and bounded field previews.
- The app constructs collaborator, suggestion, task, and stage presentation only after the user opens the review surface.
- Release verification compares the exact signed candidate against the current launch baseline and rejects a statistically meaningful regression.
