import AppKit

/// Applies lightweight Markdown presentation to an `NSTextView` without ever
/// changing its backing string. All syntax treatment lives in TextKit temporary
/// attributes, so file offsets, selections, undo, and comment anchors remain
/// expressed in the literal Markdown source.
final class MarkdownHighlighter: NSObject {
    struct Theme {
        var bodyFont: NSFont
        var headingFonts: [NSFont]
        var strongFont: NSFont
        var emphasisFont: NSFont
        var strongEmphasisFont: NSFont
        var codeFont: NSFont

        var textColor: NSColor
        var syntaxColor: NSColor
        var activeSyntaxColor: NSColor
        var linkColor: NSColor
        var checkedColor: NSColor

        static func system(baseFontSize: CGFloat = 15.5) -> Theme {
            let body = MarginTheme.sourceBodyFont(size: baseFontSize)
            let strong = NSFont.systemFont(ofSize: baseFontSize, weight: .semibold)
            let emphasis = font(byAdding: .italicFontMask, to: body)
            let strongEmphasis = font(byAdding: .italicFontMask, to: strong)

            return Theme(
                bodyFont: body,
                headingFonts: (1...6).map {
                    MarginTheme.sourceHeadingFont(level: $0, baseSize: baseFontSize)
                },
                strongFont: strong,
                emphasisFont: emphasis,
                strongEmphasisFont: strongEmphasis,
                codeFont: NSFont.monospacedSystemFont(
                    ofSize: max(baseFontSize - 0.5, 11),
                    weight: .regular
                ),
                textColor: .labelColor,
                syntaxColor: MarginTheme.syntax,
                activeSyntaxColor: MarginTheme.activeSyntax,
                linkColor: .controlAccentColor,
                checkedColor: .controlAccentColor
            )
        }

        private static func font(
            byAdding trait: NSFontTraitMask,
            to font: NSFont
        ) -> NSFont {
            NSFontManager.shared.convert(font, toHaveTrait: trait)
        }
    }

    private enum ProtectedKind {
        case fencedCode
        case htmlComment
    }

    private struct ProtectedRegion {
        var range: NSRange
        var delimiterRanges: [NSRange]
        var kind: ProtectedKind
    }

