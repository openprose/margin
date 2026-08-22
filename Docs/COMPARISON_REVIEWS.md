# Source-agnostic comparison and review

## Requirement

Margin must make it easy for a human or an agent to compare two Markdown
states, discuss their differences, and deliberately carry selected changes
forward. A state may come from a file, an open editor, standard input, a
Margin change set, or another tool. Margin must not know or care whether Git,
an agent, a backup system, or a person produced it.

Comparison is a requested activity. It must add no file discovery, parsing,
process launch, watcher, or persistent UI to Margin's startup path.

## Progress

- [x] Written source-agnostic contract and trust boundary.
- [x] Bounded deterministic comparison engine and portable review model.
- [x] Agent-facing comparison and review-thread commands.
- [x] Native inline and side-by-side comparison, commenting, refresh, swap,
  and verified apply/undo paths.
- [x] Complete the release-wide, Linux, accessibility, and paired performance
  gates; then commit and push the feature branch.

## Product principles

1. **The source is explicit.** Every side has a visible label, content digest,
   and optional path. Margin never guesses what a snapshot represents.
2. **Reading comes first.** The default comparison is a calm inline proof. A
   side-by-side view is available when spatial comparison is more useful.
3. **Markdown remains literal.** Delimiters stay visible and participate in
   the diff. Line-level structure and word-level changes make the meaning of
   an edit legible without creating a second document model.
4. **Review has an address.** A thread targets the left side, right side, or a
   changed pair and carries both a resilient quote selector and exact snapshot
   digest.
5. **Applying is deliberate.** Comparison never changes source on open.
   Applying a hunk or accepting the right side requires an explicit action,
   verifies the expected source digest, and remains undoable in an open
   editor.
6. **Humans and agents share the feature.** Essential comparison and review
   operations have deterministic CLI and JSON forms.

In version 1, every snapshot is the **logical Markdown body** after decoding
and validating Margin's terminal metadata envelope. The envelope itself is
never shown as a difference, copied into a snapshot, or replaced by an apply
operation. Original UTF-8 body bytes, including line endings and final-newline
state, remain available for exact application.

## Native app experience

### Entry points

- **File > Compare Files...** chooses two Markdown files.
- **Compare Active Tab With...** searches the other open Markdown tabs and
  compares their current editor contents, including unsaved text.
- Opening a comparison request or `.marginreview` from the CLI creates a
  native comparison tab without revealing snapshot content in arguments.

The standard shortcut is `Control-Command-C`. The same actions remain
discoverable in the File menu.

### Comparison tab

- A compact header names the left and right states and exposes swap, refresh,
  whitespace, layout, and verified-apply actions.
- Refresh rereads the original explicit files or live-tab provider only while
  a comparison is unsaved. Once a `.marginreview` exists, Refresh reloads that
  artifact so external thread/status changes appear; inert source hints are
  never followed.
- The default inline proof shows additions and removals in source order. Long
  unchanged regions collapse to a context boundary and can be expanded.
- Side-by-side mode keeps corresponding passages aligned and scrolls both
  sides together.
- Changed lines receive restrained insertion and removal treatments with
  symbols and accessible labels. Meaning never depends on red and green alone.
- Replaced lines receive word-level emphasis. Whitespace-only changes are
  visible on demand.
- Previous and next change use `Option-Command-Up` and
  `Option-Command-Down`.
- The existing trailing inspector presents comparison threads. It stays
  closed for a review with no comments until the user begins one.
- Selection on either side exposes the same quiet comment affordance used by
  source and reader views.

### Applying changes

- A changed block can copy left to right or right to left when that side is a
  writable file or open editor.
- All changed blocks can be carried in either direction after a confirmation
  that names the destination.
- Margin refuses to write when the destination's logical-body digest changed
  after the comparison began and reports that the comparison must be
  refreshed.
- Selected blocks apply as one atomic batch against one snapshot generation.
  Margin never applies one block and then interprets the remaining stale
  ranges. After applying to an unsaved file/live-tab comparison, Margin rereads
  those explicit sources; a portable review keeps the immutable evidence it
  was created to review.
- Annotation-only changes do not invalidate an otherwise safe body apply.
  Margin performs the write through `AtomicDocumentStore`, preserves the
  current terminal annotation envelope, and re-resolves its anchors against
  the resulting body. A body change or unsafe anchor reconciliation aborts the
  complete batch.
