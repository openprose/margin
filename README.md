# Margin

Margin is a fast, native Markdown editor for precise collaboration between humans and agents. It keeps the literal Markdown visible, gives reading its own calm mode, and stores threaded review comments and typed contributions inside the document itself.

There is no account, server, database, daemon, WebView, plug-in runtime, or model dependency. The macOS app and command line use the same Swift protocol engine. Markdown files remain portable authorities; an optional `.margin` directory adds workspace identity, pending stages, short-lived recovery journals, and bounded durable activity for directory-wide coordination.

## What works

- Open a Markdown file or a directory from Terminal.
- Keep several documents open in native macOS tabs.
- Browse directories in a lazy native tree without recursively indexing them at launch.
- Edit literal Markdown with restrained syntax cues, delimiter pairing, list continuation, native undo, find, spellcheck, and accessibility.
- Switch to a bounded, typography-first reader view.
- Select a passage and comment from the inline bubble, the context menu, or `⌘⌥M` in either source or reader mode.
- Review clickable source highlights and reader-margin markers, reply to any depth, edit or delete your own comments, and resolve or reopen whole threads.
- Let agents inspect, outline, slice, review, watch, create, edit, delete, reply to, and validate the same document through structured CLI commands.
- Give agents a bounded directory context, stable collaborator identities, factual activity, filtered inboxes, typed questions/issues/decisions/tasks/approvals, source suggestions, and cursor-bound handoffs.
- Stage related operations across several files and submit them all-or-none with compare-and-swap checks, deterministic crash recovery, and idempotent retries.
- Preserve comment metadata as an ignorable terminal HTML comment containing W3C Web Annotation JSON-LD.

Margin currently targets Apple silicon Macs running macOS 13 or newer. The v0.3 package is ad-hoc signed for local installation because this machine has no Developer ID certificate.

## Build and install

Requirements: macOS and Swift 5.10 or newer. The release build is pinned to Apple's current Command Line Tools on this Mac; `make test` selects a full local Xcode because its XCTest runner is not included in this host's Command Line Tools.

```sh
cd ~/code/margin
make test
make install
```

This installs `Margin.app` in `~/Applications` and `margin` in `~/.local/bin`. If that directory is not already on `PATH`, add it once in your shell configuration.

To create one macOS installer containing both the app and command-line tool:

```sh
make installer
open build/Margin-0.3.2-macOS-arm64.pkg
```

The installer places `Margin.app` in `/Applications` and `margin` in
`/usr/local/bin`. The local build is unsigned at the installer level. A public
release can set `MARGIN_APP_SIGNING_IDENTITY` and
`MARGIN_INSTALLER_SIGNING_IDENTITY` to the corresponding Apple Developer ID
certificates. Setting `MARGIN_NOTARY_PROFILE` to an existing `notarytool`
keychain profile submits, staples, and validates that signed installer as part of
the same build.

To build without installing:

```sh
make release
open build/Margin.app
```

## The happy path

```sh
# Open one document.
margin architecture.md

# Open a workspace with a directory navigator.
margin ~/code/my-project

# Open several documents as tabs in one window.
margin brief.md architecture.md review-notes.md

# Block the terminal until this Margin window closes.
margin architecture.md --wait
```

In the app, select a passage to reveal a small comment affordance, use the native context menu, or press `⌘⌥M`. The same flow works in reader mode. Commented passages remain clickable in source, while reader mode adds quiet margin markers. A document with no comments opens without an inspector; a reviewed document reveals its conversation automatically. Later replies from an agent add a tab/toolbar unread indicator without interrupting the current task. `⌘⇧R` toggles reader mode, `⌘0` toggles the directory navigator, and `⌘⌥0` toggles comments. The window supports native macOS full screen with `⌃⌘F`.

Navigation stays keyboard-first:

- `⌘P` searches and opens files by fuzzy filename or path. Directory indexing begins only when the palette opens.
- `⌘⇧P` opens the command palette; recent workspaces are read only when that palette appears.
- `⌘⇧O` searches headings in the current document.
- `⌘⌥[` and `⌘⌥]` move through open review threads in source order; Review → Go to Comment searches passages, authors, and status.
- `⌘⌥←` and `⌘⌥→` open the previous or next visible file in the navigator.
- `⌘T` opens a tab, `⌘N` opens a separate window, and `⌘W` closes the current tab.
- `⌃Tab` / `⌃⇧Tab` (or `⌘⇧]` / `⌘⇧[`) move through tabs; `⌘1`…`⌘9` select them directly.
- `⌃1`, `⌃2`, and `⌃3` focus the navigator, editor, and comments respectively.

Margin restores the previous tabs, active document, reader/source state, sidebars, selection, scroll position, and active thread after a normal relaunch. An explicit file or directory supplied on the command line always takes precedence over restoration.

