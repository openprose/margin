# Margin

**A fast, native Markdown editor for macOS, with file-native comments and a standalone CLI for human-agent collaboration.**

Margin keeps Markdown literal and portable. It adds a calm reading mode, precise passage-level discussion, and structured collaboration without moving the document into an account, database, or hosted service. The Mac app and the `margin` command use the same Swift core; the CLI also runs independently on Linux.

> **Why OpenProse is publishing Margin:** We built Margin for the OpenProse team's own Markdown writing and review workflow, then decided to share it because it is useful on its own. Margin is an independent open-source tool—not the OpenProse product and not a required part of the OpenProse platform.

## Why Margin

- **Fast and native.** Margin is a focused AppKit application, not an IDE or browser-hosted workspace. It opens into a real, editable document window in a few hundred milliseconds on our [reference system](Docs/PERFORMANCE.md).
- **Literal Markdown.** Every Markdown character stays visible and ordinary Markdown remains the source of truth. Reader mode changes the presentation, never the file format.
- **Comments that travel.** Threads, replies, suggestions, decisions, tasks, approvals, and handoffs stay with the document in an ignorable metadata block. Git and ordinary Markdown tools continue to work.
- **One surface for humans and agents.** People can write and review in the Mac app. Agents and automation can use the deterministic, machine-readable CLI on macOS or Linux.

Margin has no built-in account, sync service, server, database, daemon, WebView, plug-in runtime, or model dependency. Your files can still be stored and synchronized anywhere you choose.

## Install Margin 0.5.0

