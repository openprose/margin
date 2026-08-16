# Margin release notes

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
