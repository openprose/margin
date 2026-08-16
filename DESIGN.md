# Margin interface system

Margin's interface is quiet, exact, and tactile. It is a native work surface for close reading and precise exchange, not an IDE or an office dashboard.

Its visual character is an **editorial instrument**: the measured geometry and microtype of a drafting tool, paired with the warmth and cadence of a well-set proof. Artistic choices live in proportion, typography, and material—not decoration.

## Structure

- The center editor is always primary.
- A leading navigator appears for directory workspaces and stays collapsed for standalone files.
- A trailing comment inspector holds the conversation without covering the source.
- The unified toolbar contains only navigator, reader, new-comment, and comments controls.
- Reader mode keeps a centered measure no wider than 690 points.

All panes use standard AppKit split-view behavior, system materials, native focus rings, and familiar keyboard navigation. The layout has no decorative cards or persistent onboarding chrome.

## Workspace defaults

- A new or comment-free document begins with the source alone. The comment inspector opens automatically only when a document already contains review threads or the user starts a comment.
- Standalone files hide the navigator; directory workspaces reveal it. Closing either sidebar gives its space to the document without changing the outer window frame.
- The initial window uses a generous 1180 × 780 working size when the screen permits. Later launches restore only a usable, on-screen frame, and the document pane remains the elastic region during live resize and full screen.
- Opening several files—through the Open panel, Finder, or the CLI—places them in native tabs. An empty tab is reused, duplicate paths focus their existing tab, and separate windows remain available with `⌘N`.
- Tabs follow browser conventions: `⌘T`, `⌘W`, `⌃Tab`, `⌃⇧Tab`, and `⌘1`…`⌘9`. Pane focus uses `⌃1`…`⌃3` so it never competes with tab selection.
- Reader presentation and file-provider change watching begin only after they are requested, away from the main interaction path. Stale reader work is discarded when the user switches files or modes.

## Typography and color

Source editing uses a legible system face with a serif heading register, generous leading, and restrained syntax color. Every delimiter remains visible. The editing measure centers only when space permits, preserving a direct full-width canvas in compact windows. Reader mode uses a native serif design, increased leading, and a narrower book-like measure.

The document rests on a low-chroma, warm proofing surface; the navigator and comment inspector use slightly cooler technical surrounds. Monospaced microtype is reserved for paths, counts, dates, and navigation instructions. The user's macOS accent color is the only chromatic voice and links source anchors, Markdown cues, files, and active review state.

Colors remain adaptive AppKit values, so the app follows light mode, dark mode, increased contrast, and accent changes without a user-facing theme engine. Comment selection combines a quiet accent wash, underline, and geometric reply rail so meaning never relies on color alone.

## Interaction

- Source bytes, selections, undo, and keyboard input remain authoritative.
- Formatting actions insert or toggle ordinary Markdown delimiters.
- Lists, ordered lists, and block quotes continue on Return and terminate cleanly from an empty item.
- A passage comment begins from the current selection; without a selection Margin uses the current paragraph, then falls back to the whole document.
- Selecting a source highlight selects its thread. Selecting a thread reveals the source passage.
- Reader/source toggling preserves the corresponding selection and scroll intent.
- Autosave feedback is quiet; conflicts and unsafe metadata are explicit and actionable.

## Accessibility

Every structural pane, toolbar action, tree row, text surface, filter, empty state, and comment group has a native accessibility role or label. All essential workflows are keyboard reachable. System text, contrast, reduced-motion behavior, and focus indicators are respected. Ambiguous and orphaned anchors use text labels, not color alone.

## Performance rules

- No WebKit, SwiftUI, third-party UI toolkit, database, daemon, or network request at launch.
- Do not recursively crawl directories; enumerate a folder only when it becomes visible.
- Style source with temporary TextKit attributes; do not rebuild the document model while typing.
- Parse reader presentation only when entering or refreshing reader mode.
- Show the native window before optional background discovery work.
- Treat launch time, idle footprint, and source stability as release acceptance measurements.
