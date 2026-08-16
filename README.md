# Margin

Margin is a fast, native Markdown editor for precise collaboration between humans and agents. It keeps the literal Markdown visible, gives reading its own calm mode, and stores threaded review comments inside the document itself.

There is no account, server, database, WebView, plug-in runtime, or sidecar file. The macOS app and the command line use the same Swift comment engine and the Markdown file remains authoritative.

## What works

- Open a Markdown file or a directory from Terminal.
- Browse directories in a lazy native tree without recursively indexing them at launch.
- Edit literal Markdown with restrained syntax cues, delimiter pairing, list continuation, native undo, find, spellcheck, and accessibility.
- Switch to a bounded, typography-first reader view.
- Select a passage and start a comment with `⌘⌥M`.
- Reply to comments to any depth, resolve or reopen whole threads, and follow anchors as the document changes.
- Let agents inspect, outline, slice, comment on, reply to, and validate the same document through structured CLI commands.
- Preserve comment metadata as an ignorable terminal HTML comment containing W3C Web Annotation JSON-LD.

Margin currently targets Apple silicon Macs running macOS 13 or newer. The v0.1 package is ad-hoc signed for local installation because this machine has no Developer ID certificate.

## Build and install

Requirements: macOS and Swift 5.10 or newer. The release build is pinned to Apple's current Command Line Tools on this Mac; `make test` selects a full local Xcode because its XCTest runner is not included in this host's Command Line Tools.

```sh
cd ~/code/margin
make test
make install
```

This installs `Margin.app` in `~/Applications` and `margin` in `~/.local/bin`. If that directory is not already on `PATH`, add it once in your shell configuration.

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

# Block the terminal until this Margin window closes.
margin architecture.md --wait
```

In the app, select a passage and press `⌘⌥M` to open the composer. Comments appear in the right sidebar and the selected passage stays highlighted. `⌘⇧R` toggles reader mode, `⌘0` toggles the directory navigator, and `⌘⌥0` toggles comments. The window supports native macOS full screen with `⌃⌘F`.

Navigation stays keyboard-first:

- `⌘P` searches and opens files by fuzzy filename or path. Directory indexing begins only when the palette opens.
- `⌘⇧O` searches headings in the current document.
- `⌘⌥←` and `⌘⌥→` open the previous or next visible file in the navigator.
- `⌘1`, `⌘2`, and `⌘3` focus the navigator, editor, and comments respectively.

Formatting shortcuts write ordinary Markdown characters: `⌘B` for bold, `⌘I` for emphasis, and `⌘K` for a link. Margin never replaces the source with hidden rich-text state.

## Agent workflow

Start with discovery instead of reading the raw embedded envelope:

```sh
margin help agents
margin inspect architecture.md --json --pretty
margin outline architecture.md --json
margin slice architecture.md --heading "Failure modes" --context 2
```

Add a resilient passage comment:

```sh
margin comments add architecture.md \
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

Every comment mutation prints one JSON object to stdout. Errors print JSON to stderr, leave stdout empty, and use stable codes plus sysexits-compatible status values. Agents should use `--id` for idempotent retries and `--if-revision` / `--if-content-sha` when coordinating concurrent writes.

Run `margin help comments` for the full grammar. The embedding contract is documented in [COMMENT_PROTOCOL.md](COMMENT_PROTOCOL.md).

## Where comments live

Comments are persisted in the Markdown file itself—not in a database, sidecar, or hidden application folder. Margin appends one terminal CommonMark HTML comment beginning with `<!-- margin:comments:v1`; inside it is a JSON-LD annotation page containing thread bodies, replies, actors, status, and resilient text anchors. Ordinary Markdown renderers ignore that block, while Margin hides it from both source editing and reader mode.

The bytes before the envelope remain the logical Markdown body. Use `margin read FILE` to print only that body, `margin comments export FILE --format jsonld` to inspect the annotations, and `margin comments validate FILE` to verify the combined document.

## Architecture

Margin is intentionally small:

- **AppKit + TextKit 1** for the native window, tree, editor, reader, and comment inspector.
- **MarginCore** for Unicode coordinates, resilient anchors, JSON-LD encoding, locking, and atomic document mutation.
- **margin** for terminal launch plus deterministic human/agent review operations.
- **SwiftPM** for reproducible builds with no third-party runtime dependencies.

The directory tree loads one expanded folder at a time. Highlighting uses temporary TextKit attributes and does not change document bytes. Comment writes lock by canonical file path, reread before mutation, preserve file permissions, and atomically replace the file only after conflict checks.

## Verification

```sh
make test              # unit and concurrency tests
make smoke             # packaged CLI and application smoke tests
make benchmark         # local launch and footprint measurements
make package           # signed local app/CLI zip plus SHA-256 checksum
```

The real-agent benchmark lives in `Benchmarks/agent_benchmark`. It gives a fresh agent only the task and `margin --help`, then scores discovery, bounded reading, comment creation, nested replies, ambiguity recovery, resolution, validation, and byte-exact source preservation. See its README for the privacy and cost controls.

Measured launch results, the agent benchmark, and the complete verification record are in `Docs/PERFORMANCE.md`, `Docs/AGENT_BENCHMARK.md`, and `Docs/RELEASE_NOTES.md`.

## Scope

The Monday v0.1 deliberately excludes sync, accounts, general rich text, a complete CommonMark renderer, plug-ins, and LLM-powered filters. Summarizers and semantic filters are a later-week layer; the file protocol and bounded CLI reads are designed to support them without coupling the document to a model provider.