- Applying through an open editor participates in the native undo stack.

## Review artifact

A saved comparison is one portable JSON document using the schema
`urn:margin:comparison-review:v1`. It contains:

- a stable review identifier and timestamps;
- immutable left and right logical-body content, labels, media type, UTF-8 byte
  count, and SHA-256 digest;
- optional relative display-only source hints and body-digest preconditions;
- display options that affect presentation but not snapshot identity;
- threaded annotations with actor provenance, status, side, quote selector,
  surrounding context, and optional changed-block identity;
- an extension object whose unknown values round-trip unchanged.

Absolute paths, credentials, environment variables, and tool-specific
repository metadata are never persisted. Source hints are untrusted display
text. They never authorize a read, resolve a path, or choose a write target.
Applying to a closed file requires a destination selected explicitly by the
user in the app, followed by canonical-parent and regular-file validation.
The version 1 CLI reviews and comments but does not apply changes. Symlinks are
not writable destinations in version 1.

Saving a review is explicit. Merely opening a comparison creates no durable
review file. Beginning the first comment asks for a save location, defaulting
to a descriptive `.marginreview` filename in the standard save panel. Review
files created by Margin default to owner-only mode `0600`; mutations of an
explicitly imported review preserve its existing permissions. One-shot request
files must be owner-only, are claimed after validation, and are removed after
successful decode. Unsaved comparisons do not join session restoration.

Review saves use atomic replacement, stable caller-selectable idempotency
identifiers, and optimistic review-revision checks. A separate
snapshot-generation identifier names the immutable pair. Reloading a review
can observe newer thread, status, and display revisions without changing its
snapshots. Starting a comparison from newer source states creates a new review;
version 1 deliberately does not grow one artifact with every prior snapshot
body.

## CLI contract

```text
margin compare [OPTIONS] [--] LEFT RIGHT
margin compare open [--wait] [--app PATH] [--] REVIEW
margin compare comments list [LIST_OPTIONS] [--] REVIEW
margin compare comments add --side left|right ANCHOR MESSAGE [MUTATION_OPTIONS] [--] REVIEW
margin compare comments reply MESSAGE [MUTATION_OPTIONS] [--] REVIEW PARENT
margin compare comments resolve|reopen [MUTATION_OPTIONS] [--] REVIEW THREAD
```

`LEFT` and `RIGHT` are regular UTF-8 Markdown files. Exactly one side may be
the literal `-`, which reads standard input once. `--` ends option parsing so
dash-prefixed paths remain addressable. In version 1, change-set and arbitrary
typed snapshot references are intentionally excluded; callers materialize
them as a file or standard input.

Without `--json`, the two-source form opens the native app on macOS through an
owner-only, size-bounded request file whose snapshot bytes never appear in
process arguments. The app atomically claims and removes that request. With
`--json`, it emits a bounded structural comparison and never launches the app.
Linux requires `--json` or `--save-review`; otherwise it returns
`APP_UNAVAILABLE`.
Adding `compare` reserves that command word; a file literally named `compare`
remains openable as `margin ./compare` or `margin -- compare`.

Machine-facing output includes exact snapshot digests, ordered changed
blocks, zero-based line offsets, half-open Unicode-scalar ranges, bounded
previews, truncation signals, and a structured argument array for requesting
more detail. Agent commands can create, inspect, reply to, resolve, and reopen
comparison threads without parsing presentation text. Add and reply accept
stable caller-selected identifiers for safe uncertain retries; every mutation
accepts an expected review revision.

All paths are passed as literal arguments. Standard input has an explicit
byte limit and invalid UTF-8 is rejected. JSON output is stable, versioned,
and free of terminal styling.

## Diff semantics

- Version 1 uses `margin-line-diff-v1`: common prefix and suffix trimming
  followed by bounded dynamic-programming longest-common-subsequence regions,
  with deletion before insertion as the documented tie break. Exhausting the
  deterministic work budget produces one coarse replacement block for that
  region; wall-clock timing never changes output.
- A UTF-8 BOM is removed from the logical body. Normalize CRLF and CR only for
  matching while preserving original bytes in both snapshots. Final-newline
  state is significant and represented explicitly.