Formatting shortcuts write ordinary Markdown characters: `⌘B` for bold, `⌘I` for emphasis, and `⌘K` for a link. Margin never replaces the source with hidden rich-text state.

## Agent workflow

Start with the self-describing contract and a bounded context instead of reading files or the embedded envelope indiscriminately:

```sh
margin man
margin man review
margin capabilities --json --for review
margin context ~/code/my-project --json --max-files 64 --pretty
margin inbox ~/code/my-project --status open --pretty
```

`margin man` is the stable teaching entry point for humans and agents. Its
focused pages—`review`, `comments`, `suggestions`, `staging`, `handoff`, `merge`,
and `safety`—explain judgment and safe defaults. The capability projections
remain the exact machine-readable command contract, while `COMMAND --help`
provides leaf-level syntax. The older `margin help agents` entry remains an alias
for the manual overview.

Workflow projections are also available for `staging`, `suggestions`, `handoff`,
and `merge`. They retain the versioned machine contract while avoiding the cost
of repeatedly loading commands unrelated to the current task. The complete
catalog remains available as `margin capabilities --json`.

A plain Markdown file is already a collaboration root. Initialize a directory only when stable workspace identity and cross-file stages are useful:

```sh
margin workspace init ~/code/my-project
margin workspace show ~/code/my-project --pretty
```

Add a resilient passage contribution. `comment`, `question`, `issue`, `decision`, `task`, and `approval` share the same thread and anchor model:

```sh
margin comments add architecture.md \
  --kind question \
  --quote "The queue is the source of truth." \
  -m "What guarantees ordering during replay?" \
  --actor-type software \
  --actor-name "architecture-reviewer" \
  --id 0af41cb0-63c6-4f1c-aab6-a0e1726278da
```

Then inspect and continue the thread:

```sh
margin comments list architecture.md --status all --pretty
margin comments reply architecture.md COMMENT_ID \
  -m "I verified this against the recovery path." \
  --actor-type software --actor-name "implementation-agent"
margin comments resolve architecture.md COMMENT_ID \
  --actor-type software --actor-name "implementation-agent"
margin comments validate architecture.md --pretty
```

Propose a source edit without applying it, then let a human or another agent accept or reject it atomically:

```sh
margin suggest add architecture.md \
  --quote "at least once" \
  --replacement "exactly once after durable acknowledgement" \
  -m "Make the delivery guarantee explicit" \
  --actor-type software --actor-name "architecture-reviewer" --id UUID

margin suggest list architecture.md --pretty
margin suggest accept architecture.md SUGGESTION_ID \
  --actor-type person --actor-name "reviewer"
```

Record a durable handoff so the next agent needs no transcript from the previous one:

```sh
margin handoff add ~/code/my-project --path architecture.md \
  -m "Recovery is verified; ordering remains unresolved." \
  --touched COMMENT_ID --unresolved ISSUE_ID --next-actor urn:agent:verification \
  --actor-id urn:agent:architecture --actor-type software --id UUID
```

For one all-or-none update spanning files, create an immutable operation plan, inspect it, and submit it. `stage submit` refuses stale cursors without changing any file:

```json
{
  "schema": "urn:margin:stage-intent:v1",
  "version": 1,
  "operations": [
    {"kind":"contribution","path":"architecture.md","contributionKind":"decision","body":"Use a durable write-ahead journal."},
    {"kind":"contribution","path":"operations.md","contributionKind":"task","body":"Add a recovery drill.","assignee":"urn:agent:operations","priority":"high"}
  ]
}
```

```sh
margin stage create ~/code/my-project --operations-file plan.json \
  --request-id urn:request:recovery-plan \
  --actor-id urn:agent:architecture --actor-type software
margin stage list ~/code/my-project --pretty
margin stage show ~/code/my-project STAGE_ID --pretty
margin stage submit ~/code/my-project STAGE_ID --pretty
```

`stage list` is metadata-only and bounded by both count and aggregate bytes.
`stage show` adds bounded contribution, suggestion, task, and handoff previews,
but never prints staged file bytes or raw cursor tokens. If submission reports a
stale cursor, refresh the exact hidden plan against current annotation metadata
instead of reconstructing it:

```sh
margin stage refresh ~/code/my-project STAGE_ID --pretty
margin stage show ~/code/my-project REFRESHED_STAGE_ID --pretty
margin stage submit ~/code/my-project REFRESHED_STAGE_ID --pretty
margin stage discard ~/code/my-project STAGE_ID --pretty
```

Refresh creates a distinct immutable stage, retains the prior stage, records
their lineage, and is idempotent. It refuses logical-source drift, broken
selectors, changed direct-file targets, and mismatched suggestion text rather
than silently rebasing intent.

