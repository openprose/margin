# Margin release notes

## 0.2.0 — focused human-agent review

Release date: 2026-08-16

- Added a lazy inline comment affordance and native context-menu action for nonempty selections in both literal source and reader mode.
- Made source highlights and reader-margin markers clickable, including compact overlap counts and source-preserving reader selection mapping.
- Rebuilt the comment inspector around compact inactive threads, one quoted passage, a continuous reply rail, bounded visual nesting, long-thread context, native Markdown rendering, and accessible review progress.
- Added source-ordered previous/next review commands, Go to Comment search, resolve-and-advance behavior, and `⌘⌥[` / `⌘⌥]` shortcuts.
- Added owner-only comment/reply editing and explicit leaf/tree deletion with conflict-aware one-step Undo. Edit safety is bound to the revision visible when composition begins, so a later agent update cannot be overwritten by a stale open composer. Literal Markdown bytes and unknown protocol extensions remain unchanged.
- Added non-disruptive unread activity for external agents: a lazy numeric tab/toolbar indicator and temporary New filter appear without opening the inspector or stealing focus.
- Added an on-demand `⌘⇧P` command palette, recent workspaces, and relaunch continuity for tabs, active documents, reader/source state, sidebars, selection, scroll position, and active thread.
- Added bounded `margin review --json`, event-driven `margin comments watch --jsonl`, and safe CLI `edit` / `delete --subtree` operations. Watch observes atomic replacement without polling and recovers from target-file deletion/recreation.
- Clarified returned annotation IDs, bare/full UUID acceptance, read-command pretty printing, and digest shapes after a blind agent usability run.
- Fixed overlapping-anchor selection feedback, narrow owner-action compression, filesystem-watcher dismissal of Undo, and full-size-titlebar safe-area placement found during live Mac inspection.

### Verification

- 71 XCTest cases pass, including Unicode anchors, concurrent CAS edits/deletes, stale-inspector rejection, exact deletion restore, watch replacement/reconnect, adversarially bounded review output, resolved-only navigation, external unread behavior, overlapping highlights, narrow action layout, persistent Undo, and reader performance.
- The CLI contract suite passes all deterministic read, comment, concurrency, nested-thread, edit/delete, watch, validation, and source-preservation checks.
- A blind agent, given only `--help`, completed review → comment → reply → edit → live watch event → resolve → validate. Every operation took 0.00–0.01 seconds, the watch observed the mutation in about 71 ms, and the logical Markdown SHA-256 remained byte-identical.
- Live testing of the exact signed candidate covers source/reader selection comments, clickable overlapping threads, reader markers, unread external activity, owner edit/Undo, narrow and wide inspector layout, tabs, command palette, and accessible labels/focus.
- Signed bundle smoke, archive verification, local installation, and the 15-run performance gate pass.

### Performance and artifact

On the current M1 Max Mac, the exact candidate reaches a visible real editor window in **307.327 ms median / 336.417 ms p95** across thirty warm launches, with **158.617 MiB median RSS**. Against an immediately rebuilt, identically measured v0.1.3 baseline, median launch improves by 2.6%, p95 by 12.0%, and median RSS by 3.8%. Optional review features remain strictly on demand; see `Docs/PERFORMANCE.md`.

Release artifact: `Margin-0.2.0-macOS-arm64.zip` (1,645,858 bytes), SHA-256 `175066e656bb5ac58b664a40e341e2e89bda994a815b970a0bb02be18f833203`.

## 0.1.3 — native workspace behavior

Release date: 2026-08-16

- Corrected split-pane priorities so the document absorbs horizontal resize while navigator and comment panes retain useful widths.
- Made sidebar collapse preserve the outer window frame, restored only valid on-screen frames, and removed unnecessary full-screen size overrides.
- Added native macOS document tabs, multi-file Open/CLI launch, duplicate-tab focusing, tab tooltips, and standard tab/window commands.
- Made the comment inspector contextual: hidden for empty and unreviewed documents, automatically visible for existing threads, and respectful of explicit user visibility choices.
- Fixed lazy comment rendering when a reviewed document opens with its inspector initially collapsed.
- Fixed an infinite reader loop caused by valid tables with blank header cells and added forward-progress regression coverage.
- Moved reader construction and file-provider watcher setup off the main interaction path, with stale-work cancellation and a lightweight preparing state.
- Added AppKit behavior and performance tests for resizing, quiet pane defaults, comment-aware visibility, delayed filesystem opens, reader tables, and launcher argument grouping.

The Markdown/comment protocol remains byte-compatible with prior releases. Tabs and pane defaults are presentation behavior only.

On the current M1 Max Mac, the exact signed candidate reached a visible window in 292.688 ms median / 338.877 ms p95 across fifteen warm launches. A same-session five-run control of the installed v0.1.2 binary measured 296.394 ms median, so the new workspace behavior does not add measurable launch latency in the current environment. See `Docs/PERFORMANCE.md` for the RSS and cross-session caveat.

Release artifact: `Margin-0.1.3-macOS-arm64.zip` (1,234,406 bytes), SHA-256 `1dc44895fcd0353cf999a5c08cf1d8a05cab1f955df6abba9701f648e7644d63`.

## 0.1.2 — editorial instrument

Release date: 2026-08-16

- Established a restrained visual system that pairs warm document surfaces with cooler technical navigator and review surfaces.
- Added a serif heading register and centered wide-window editing measure while keeping every Markdown delimiter literal and editable.
- Refined reader typography to a calmer 690-point measure with more generous page rhythm and proof-like code treatment.
- Rebuilt comment presentation around clear actor hierarchy, monospaced metadata, literary quote treatment, accent rails, and quieter selection states.
- Refined the directory navigator and Quick Open palette with more precise spacing, file hierarchy, metadata, and adaptive surfaces.
- Made standard window zoom use the full visible screen while retaining native macOS full-screen behavior.