- Compute the deterministic line diff first, then a Unicode-scalar token diff
  only inside paired replacement lines shorter than 32 KiB. Longer replacements
  retain line-level presentation.
- Give every changed block a pair-local identifier derived from the snapshot
  generation and source ranges. A new snapshot pair produces new identifiers.
- Bound work by input bytes, line count, line bytes, changed blocks, and a
  deterministic algorithmic work budget. A cancelled or superseded comparison
  must stop promptly.

## Resource and trust limits

Version 1 applies the following hard ceilings before expensive work:

- 8 MiB per snapshot and 16 MiB combined logical Markdown;
- 100,000 lines per side and 1 MiB per physical line;
- 20,000 changed blocks and 32 KiB per word-diff line;
- 64 MiB encoded review artifact;
- 2,000 threads, 10,000 total annotations, 256 annotations per thread, depth
  32, and 64 KiB per body;
- 512 UTF-8 bytes per label or identifier;
- 256 extension keys, nesting depth 16, and 1 MiB aggregate extension data;
- one Unicode-scalar projection per current snapshot during review validation,
  plus a shared 32 million scalar-comparison ceiling for explicit anchor
  refresh and apply reconciliation.

File inputs are opened as bounded regular files. FIFOs, devices, directories,
symlinks, invalid UTF-8, embedded NUL, changing-during-read inputs, duplicate
JSON keys, digest/count mismatches, invalid ranges, invalid thread graphs, and
over-limit values are rejected with stable error codes. Labels, comments, and
extensions are untrusted text and never interpreted as commands.

## Performance acceptance

- App and CLI cold-launch measurements remain within the existing release
  budgets in `Docs/PERFORMANCE.md`.
- No comparison service or view is constructed before an explicit comparison
  request.
- Inputs are read and diffed away from the main thread. The window and tab
  appear before expensive work completes.
- For a roughly 1 MiB, 20,000-line fixture, `make benchmark-comparison`
  separately records tab-visible,
  complete-ready, and settled-memory distributions. Version 1 does not claim
  progressive streaming; the first presented content arrives with the complete
  deterministic comparison.
- Scrolling, selection, typing in other tabs, and comment entry remain
  responsive while a comparison is running.

## Accessibility and failure behavior

- Every side, change, thread, and action has a native accessibility role and
  concise label.
- Keyboard-only users can enter, traverse, comment on, apply, and close a
  comparison.
- Missing files, permission failures, oversized input, binary input, stale
  destinations, malformed review artifacts, and cancelled work produce quiet,
  actionable states without losing either snapshot.
- Comparison never edits a source, creates a review artifact, or opens the
  comment inspector merely because it was viewed.
- Opening a review artifact is inert. It never follows source hints, accesses
  additional files, or enables writes without a new explicit destination.

## Explicit non-goals

- Repository discovery, Git status, branches, commits, remotes, and Git-aware
  persistence.
- Comparing arbitrary binary formats.
- Semantic Markdown rewriting or hidden WYSIWYG normalization.
- Margin change-set sources in version 1. An external caller may materialize a
  before/after image and use the ordinary file or standard-input boundary.
- Network synchronization or a background comparison daemon.

External tools may resolve any versioning system into two files or standard
input and ask Margin to compare them. That adapter boundary is intentional.

## Release gates

The feature is complete when:

1. The app entry points, inline and side-by-side views, navigation, comments,
   refresh, and safe apply paths pass automated and manual tests.
2. The CLI supports file and standard-input comparison, bounded JSON output,
   review creation and thread mutation, and app launch requests.
3. Golden diff cases cover empty, identical, Unicode, Markdown structure,
   repeated lines, CRLF, BOM, final newline, whitespace, long lines, and large
   documents.
4. Adversarial tests cover symlinks and swap races, changing files, malformed
   and duplicate-key artifacts, stale body and metadata races, cancellation,
   competing optimistic writers, request-file cleanup, and hard resource
   boundaries.
5. Accessibility inspection and keyboard-only testing pass in both appearances
   and increased-contrast mode.
6. Release performance measurements compare the signed candidate against the
   current release in counterbalanced runs and show no statistically meaningful
   app startup, static CLI, idle-memory, or typing regression. Invoked compare
   measurements separately record tab-visible, complete-ready, and settled
   memory; deterministic tests exercise supersession and cancellation.
