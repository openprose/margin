# Margin interface system

Margin's interface is quiet, exact, and tactile. It is a native work surface for close reading and precise exchange, not an IDE or an office dashboard.

## Structure

- The center editor is always primary.
- A leading navigator appears for directory workspaces and stays collapsed for standalone files.
- A trailing comment inspector holds the conversation without covering the source.
- The unified toolbar contains only navigator, reader, new-comment, and comments controls.
- Reader mode keeps a centered measure no wider than 720 points.

All panes use standard AppKit split-view behavior, system materials, native focus rings, and familiar keyboard navigation. The layout has no decorative cards or persistent onboarding chrome.

## Typography and color

Source editing uses the system monospaced design with semantic weight and restrained color to expose Markdown structure while leaving every delimiter visible. Reader mode uses native text styles, increased leading, and a bounded line length.

Colors come from semantic AppKit values such as label, secondary label, text background, separator, link, and control accent. The app therefore follows light mode, dark mode, increased contrast, and accent changes without a parallel theme engine. Comment selection combines background with an underline so meaning never relies on color alone.

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