Download the artifacts from [GitHub Releases](https://github.com/openprose/margin/releases).

### macOS app and CLI

The unified Apple-silicon package installs:

- `Margin.app` in `/Applications`
- `margin` in `/usr/local/bin`

Margin currently supports Apple-silicon Macs running macOS 13 or newer.

The current package is ad-hoc signed at the app and executable level, but the installer itself is unsigned. It is **not** signed with an Apple Developer ID or notarized, so macOS will show Gatekeeper warnings. See [Installation](Docs/INSTALLATION.md) for the safe first-open procedure; you do not need to disable Gatekeeper globally.

Once installed:

```sh
# Open one document in the Mac app.
margin README.md

# Open a directory workspace.
margin .

# Wait until the opened Margin window closes.
margin README.md --wait
```

### Linux CLI

Standalone `margin` CLI archives are available for Linux x86-64 and ARM64. Extract the archive and place the `margin` executable in a directory on `PATH`, commonly `~/.local/bin` for one user or `/usr/local/bin` for the system.

The Linux CLI does not require or include the Mac app. Document and collaboration commands work normally; GUI launch forms such as `margin FILE`, `margin open`, and `--wait` are unavailable.

```sh
margin version
margin read README.md
margin review README.md --json --pretty
```

Checksums are included with each release. For full platform instructions and the source-build path, see [Installation](Docs/INSTALLATION.md).

## A focused Markdown workspace

Open a file for quick editing or a directory for a native, lazily loaded navigator. Margin supports multiple documents in native tabs while keeping the editor at the center of the window.

In the app you can:

- edit literal Markdown with restrained syntax cues, delimiter pairing, list continuation, native undo, find, spellcheck, and accessibility support;
- switch to a bounded, typography-first reader view with `⌘⇧R`;
- select a passage and comment from the inline affordance, context menu, or `⌘⌥M`;
- follow source highlights and reader-margin markers into threaded discussions;
- reply, resolve or reopen threads, and edit or delete your own comments;
- navigate files, headings, commands, and review threads from the keyboard; and
- keep working while comments added by another process appear as quiet unread activity.

Formatting actions write ordinary Markdown delimiters. Margin never replaces the source with hidden rich-text state.

## Humans and agents share the same document

| In the Mac app | From the CLI |
| --- | --- |
| Write and read literal Markdown | Read bounded document or directory context |
| Select passages and start threads | Add, reply to, resolve, edit, and validate comments |
| Review and decide on suggestions | Propose source edits without silently applying them |
| Browse files and open work | Discover inbox items and record durable handoffs |
| Inspect coordinated changes | Stage all-or-none changes across several files |

The CLI teaches its own safe usage:

```sh
margin man
margin man review
margin capabilities --json --for review
```

Two explicit Markdown states can also be compared without teaching Margin
about Git, branches, or any other versioning system:

```sh
# Open the native comparison view on macOS.
margin compare architecture.md proposal.md

# Return a bounded, machine-readable diff to an agent.
margin compare architecture.md proposal.md --json --pretty

# Save a portable review, then add a threaded comment from the CLI.
margin compare architecture.md proposal.md \
  --save-review architecture-review.marginreview
margin compare comments add architecture-review.marginreview \
  --side right --quote "The queue is the source of truth." \
  -m "Please name the ordering guarantee." \
  --actor-type software --actor-name architecture-reviewer
```

A small review workflow looks like this:

```sh
# Inspect a bounded review projection without parsing the file yourself.
margin review architecture.md --json --pretty

# Attach a question to an exact passage.
margin comments add architecture.md \
  --kind question \
  --quote "The queue is the source of truth." \
  -m "What guarantees ordering during replay?" \
  --actor-type software \
  --actor-name architecture-reviewer

# List and validate the resulting document state.
margin comments list architecture.md --status all --pretty
margin comments validate architecture.md --pretty
```

Commands use stable JSON output, explicit actor identity, conflict-aware revisions, and idempotency controls for safe automation. Read the [CLI guide](Docs/CLI.md) for comments, suggestions, handoffs, watches, staging, reconciliation, and merge workflows.

## How comments travel with Markdown

A document with collaboration metadata ends with one CommonMark-compatible HTML comment:

```text
Your ordinary Markdown remains here.

<!-- margin:comments:v1⏎
{ portable annotation data }⏎
-->
```

Here `⏎` denotes a line feed; the glyph itself is not written. Showing it explicitly keeps
this README from being mistaken for a document with a nonterminal Margin metadata block.

Ordinary Markdown renderers ignore the block. Margin hides it from source editing and reader mode, while the CLI can inspect and validate it. The payload follows the W3C Web Annotation data model with Margin extensions for thread state, resilient text anchors, document integrity, and projection rules.

This makes one file the portable authority for both the writing and the discussion around it. See the [embedded comment protocol](COMMENT_PROTOCOL.md) and [directory collaboration protocol](Docs/COLLABORATION_PROTOCOL.md) for the exact contracts.

## What's in this repository

- **Margin for Mac** — the native AppKit editor, reader, navigator, and comment inspector.
- **`margin` CLI** — Mac app launching plus deterministic document and collaboration operations on macOS; standalone collaboration operations on Linux.
- **MarginCore** — the shared Swift implementation for Unicode coordinates, resilient anchors, JSON-LD encoding, locking, atomic mutation, transactions, recovery, reconciliation, and merge.
- **MarginBench** — optional, separately packaged research tooling for testing whether agents can collaborate correctly through documents.

MarginBench is not needed to install or use Margin. It evaluates exact protocol outcomes rather than general writing quality, and its current public results are development evidence rather than a broad claim that Margin improves agent performance. Researchers and contributors can start with the [MarginBench benchmark card](Docs/MARGINBENCH.md).

## Scope

Margin 0.5.0 is deliberately local and file-native. It does not provide hosted sync, accounts, general rich text, plug-ins, or built-in model features. Durable activity records what collaborators did; it does not infer that someone is online.

Current platform support:

| Surface | Support |
| --- | --- |
| Mac app | Apple silicon, macOS 13+ |
| CLI on macOS | App launching and all collaboration commands |
| CLI on Linux | x86-64 and ARM64 collaboration commands; no GUI launching |

Intel Mac support, Developer ID signing, and notarization are future distribution work. See the [roadmap](ROADMAP.md) for other intentionally deferred capabilities.

## Documentation

- [Installation](Docs/INSTALLATION.md)
- [CLI guide](Docs/CLI.md)
- [Architecture](Docs/ARCHITECTURE.md)
- [Embedded comment protocol](COMMENT_PROTOCOL.md)
- [Directory collaboration protocol](Docs/COLLABORATION_PROTOCOL.md)
- [Source-agnostic comparison and review](Docs/COMPARISON_REVIEWS.md)
- [Performance methodology and results](Docs/PERFORMANCE.md)
- [MarginBench](Docs/MARGINBENCH.md)
- [Release notes](Docs/RELEASE_NOTES.md)
- [Contributing](CONTRIBUTING.md)
- [Security policy](SECURITY.md)
- [Release process](RELEASING.md)

## Build and verify

Building the Mac app requires macOS and Swift 5.10 or newer:

```sh
make test
make release
open build/Margin.app
```

The repository also contains deterministic CLI, concurrency, collaboration, packaging, Linux, and MarginBench checks. See [Contributing](CONTRIBUTING.md) for the appropriate verification commands and development workflow.

## Contributing and license

Contributions are welcome. Please read [Contributing](CONTRIBUTING.md) and the [Security policy](SECURITY.md) before opening a change or reporting a vulnerability.

Margin is licensed under the [Apache License 2.0](LICENSE). Copyright 2026 OpenProse, Inc.