The redesign remains pure AppKit/TextKit and adds no dependency, asset load, network request, or launch-time directory work. The comment protocol and Markdown bytes are unchanged.

On the current M1 Max Mac, the exact signed candidate reached a visible window in 223.750 ms median / 232.907 ms p95 across fifteen warm launches, with 80.734 MiB median RSS. This is within—and slightly faster than—the v0.1.1 launch distribution.

Release artifact: `Margin-0.1.2-macOS-arm64.zip` (1,223,244 bytes), SHA-256 `3a10d390db101041fd4f2a2eb39dabc22daf3ec14922dac08a5942c2ac2ed631`.

## 0.1.1 — usability pass

Release date: 2026-08-16

- Removed implicit window-width ceilings and added native full-screen access at `⌃⌘F`.
- Reworked comment threads with clearly owned root actions, actor glyphs, quote treatment, nested rails, bounded visual indentation, and explicit deep-reply lineage.
- Added an on-demand native Quick Open palette (`⌘P`) with fuzzy filename/path matching and no launch-time directory indexing.
- Added heading navigation (`⌘⇧O`), visible-file traversal (`⌘⌥←` / `⌘⌥→`), and pane focus (`⌘1` / `⌘2` / `⌘3`).
- Deferred reader construction until reader mode is first requested, removing safe work from the source-editor launch path.
- Fixed recursive folder expansion through AppKit accessibility actions and verified repeated expand/collapse behavior.

All v0.1.0 document and comment protocol guarantees remain unchanged. Comments still live inside the Markdown file's terminal, ignorable JSON-LD envelope.

On the current M1 Max Mac and the same 15-run warm-launch probe used for 0.1.0, v0.1.1 reaches a visible window in 232.583 ms median / 248.301 ms p95 and uses 80.391 MiB median RSS at the sampling point. That improves the shipped 0.1.0 median by 31.5%, with no placeholder editor.

Release artifact: `Margin-0.1.1-macOS-arm64.zip` (1,215,440 bytes), SHA-256 `584b6ecb596b22d008c243c3aed85d5d232d1360d194d8a822bfcdae2a489de0`.

## 0.1.0 — initial release

Release date: 2026-08-16

Margin 0.1.0 is the first complete local release of the native Markdown review workspace. It treats one Markdown file as the shared authority for human and agent collaboration: literal source remains editable, reader mode presents the same content calmly, and standards-informed threaded annotations travel inside the document.

### Included

- Native AppKit application for Apple silicon Macs running macOS 13 or newer.
- Terminal opening of existing or new files and directory workspaces, including a blocking `--wait` mode.
- Lazy directory navigator with Markdown-first workspace selection.
- Literal-Markdown editing with native undo, find, spelling, formatting shortcuts, delimiter pairing, list continuation, syntax cues, autosave, and close-time save protection.
- Native reader mode with a bounded reading measure and source-to-reader selection mapping.
- Passage- and document-level comments, arbitrary-depth replies, open/resolved filters, anchor highlights, and resolve/reopen workflows.
- Terminal commands for bounded inspection, outlines, slices, comment creation, replies, status changes, reanchoring, validation, and JSON-LD export.
- A terminal CommonMark HTML comment containing W3C Web Annotation JSON-LD, resilient text quote/position selectors, integrity hashes, revisions, and atomic concurrent mutations.
- Ad-hoc signed local app bundle, standalone CLI, installer, archive, checksum, smoke test, performance probe, and agent benchmark harness.

### Verification

- 22 XCTest cases pass, including Unicode and CRLF coordinates, anchor relocation and ambiguity, malformed metadata, delimiter injection, idempotency, stale preconditions, permission preservation, nested threads, and concurrent replies.
- The CLI contract suite passes discovery, structured reads, ambiguity refusal, idempotent retry, compare-and-swap conflict handling, nested thread lookup, resolve/reopen by descendant, validation, exact source preservation, and new-file safety.
- Live Mac testing covers source editing, reader mapping, keyboard comment submission, nested external replies, thread status changes, autosave anchor migration, directory navigation, accessibility labels, immediate close-time flush, and `--wait` lifecycle.
- Four independently configured agents each scored 100/100 on the fixed CLI collaboration benchmark, preserved logical source bytes exactly, exited normally, and avoided timeouts.

### Measured performance

On the current M1 Max Mac running macOS 26.2, a warm launch of the final release app with a small Markdown file reaches its first visible window in 339.729 ms median and 347.985 ms p95; median RSS measured 250 ms later is 111.188 MiB. The same probe measures a minimal 74 KB AppKit window at 205.745 ms and 80.703 MiB, which establishes the operating-system/framework floor for interpreting those numbers.

### Distribution limits

This build is arm64 and ad-hoc signed for local use. It is not Developer ID signed or notarized because no signing identity is installed on this Mac. Intel/universal packaging, sync, accounts, complete CommonMark rendering, import from other annotation systems, comment editing/deletion, stale-envelope repair after non-Margin source changes, plug-ins, and model-powered semantic lenses remain future work.

### Release artifact

- Archive: `Margin-0.1.0-macOS-arm64.zip` (1,183,878 bytes)
- SHA-256: `8955ec43c2f4bce96d18810a42f4da75885caf6fd42808e6cdcd7e48c77d2955`
- Installed app: `~/Applications/Margin.app`
- Installed command: `~/.local/bin/margin`