    private enum Patterns {
        static let heading = regex(#"(?m)^( {0,3})(#{1,6})([\t ]+)(.*?)([\t ]+#+)?[\t ]*$"#)
        static let setextHeading = regex(#"(?m)^([^\n]+)\n( {0,3})(=+|-+)[\t ]*$"#)
        static let blockquote = regex(#"(?m)^( {0,3}(?:>[\t ]?)+)"#)
        static let listMarker = regex(#"(?m)^( {0,3})([-+*]|\d+[.)])([\t ]+)"#)
        static let taskMarker = regex(#"(?m)^( {0,3}[-+*][\t ]+)(\[[ xX]\])([\t ]+)"#)
        static let thematicBreak = regex(#"(?m)^( {0,3})(?:(?:\*[\t ]*){3,}|(?:-[\t ]*){3,}|(?:_[\t ]*){3,})$"#)

        static let image = regex(#"!\[([^\]\n]*)\]\(([^)\n]+)\)"#)
        static let link = regex(#"(?<!!)\[([^\]\n]+)\]\(([^)\n]+)\)"#)
        static let referenceLink = regex(#"(?<!!)\[([^\]\n]+)\]\[([^\]\n]*)\]"#)
        static let autolink = regex(#"<(https?://[^>\n]+|mailto:[^>\n]+)>"#)
        static let inlineCode = regex(#"(?<!\\)(`+)(?!`)(.+?)(?<!`)\1(?!`)"#)
        static let strongAsterisk = regex(#"(?<!\\)\*\*(?=\S)(.+?)(?<=\S)\*\*"#)
        static let strongUnderscore = regex(#"(?<![\\_])__(?=\S)(.+?)(?<=\S)__(?!_)"#)
        static let emphasisAsterisk = regex(#"(?<![\\*])\*(?![\s*])(.+?)(?<![\s\\])\*(?!\*)"#)
        static let emphasisUnderscore = regex(#"(?<![\\_])_(?![\s_])(.+?)(?<![\s\\])_(?!_)"#)
        static let strongEmphasisAsterisk = regex(#"(?<!\\)\*\*\*(?=\S)(.+?)(?<=\S)\*\*\*"#)
        static let strongEmphasisUnderscore = regex(#"(?<![\\_])___(?=\S)(.+?)(?<=\S)___(?!_)"#)
        static let strikethrough = regex(#"(?<!\\)~~(?=\S)(.+?)(?<=\S)~~"#)
        static let escape = regex(#"\\(?=[^\p{L}\p{N}\s])"#)

        private static func regex(_ pattern: String) -> NSRegularExpression {
            // Patterns are constants covered by compile checks. A programming
            // error here should fail immediately rather than silently dropping
            // a visual language feature.
            try! NSRegularExpression(pattern: pattern)
        }
    }

    weak var textView: NSTextView?
    var theme: Theme {
        didSet {
            if let textView {
                Self.prepare(textView, theme: theme)
            }
            invalidate()
        }
    }

    private var observations: [NSObjectProtocol] = []
    private var activeLineRange = NSRange(location: NSNotFound, length: 0)
    private var protectedRegions: [ProtectedRegion] = []
    private var hasParsedProtectedRegions = false
    private var editSequence = 0
    private var handledEditSequence = 0
#if DEBUG
    /// Kept internal so focused presentation smokes can verify that ordinary
    /// paragraph edits do not accidentally trigger a whole-document scan.
    private(set) var protectedRegionParseCountForTesting = 0
#endif

    init(textView: NSTextView, theme: Theme = .system()) {
        self.textView = textView
        self.theme = theme
        super.init()
        attach(to: textView)
    }

    deinit {
        observations.forEach(NotificationCenter.default.removeObserver)
    }

    /// Configures only view-level source-editor behavior. The backing string is
    /// untouched and remains suitable for direct persistence with `textView.string`.
    static func prepare(_ textView: NSTextView, theme: Theme = .system()) {
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFontPanel = false
        textView.usesRuler = false
        textView.allowsUndo = true
        textView.isContinuousSpellCheckingEnabled = true
        textView.isGrammarCheckingEnabled = false

        // Markdown punctuation is data. Smart substitutions must never rewrite it.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false

        textView.font = theme.bodyFont
        textView.textColor = theme.textColor
        textView.insertionPointColor = .controlAccentColor
        textView.drawsBackground = true
        textView.backgroundColor = MarginTheme.documentBackground
        textView.textContainerInset = NSSize(width: 46, height: 44)
        textView.textContainer?.lineFragmentPadding = 0
        textView.usesFindPanel = true
        textView.isIncrementalSearchingEnabled = true

        let paragraph = MarginTheme.sourceParagraphStyle()
        textView.defaultParagraphStyle = paragraph
        textView.typingAttributes = [
            .font: theme.bodyFont,
            .foregroundColor: theme.textColor,
            .paragraphStyle: paragraph,
        ]
        textView.setAccessibilityLabel("Markdown source")
    }

    func attach(to textView: NSTextView) {
        detach()
        self.textView = textView
        Self.prepare(textView, theme: theme)

        guard let textStorage = textView.textStorage else { return }
        let center = NotificationCenter.default
        observations.append(
            center.addObserver(
                forName: NSTextStorage.didProcessEditingNotification,
                object: textStorage,
                queue: .main
            ) { [weak self, weak textStorage] _ in
                guard
                    let self,
                    let textStorage,
                    textStorage.editedMask.contains(.editedCharacters)
                else { return }
                self.editSequence += 1
                let sequence = self.editSequence
                let editedRange = textStorage.editedRange
                let changeInLength = textStorage.changeInLength

                // `didProcessEditing` is posted before TextKit has fully unwound
                // its internal edit transaction. Painting temporary attributes
                // synchronously here can leave NSLayoutManager observing the new
                // string with old glyph ranges when a document shrinks.
                DispatchQueue.main.async { [weak self, weak textStorage] in
                    guard let self, let textStorage,
                          self.textView?.textStorage === textStorage,
                          sequence > self.handledEditSequence else { return }
                    self.refreshAfterEdit(
                        editedRange: editedRange,
                        changeInLength: changeInLength
                    )
                    self.handledEditSequence = sequence
                }
            }
        )
        observations.append(
            center.addObserver(
                forName: NSTextView.didChangeSelectionNotification,
                object: textView,
                queue: .main
            ) { [weak self] _ in
                self?.selectionDidChange()
            }
        )

        updateActiveLineRange()
        invalidate()
    }

    func detach() {
        observations.forEach(NotificationCenter.default.removeObserver)
        observations.removeAll()
        clearTemporaryAttributes(in: nil)
        protectedRegions.removeAll()
        hasParsedProtectedRegions = false
        editSequence = 0
        handledEditSequence = 0
#if DEBUG
        protectedRegionParseCountForTesting = 0
#endif
        activeLineRange = NSRange(location: NSNotFound, length: 0)
        textView = nil
    }

    /// Rebuilds presentation for the complete source. Call this after replacing
    /// `textView.string` or changing an external appearance preference.
    func invalidate() {
        guard let textStorage = textView?.textStorage else { return }
        handledEditSequence = editSequence
        highlight(
            range: NSRange(location: 0, length: textStorage.length),
            structuralChange: true
        )
    }

    private func refreshAfterEdit(editedRange: NSRange, changeInLength: Int) {
        guard let textStorage = textView?.textStorage else { return }
        let source = textStorage.string as NSString
        let dirtyRange = expandedParagraphRange(around: editedRange, in: source)

        let touchesOldDelimiter = protectedRegions.contains { region in
            region.delimiterRanges.contains { rangesIntersect($0, dirtyRange) }
        }
        let dirtyText = source.substring(with: clamped(dirtyRange, to: source.length))
        let introducesDelimiter = dirtyText.contains("```")
            || dirtyText.contains("~~~")
            || dirtyText.contains("<!--")
            || dirtyText.contains("-->")

        // New or removed block delimiters can change presentation to the end of
        // a document. Ordinary edits remain local, even in large files.
        let structuralChange = touchesOldDelimiter || introducesDelimiter
        if !structuralChange {
            migrateProtectedRegions(
                through: editedRange,
                changeInLength: changeInLength
            )
        }
        let range = structuralChange
            ? NSRange(location: 0, length: source.length)
            : dirtyRange
        highlight(range: range, structuralChange: structuralChange)

    }

    /// `NSTextStorage.editedRange` is expressed after the edit. Protected source
    /// ranges are parser state, so keep them aligned for edits that do not alter
    /// a fence or HTML-comment delimiter.
    private func migrateProtectedRegions(
        through editedRange: NSRange,
        changeInLength: Int
    ) {
        guard hasParsedProtectedRegions, changeInLength != 0 else { return }
        let oldLength = max(0, editedRange.length - changeInLength)
        let oldEdit = NSRange(location: editedRange.location, length: oldLength)

        protectedRegions = protectedRegions.map { region in
            var migrated = region
            migrated.range = migratedRange(
                region.range,
                through: oldEdit,
                replacementLength: editedRange.length
            )
            migrated.delimiterRanges = region.delimiterRanges.map {
                migratedRange(
                    $0,
                    through: oldEdit,
                    replacementLength: editedRange.length
                )
            }
            return migrated
        }
    }

    private func migratedRange(
        _ range: NSRange,
        through edit: NSRange,
        replacementLength: Int
    ) -> NSRange {
        let oldEditEnd = NSMaxRange(edit)
        let rangeEnd = NSMaxRange(range)
        let delta = replacementLength - edit.length

        if oldEditEnd <= range.location {
            return NSRange(location: max(0, range.location + delta), length: range.length)
        }
        if edit.location >= rangeEnd { return range }

        // A non-structural overlap can only be content inside a protected block;
        // delimiter overlaps are promoted to a full parse before this method.
        return NSRange(
            location: range.location,
            length: max(0, range.length + delta)
        )
    }

    private func selectionDidChange() {
        let previous = activeLineRange
        updateActiveLineRange()

        if previous.location != NSNotFound {
            highlight(range: previous, structuralChange: false)
        }
        if activeLineRange.location != NSNotFound,
           !NSEqualRanges(previous, activeLineRange) {
            highlight(range: activeLineRange, structuralChange: false)
        }
    }

    private func updateActiveLineRange() {
        guard
            let textView,
            let textStorage = textView.textStorage
        else {
            activeLineRange = NSRange(location: NSNotFound, length: 0)
            return
        }

        let source = textStorage.string as NSString
        let selected = textView.selectedRange()
        let location = min(selected.location, source.length)
        activeLineRange = expandedParagraphRange(
            around: NSRange(location: location, length: 0),
            in: source
        )
    }

    private func highlight(range requestedRange: NSRange, structuralChange: Bool) {
        guard
            let textView,
            let textStorage = textView.textStorage,
            let layoutManager = textView.layoutManager
        else { return }

        let source = textStorage.string as NSString
        let range = clamped(requestedRange, to: source.length)
        guard range.location != NSNotFound else { return }

        if structuralChange || !hasParsedProtectedRegions {
            protectedRegions = parseProtectedRegions(in: source)
            hasParsedProtectedRegions = true
#if DEBUG
            protectedRegionParseCountForTesting += 1
#endif
        }

        clearTemporaryAttributes(in: range)
        guard range.length > 0 else { return }

        applyProtectedRegions(
            intersecting: range,
            with: layoutManager
        )
        applyBlockSyntax(in: range, source: source, layoutManager: layoutManager)
        applyInlineSyntax(in: range, source: source, layoutManager: layoutManager)
    }

    private func applyProtectedRegions(
        intersecting target: NSRange,
        with layoutManager: NSLayoutManager
    ) {
        for region in protectedRegions where rangesIntersect(region.range, target) {
            let visible = NSIntersectionRange(region.range, target)
            switch region.kind {
            case .fencedCode:
                layoutManager.addTemporaryAttributes(
                    [
                        .font: theme.codeFont,
                        .foregroundColor: theme.textColor,
                    ],
                    forCharacterRange: visible
                )
            case .htmlComment:
                layoutManager.addTemporaryAttributes(
                    [
                        .font: theme.codeFont,
                        .foregroundColor: theme.syntaxColor,
                    ],
                    forCharacterRange: visible
                )
            }

            for delimiter in region.delimiterRanges where rangesIntersect(delimiter, target) {
                applySyntax(
                    to: NSIntersectionRange(delimiter, target),
                    layoutManager: layoutManager
                )
            }
        }
    }

    private func applyBlockSyntax(
        in range: NSRange,
        source: NSString,
        layoutManager: NSLayoutManager
    ) {
        for match in matches(Patterns.heading, range: range, source: source) {
            guard !isProtected(match.range) else { continue }
            let marker = match.range(at: 2)
            let level = min(max(marker.length, 1), theme.headingFonts.count)
            applySyntax(to: marker, layoutManager: layoutManager)
            applySyntax(to: match.range(at: 5), layoutManager: layoutManager)
            apply(
                [.font: theme.headingFonts[level - 1]],
                to: match.range(at: 4),
                layoutManager: layoutManager
            )
        }

        for match in matches(Patterns.setextHeading, range: range, source: source) {
            guard !isProtected(match.range) else { continue }
            let marker = match.range(at: 3)
            let markerText = source.substring(with: marker)
            let level = markerText.first == "=" ? 0 : 1
            apply(
                [.font: theme.headingFonts[level]],
                to: match.range(at: 1),
                layoutManager: layoutManager
            )
            applySyntax(to: marker, layoutManager: layoutManager)
        }

        syntaxCaptures(
            Patterns.blockquote,
            capture: 1,
            in: range,
            source: source,
            layoutManager: layoutManager
        )
        syntaxCaptures(
            Patterns.listMarker,
            capture: 2,
            in: range,
            source: source,
            layoutManager: layoutManager
        )

        for match in matches(Patterns.taskMarker, range: range, source: source) {
            guard !isProtected(match.range) else { continue }
            let markerRange = match.range(at: 2)
            let marker = source.substring(with: markerRange).lowercased()
            let color = marker == "[x]" ? theme.checkedColor : syntaxColor(for: markerRange)
            apply(
                [.foregroundColor: color, .font: theme.codeFont],
                to: markerRange,
                layoutManager: layoutManager
            )
        }

        for match in matches(Patterns.thematicBreak, range: range, source: source) {
            guard !isProtected(match.range) else { continue }
            applySyntax(to: match.range, layoutManager: layoutManager)
        }
    }

    private func applyInlineSyntax(
        in range: NSRange,
        source: NSString,
        layoutManager: NSLayoutManager
    ) {
        for match in matches(Patterns.image, range: range, source: source) {
            guard !isProtected(match.range) else { continue }
            applySyntax(to: match.range, layoutManager: layoutManager)
            apply(
                [.foregroundColor: theme.textColor, .font: theme.emphasisFont],
                to: match.range(at: 1),
                layoutManager: layoutManager
            )
            apply(
                [.foregroundColor: theme.syntaxColor, .font: theme.codeFont],
                to: match.range(at: 2),
                layoutManager: layoutManager
            )
        }

        for pattern in [Patterns.link, Patterns.referenceLink] {
            for match in matches(pattern, range: range, source: source) {
                guard !isProtected(match.range) else { continue }
                applySyntax(to: match.range, layoutManager: layoutManager)
                apply(
                    [.foregroundColor: theme.linkColor],
                    to: match.range(at: 1),
                    layoutManager: layoutManager
                )
                apply(
                    [.foregroundColor: theme.syntaxColor, .font: theme.codeFont],
                    to: match.range(at: 2),
                    layoutManager: layoutManager
                )
            }
        }

        for match in matches(Patterns.autolink, range: range, source: source) {
            guard !isProtected(match.range) else { continue }
            applySyntax(to: match.range, layoutManager: layoutManager)
            apply(
                [.foregroundColor: theme.linkColor, .font: theme.codeFont],
                to: match.range(at: 1),
                layoutManager: layoutManager
            )
        }

        for match in matches(Patterns.inlineCode, range: range, source: source) {
            guard !isProtected(match.range) else { continue }
            applySyntax(to: match.range(at: 1), layoutManager: layoutManager)
            let closing = NSRange(
                location: NSMaxRange(match.range) - match.range(at: 1).length,
                length: match.range(at: 1).length
            )
            applySyntax(to: closing, layoutManager: layoutManager)
            apply(
                [.font: theme.codeFont],
                to: match.range(at: 2),
                layoutManager: layoutManager
            )
        }

        applyDelimitedStyle(
            Patterns.strongAsterisk,
            markerLength: 2,
            font: theme.strongFont,
            in: range,
            source: source,
            layoutManager: layoutManager
        )
        applyDelimitedStyle(
            Patterns.strongUnderscore,
            markerLength: 2,
            font: theme.strongFont,
            in: range,
            source: source,
            layoutManager: layoutManager
        )
        applyDelimitedStyle(
            Patterns.emphasisAsterisk,
            markerLength: 1,
            font: theme.emphasisFont,
            in: range,
            source: source,
            layoutManager: layoutManager
        )
        applyDelimitedStyle(
            Patterns.emphasisUnderscore,
            markerLength: 1,
            font: theme.emphasisFont,
            in: range,
            source: source,
            layoutManager: layoutManager
        )
        applyDelimitedStyle(
            Patterns.strikethrough,
            markerLength: 2,
            font: theme.bodyFont,
            additionalAttributes: [
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .strikethroughColor: theme.syntaxColor,
            ],
            in: range,
            source: source,
            layoutManager: layoutManager
        )

        // Combined emphasis runs last so nested single/double patterns cannot
        // flatten the intended bold-italic presentation.
        applyDelimitedStyle(
            Patterns.strongEmphasisAsterisk,
            markerLength: 3,
            font: theme.strongEmphasisFont,
            in: range,
            source: source,
            layoutManager: layoutManager
        )
        applyDelimitedStyle(
            Patterns.strongEmphasisUnderscore,
            markerLength: 3,
            font: theme.strongEmphasisFont,
            in: range,
            source: source,
            layoutManager: layoutManager
        )

        syntaxCaptures(
            Patterns.escape,
            capture: 0,
            in: range,
            source: source,
            layoutManager: layoutManager
        )
    }

    private func applyDelimitedStyle(
        _ pattern: NSRegularExpression,
        markerLength: Int,
        font: NSFont,
        additionalAttributes: [NSAttributedString.Key: Any] = [:],
        in range: NSRange,
        source: NSString,
        layoutManager: NSLayoutManager
    ) {
        for match in matches(pattern, range: range, source: source) {
            guard !isProtected(match.range) else { continue }
            let content = match.range(at: 1)
            let opening = NSRange(location: match.range.location, length: markerLength)
            let closing = NSRange(
                location: NSMaxRange(match.range) - markerLength,
                length: markerLength
            )
            applySyntax(to: opening, layoutManager: layoutManager)
            applySyntax(to: closing, layoutManager: layoutManager)

            var attributes = additionalAttributes
            attributes[.font] = font
            apply(attributes, to: content, layoutManager: layoutManager)
        }
    }

    private func syntaxCaptures(
        _ pattern: NSRegularExpression,
        capture: Int,
        in range: NSRange,
        source: NSString,
        layoutManager: NSLayoutManager
    ) {
        for match in matches(pattern, range: range, source: source) {
            guard !isProtected(match.range) else { continue }
            applySyntax(to: match.range(at: capture), layoutManager: layoutManager)
        }
    }

    private func applySyntax(to range: NSRange, layoutManager: NSLayoutManager) {
        apply(
            [.foregroundColor: syntaxColor(for: range)],
            to: range,
            layoutManager: layoutManager
        )
    }

    private func syntaxColor(for range: NSRange) -> NSColor {
        rangesIntersect(range, activeLineRange)
            ? theme.activeSyntaxColor
            : theme.syntaxColor
    }

    private func apply(
        _ attributes: [NSAttributedString.Key: Any],
        to range: NSRange,
        layoutManager: NSLayoutManager
    ) {
        guard range.location != NSNotFound, range.length > 0 else { return }
        layoutManager.addTemporaryAttributes(attributes, forCharacterRange: range)
    }

    private func clearTemporaryAttributes(in requestedRange: NSRange?) {
        guard
            let textView,
            let textStorage = textView.textStorage,
            let layoutManager = textView.layoutManager
        else { return }

        let range = clamped(
            requestedRange ?? NSRange(location: 0, length: textStorage.length),
            to: textStorage.length
        )
        guard range.location != NSNotFound else { return }

        // Background and underline are deliberately not owned here. The comment
        // presentation layer may use those temporary-attribute channels without
        // being erased by Markdown re-highlighting.
        for key: NSAttributedString.Key in [
            .foregroundColor,
            .font,
            .strikethroughStyle,
            .strikethroughColor,
        ] {
            layoutManager.removeTemporaryAttribute(key, forCharacterRange: range)
        }
    }

    private func matches(
        _ regex: NSRegularExpression,
        range: NSRange,
        source: NSString
    ) -> [NSTextCheckingResult] {
        regex.matches(in: source as String, range: clamped(range, to: source.length))
    }

    private func isProtected(_ range: NSRange) -> Bool {
        for region in protectedRegions {
            if region.range.location > NSMaxRange(range) { break }
            if rangesIntersect(region.range, range) { return true }
        }
        return false
    }

    private func parseProtectedRegions(in source: NSString) -> [ProtectedRegion] {
        var regions = fencedCodeRegions(in: source)
        regions.append(contentsOf: htmlCommentRegions(in: source))
        return regions.sorted { $0.range.location < $1.range.location }
    }

    private func fencedCodeRegions(in source: NSString) -> [ProtectedRegion] {
        struct OpenFence {
            var character: unichar
            var count: Int
            var start: Int
            var openingRange: NSRange
        }

        var regions: [ProtectedRegion] = []
        var open: OpenFence?
        var cursor = 0

        while cursor < source.length {
            var lineStart = 0
            var lineEnd = 0
            var contentsEnd = 0
            source.getLineStart(
                &lineStart,
                end: &lineEnd,
                contentsEnd: &contentsEnd,
                for: NSRange(location: cursor, length: 0)
            )
            let contentRange = NSRange(location: lineStart, length: contentsEnd - lineStart)
            let line = source.substring(with: contentRange) as NSString
            let fence = fenceMarker(in: line, absoluteLineStart: lineStart)

            if let current = open {
                if let fence,
                   fence.character == current.character,
                   fence.count >= current.count,
                   fence.hasOnlyTrailingWhitespace {
                    regions.append(
                        ProtectedRegion(
                            range: NSRange(
                                location: current.start,
                                length: lineEnd - current.start
                            ),
                            delimiterRanges: [current.openingRange, fence.range],
                            kind: .fencedCode
                        )
                    )
                    open = nil
                }
            } else if let fence, fence.count >= 3 {
                open = OpenFence(
                    character: fence.character,
                    count: fence.count,
                    start: lineStart,
                    openingRange: fence.range
                )
            }

            cursor = max(lineEnd, cursor + 1)
        }

        if let open {
            regions.append(
                ProtectedRegion(
                    range: NSRange(
                        location: open.start,
                        length: source.length - open.start
                    ),
                    delimiterRanges: [open.openingRange],
                    kind: .fencedCode
                )
            )
        }
        return regions
    }

    private func fenceMarker(
        in line: NSString,
        absoluteLineStart: Int
    ) -> (
        character: unichar,
        count: Int,
        range: NSRange,
        hasOnlyTrailingWhitespace: Bool
    )? {
        var cursor = 0
        while cursor < min(3, line.length), line.character(at: cursor) == 0x20 {
            cursor += 1
        }
        guard cursor < line.length else { return nil }

        let character = line.character(at: cursor)
        guard character == 0x60 || character == 0x7E else { return nil }
        let markerStart = cursor
        while cursor < line.length, line.character(at: cursor) == character {
            cursor += 1
        }
        let count = cursor - markerStart
        guard count >= 3 else { return nil }

        let remainder = line.substring(from: cursor)
        let onlyWhitespace = remainder.trimmingCharacters(in: .whitespaces).isEmpty
        return (
            character,
            count,
            NSRange(location: absoluteLineStart + markerStart, length: count),
            onlyWhitespace
        )
    }

    private func htmlCommentRegions(in source: NSString) -> [ProtectedRegion] {
        var regions: [ProtectedRegion] = []
        var cursor = 0
        let openToken = "<!--"
        let closeToken = "-->"

        while cursor < source.length {
            let searchRange = NSRange(location: cursor, length: source.length - cursor)
            let opening = source.range(of: openToken, range: searchRange)
            guard opening.location != NSNotFound else { break }

            let closeSearchStart = NSMaxRange(opening)
            let closeSearch = NSRange(
                location: closeSearchStart,
                length: source.length - closeSearchStart
            )
            let closing = source.range(of: closeToken, range: closeSearch)
            let end = closing.location == NSNotFound
                ? source.length
                : NSMaxRange(closing)
            let delimiters = closing.location == NSNotFound
                ? [opening]
                : [opening, closing]
            regions.append(
                ProtectedRegion(
                    range: NSRange(location: opening.location, length: end - opening.location),
                    delimiterRanges: delimiters,
                    kind: .htmlComment
                )
            )
            cursor = max(end, NSMaxRange(opening))
        }
        return regions
    }

    private func expandedParagraphRange(
        around range: NSRange,
        in source: NSString
    ) -> NSRange {
        guard source.length > 0 else { return NSRange(location: 0, length: 0) }
        let safe = clamped(range, to: source.length)
        let probeLocation = min(safe.location, max(source.length - 1, 0))
        var expanded = source.paragraphRange(
            for: NSRange(location: probeLocation, length: safe.length)
        )

        if expanded.location > 0 {
            let previous = source.paragraphRange(
                for: NSRange(location: expanded.location - 1, length: 0)
            )
            expanded = NSUnionRange(previous, expanded)
        }
        if NSMaxRange(expanded) < source.length {
            let next = source.paragraphRange(
                for: NSRange(location: NSMaxRange(expanded), length: 0)
            )
            expanded = NSUnionRange(expanded, next)
        }
        return clamped(expanded, to: source.length)
    }

    private func clamped(_ range: NSRange, to length: Int) -> NSRange {
        guard range.location != NSNotFound else {
            return NSRange(location: NSNotFound, length: 0)
        }
        let location = min(max(range.location, 0), length)
        return NSRange(
            location: location,
            length: min(max(range.length, 0), length - location)
        )
    }

    private func rangesIntersect(_ lhs: NSRange, _ rhs: NSRange) -> Bool {
        guard lhs.location != NSNotFound, rhs.location != NSNotFound else { return false }
        if lhs.length == 0 || rhs.length == 0 {
            return lhs.location >= rhs.location && lhs.location <= NSMaxRange(rhs)
                || rhs.location >= lhs.location && rhs.location <= NSMaxRange(lhs)
        }
        return NSIntersectionRange(lhs, rhs).length > 0
    }
}