For a long-lived collaborator, watch one file without polling:

```sh
margin comments watch architecture.md --jsonl --since-revision 12
```

Agents can revise or safely remove their feedback while preserving the thread model:

```sh
margin comments edit architecture.md COMMENT_ID -m "A more precise finding." \
  --actor-type software --actor-name "architecture-reviewer" --if-revision 13
margin comments delete architecture.md REPLY_ID --if-revision 14
margin comments delete architecture.md ROOT_ID --subtree --if-revision 15
```

`context`, `inbox`, `review`, `slice`, and every directory scan are explicitly bounded and report truncation. `watch` emits compact JSONL changes after an initial snapshot. Deleting a contribution that has replies fails unless `--subtree` is explicit.

Every collaboration mutation prints one JSON object to stdout. Errors print JSON to stderr, leave stdout empty, and use stable codes plus sysexits-compatible status values. Agents should use stable actor IDs, `--id` or `--request-id` for retries, and returned cursors or compare-and-swap flags when coordinating concurrent writes.

Run `margin COMMAND SUBCOMMAND --help` for exact local grammar. The [comment embedding contract](COMMENT_PROTOCOL.md), [directory collaboration protocol](Docs/COLLABORATION_PROTOCOL.md), and [collaboration eval design](Docs/COLLABORATION_EVALS.md) are versioned in the repository.

## Where comments live

Comments are persisted in the Markdown file itself—not in a database, sidecar, or hidden application folder. Margin appends one terminal CommonMark HTML comment beginning with `<!-- margin:comments:v1`; inside it is a JSON-LD annotation page containing thread bodies, replies, actors, status, and resilient text anchors. Ordinary Markdown renderers ignore that block, while Margin hides it from both source editing and reader mode.

The bytes before the envelope remain the logical Markdown body. Use `margin read FILE` to print only that body, `margin comments export FILE --format jsonld` to inspect the annotations, and `margin comments validate FILE` to verify the combined document.

## Architecture

Margin is intentionally small:

- **AppKit + TextKit 1** for the native window, tree, editor, reader, and comment inspector.
- **MarginCore** for Unicode coordinates, resilient anchors, JSON-LD encoding, locking, and atomic document mutation.
- **MarginCore collaboration layer** for bounded contexts, cursors, stages, semantic operations, shared document locks, write-ahead recovery, reconciliation, and three-way annotation merge.
- **margin** for terminal launch plus deterministic human/agent collaboration operations and a static capability catalog.
- **SwiftPM** for reproducible builds with no third-party runtime dependencies.

The directory tree loads one expanded folder at a time. Highlighting uses temporary TextKit attributes and does not change document bytes. Ordinary writes lock by canonical file path, reread before mutation, preserve file metadata, and atomically replace the file only after conflict checks. Cross-file submissions acquire the same document locks in canonical order plus one root lock; they stage complete validated images and retain a durable recovery journal until the set is committed.

## Verification

```sh
make test              # unit and concurrency tests
make eval              # deterministic CLI-agent eval oracles and harness tests
make eval-collaboration # strict twelve-scenario directory-collaboration gate
make smoke             # packaged CLI and application smoke tests
make benchmark         # local launch and footprint measurements
make installer         # one local macOS package installing the app and CLI
make package           # portable zip and one-file installer, each with checksum
make test-linux        # portable core/CLI gate in pinned Swift Linux
make marginbench-test  # provider-neutral benchmark contracts and exact oracles
make marginbench-preflight # all Prime roles through a local fake model; no spend
make marginbench-package   # Linux-verified wheel and source archive
```

The original real-agent benchmark lives in `Benchmarks/agent_benchmark`. The hill-climbing suite in `Evals/cli` expands it into six single-document task families. `Evals/collaboration` adds twelve secret-seeded relay environments for human-to-agent, agent-to-agent, concurrent, staged multi-file, suggestion, recovery, and merge workflows. `Evals/marginbench` packages the provider-independent public benchmark, reproducible Linux CLI, and Prime Verifiers adapter. All three systems grade final protocol state rather than model prose and keep paid execution behind explicit caps and confirmation.

Measured launch results, agent benchmarks/evals, and the complete verification record are in `Docs/PERFORMANCE.md`, `Docs/AGENT_BENCHMARK.md`, `Docs/CLI_EVALS.md`, and `Docs/RELEASE_NOTES.md`.

## Scope

Margin 0.3 deliberately excludes hosted sync, accounts, general rich text, plug-ins, and LLM-powered filters. Collaboration is local and file-native: durable actors and activity are facts, never speculative “online” presence. Summarizers and semantic lenses remain a later layer; bounded contexts and event-driven review streams support them without coupling a document to a model provider.
