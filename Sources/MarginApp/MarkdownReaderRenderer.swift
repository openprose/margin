import AppKit

/// A dependency-free, presentation-only Markdown renderer for reader mode.
///
/// The renderer intentionally covers the calm reading path rather than trying
/// to become an HTML engine. Its source mappings let the comments layer convert
/// reader selections back to literal Markdown offsets.
struct MarkdownReaderRenderer {
    struct Theme {
        var bodyFont: NSFont
        var headingFonts: [NSFont]
        var codeFont: NSFont
        var textColor: NSColor
        var secondaryTextColor: NSColor
        var linkColor: NSColor
        var accentColor: NSColor
        var codeBackgroundColor: NSColor
        var separatorColor: NSColor

        var bodyParagraphStyle: NSParagraphStyle
        var quoteParagraphStyle: NSParagraphStyle
        var codeParagraphStyle: NSParagraphStyle

        static func system(bodyFontSize: CGFloat = 18) -> Theme {
            let body = MarginTheme.serifFont(ofSize: bodyFontSize, weight: .regular)
            let headingSizes: [CGFloat] = [31, 25, 21, 18.5, 17, 16]
                .map { $0 * (bodyFontSize / 18) }

            let bodyParagraph = NSMutableParagraphStyle()
            bodyParagraph.lineSpacing = max(6, bodyFontSize * 0.36)
            bodyParagraph.paragraphSpacing = max(11, bodyFontSize * 0.62)
            bodyParagraph.lineBreakMode = .byWordWrapping
            bodyParagraph.hyphenationFactor = 0.18

            let quoteParagraph = bodyParagraph.mutableCopy() as! NSMutableParagraphStyle
            quoteParagraph.headIndent = 24
            quoteParagraph.firstLineHeadIndent = 24
            quoteParagraph.tailIndent = -18
            quoteParagraph.paragraphSpacing = 8

            let codeParagraph = NSMutableParagraphStyle()
            codeParagraph.lineSpacing = 4
            codeParagraph.paragraphSpacingBefore = 10
            codeParagraph.paragraphSpacing = 12
            codeParagraph.headIndent = 14
            codeParagraph.firstLineHeadIndent = 14
            codeParagraph.tailIndent = -14
            codeParagraph.lineBreakMode = .byCharWrapping

            return Theme(
                bodyFont: body,
                headingFonts: headingSizes.enumerated().map { index, size in
                    MarginTheme.serifFont(
                        ofSize: size,
                        weight: index < 2 ? .bold : .semibold
                    )
                },
                codeFont: NSFont.monospacedSystemFont(
                    ofSize: max(bodyFontSize - 2.5, 11),
                    weight: .regular
                ),
                textColor: .labelColor,
                secondaryTextColor: MarginTheme.secondaryInk,
                linkColor: .controlAccentColor,
                accentColor: .controlAccentColor,
                codeBackgroundColor: MarginTheme.codeBackground,
                separatorColor: MarginTheme.rule,
                bodyParagraphStyle: bodyParagraph,
                quoteParagraphStyle: quoteParagraph,
                codeParagraphStyle: codeParagraph
            )
        }

    }

    enum MappingKind: String {
        case text
        case code
        case linkLabel
        case imageDescription
    }

    struct SourceMapping {
        var sourceRange: NSRange
        var renderedRange: NSRange
        var kind: MappingKind
    }

    struct Result {
        var attributedString: NSAttributedString
        var sourceMappings: [SourceMapping]

        /// Returns the smallest reader range containing all visible text mapped
        /// from a source selection. Markdown delimiters may create gaps inside it.
        func renderedRange(for sourceRange: NSRange) -> NSRange? {
            enclosingRange(
                sourceMappings.compactMap { mapping in
                    projectedRange(
                        sourceRange,
                        from: mapping.sourceRange,
                        to: mapping.renderedRange
                    )
                }
            )
        }

        /// Returns the smallest literal-source range represented by a reader
        /// selection. The caller may refine it with its comment-anchor policy.
        func sourceRange(for renderedRange: NSRange) -> NSRange? {
            enclosingRange(
                sourceMappings.compactMap { mapping in
                    projectedRange(
                        renderedRange,
                        from: mapping.renderedRange,
                        to: mapping.sourceRange
                    )
                }
            )
        }

        func renderedRanges(intersecting sourceRange: NSRange) -> [NSRange] {
            sourceMappings.compactMap { mapping in
                projectedRange(
                    sourceRange,
                    from: mapping.sourceRange,
                    to: mapping.renderedRange
                )
            }
        }

        private func projectedRange(
            _ requested: NSRange,
            from source: NSRange,
            to destination: NSRange
        ) -> NSRange? {
            guard
                requested.location != NSNotFound,
                source.location != NSNotFound,
                destination.location != NSNotFound
            else { return nil }

            if requested.length == 0 {
                guard requested.location >= source.location,
                      requested.location <= NSMaxRange(source) else { return nil }
                if source.length == destination.length {
                    return NSRange(
                        location: destination.location
                            + min(requested.location - source.location, destination.length),
                        length: 0
                    )
                }
                guard source.length > 0 else {
                    return NSRange(location: destination.location, length: 0)
                }
                let fraction = CGFloat(requested.location - source.location)
                    / CGFloat(source.length)
                return NSRange(
                    location: destination.location
                        + Int((CGFloat(destination.length) * fraction).rounded()),
                    length: 0
                )
            }

            let intersection = NSIntersectionRange(requested, source)
            guard intersection.length > 0 else { return nil }
            if source.length == destination.length {
                return NSRange(
                    location: destination.location + intersection.location - source.location,
                    length: intersection.length
                )
            }
            guard source.length > 0 else { return nil }
            let startFraction = CGFloat(intersection.location - source.location)
                / CGFloat(source.length)
            let endFraction = CGFloat(NSMaxRange(intersection) - source.location)
                / CGFloat(source.length)
            let projectedStart = destination.location
                + Int(floor(CGFloat(destination.length) * startFraction))
            let projectedEnd = destination.location
                + Int(ceil(CGFloat(destination.length) * endFraction))
            return NSRange(
                location: projectedStart,
                length: max(projectedEnd - projectedStart, 0)
            )
        }

        private func enclosingRange(_ ranges: [NSRange]) -> NSRange? {
            guard
                let first = ranges.min(by: { $0.location < $1.location }),
                let end = ranges.map(NSMaxRange).max()
            else { return nil }
            return NSRange(location: first.location, length: end - first.location)
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

    private struct SourceLine {
        var contentRange: NSRange
        var fullRange: NSRange
    }

    private struct Fence {
        var character: unichar
        var count: Int
        var markerRange: NSRange
        var hasOnlyTrailingWhitespace: Bool
    }

    private struct InlineToken {
        enum Kind {
            case code
            case image
            case link
            case referenceLink
            case strongEmphasis
            case strong
            case emphasis
            case strikethrough
            case autolink
            case escape
        }

        var kind: Kind
        var match: NSTextCheckingResult
        var priority: Int
    }

    private enum Patterns {
        static let atxHeading = regex(#"^( {0,3})(#{1,6})[\t ]+(.+?)(?:[\t ]+#+)?[\t ]*$"#)
        static let setextHeading = regex(#"^( {0,3})(=+|-+)[\t ]*$"#)
        static let blockquote = regex(#"^( {0,3})(>+[\t ]?)(.*)$"#)
        static let listItem = regex(#"^( *)([-+*]|\d+[.)])[\t ]+(?:\[([ xX])\][\t ]+)?(.*)$"#)
        static let thematicBreak = regex(#"^( {0,3})(?:(?:\*[\t ]*){3,}|(?:-[\t ]*){3,}|(?:_[\t ]*){3,})$"#)
        static let referenceDefinition = regex(#"^ {0,3}\[([^\]]+)\]:[\t ]*(?:<([^>]+)>|(\S+))(?:[\t ]+[\"'(]([^\"')]+)[\"')])?[\t ]*$"#)
        static let tableDelimiter = regex(#"^[\t ]*\|?[\t ]*:?-{3,}:?[\t ]*(?:\|[\t ]*:?-{3,}:?[\t ]*)+\|?[\t ]*$"#)

        static let inlineCode = regex(#"(?<!\\)(`+)(?!`)(.+?)(?<!`)\1(?!`)"#)
        static let image = regex(#"!\[([^\]\n]*)\]\(([^)\n\t ]+)(?:[\t ]+[\"']([^\"']*)[\"'])?\)"#)
        static let link = regex(#"(?<!!)\[([^\]\n]+)\]\(([^)\n\t ]+)(?:[\t ]+[\"']([^\"']*)[\"'])?\)"#)
        static let referenceLink = regex(#"(?<!!)\[([^\]\n]+)\]\[([^\]\n]*)\]"#)
        static let strongEmphasisAsterisk = regex(#"(?<!\\)\*\*\*(?=\S)(.+?)(?<=\S)\*\*\*"#)
        static let strongEmphasisUnderscore = regex(#"(?<![\\_])___(?=\S)(.+?)(?<=\S)___(?!_)"#)
        static let strongAsterisk = regex(#"(?<!\\)\*\*(?=\S)(.+?)(?<=\S)\*\*"#)
        static let strongUnderscore = regex(#"(?<![\\_])__(?=\S)(.+?)(?<=\S)__(?!_)"#)
        static let emphasisAsterisk = regex(#"(?<![\\*])\*(?![\s*])(.+?)(?<![\s\\])\*(?!\*)"#)
        static let emphasisUnderscore = regex(#"(?<![\\_])_(?![\s_])(.+?)(?<![\s\\])_(?!_)"#)
        static let strikethrough = regex(#"(?<!\\)~~(?=\S)(.+?)(?<=\S)~~"#)
        static let autolink = regex(#"<(https?://[^>\n]+|mailto:[^>\n]+)>"#)
        static let escape = regex(#"\\([^\p{L}\p{N}\s])"#)

        private static func regex(_ pattern: String) -> NSRegularExpression {
            try! NSRegularExpression(pattern: pattern)
        }
    }

    private final class Builder {
        let output = NSMutableAttributedString()
        var mappings: [SourceMapping] = []

        @discardableResult
        func append(
            _ text: String,
            attributes: [NSAttributedString.Key: Any],
            sourceRange: NSRange? = nil,
            kind: MappingKind = .text
        ) -> NSRange {
            let renderedRange = NSRange(
                location: output.length,
                length: (text as NSString).length
            )
            output.append(NSAttributedString(string: text, attributes: attributes))
            if let sourceRange, renderedRange.length > 0 {
                mappings.append(
                    SourceMapping(
                        sourceRange: sourceRange,
                        renderedRange: renderedRange,
                        kind: kind
                    )
                )
            }
            return renderedRange
        }

        func addAttributes(
            _ attributes: [NSAttributedString.Key: Any],
            range: NSRange
        ) {
            guard range.location != NSNotFound, range.length > 0 else { return }
            output.addAttributes(attributes, range: range)
        }
    }

    var theme: Theme
    var baseURL: URL?

    init(theme: Theme = .system(), baseURL: URL? = nil) {
        self.theme = theme
        self.baseURL = baseURL
    }

    static func prepare(_ textView: NSTextView, theme: Theme = .system()) {
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.importsGraphics = false
        textView.drawsBackground = true
        textView.backgroundColor = MarginTheme.documentBackground
        textView.textContainerInset = NSSize(width: 48, height: 64)
        textView.textContainer?.lineFragmentPadding = 0
        textView.usesFindPanel = true
        textView.isIncrementalSearchingEnabled = true
        textView.linkTextAttributes = [
            .foregroundColor: theme.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .underlineColor: theme.linkColor.withAlphaComponent(0.65),
        ]
        textView.setAccessibilityLabel("Markdown reader")
    }

    func render(_ markdown: String) -> Result {
        let source = markdown as NSString
        let lines = sourceLines(in: source)
        let hiddenRanges = htmlCommentRanges(in: source)
        let references = referenceDefinitions(in: source, lines: lines, hiddenRanges: hiddenRanges)
        let hiddenFrontMatter = frontMatterRange(in: source, lines: lines)
        let builder = Builder()

        var lineIndex = 0
        while lineIndex < lines.count {
            let line = lines[lineIndex]
            let lineText = source.substring(with: line.contentRange)

            if isRangeHidden(line.contentRange, hiddenRanges: hiddenRanges)
                || hiddenFrontMatter.map({ rangesIntersect($0, line.fullRange) }) == true
                || referenceDefinition(on: line, source: source) != nil {
                lineIndex += 1
                continue
            }
            if lineText.trimmingCharacters(in: .whitespaces).isEmpty {
                lineIndex += 1
                continue
            }

            if let fence = fence(in: line, source: source), fence.count >= 3 {
                lineIndex = renderFencedCode(
                    startingAt: lineIndex,
                    openingFence: fence,
                    lines: lines,
                    source: source,
                    builder: builder
                )
                continue
            }

            if let match = firstMatch(Patterns.atxHeading, in: line.contentRange, source: source) {
                let level = min(max(match.range(at: 2).length, 1), 6)
                renderHeading(
                    sourceRange: match.range(at: 3),
                    level: level,
                    source: source,
                    hiddenRanges: hiddenRanges,
                    references: references,
                    builder: builder
                )
                lineIndex += 1
                continue
            }

            if lineIndex + 1 < lines.count,
               let setext = firstMatch(
                   Patterns.setextHeading,
                   in: lines[lineIndex + 1].contentRange,
                   source: source
               ) {
                let marker = source.substring(with: setext.range(at: 2))
                renderHeading(
                    sourceRange: trimmed(line.contentRange, in: source),
                    level: marker.first == "=" ? 1 : 2,
                    source: source,
                    hiddenRanges: hiddenRanges,
                    references: references,
                    builder: builder
                )
                lineIndex += 2
                continue
            }

            if firstMatch(Patterns.thematicBreak, in: line.contentRange, source: source) != nil {
                renderThematicBreak(builder: builder)
                lineIndex += 1
                continue
            }

            if isTableHeader(at: lineIndex, lines: lines, source: source) {
                lineIndex = renderTable(
                    startingAt: lineIndex,
                    lines: lines,
                    source: source,
                    hiddenRanges: hiddenRanges,
                    references: references,
                    builder: builder
                )
                continue
            }

            if let quote = firstMatch(Patterns.blockquote, in: line.contentRange, source: source) {
                lineIndex = renderBlockquote(
                    startingAt: lineIndex,
                    firstMatch: quote,
                    lines: lines,
                    source: source,
                    hiddenRanges: hiddenRanges,
                    references: references,
                    builder: builder
                )
                continue
            }

            if let item = firstMatch(Patterns.listItem, in: line.contentRange, source: source) {
                lineIndex = renderList(
                    startingAt: lineIndex,
                    firstMatch: item,
                    lines: lines,
                    source: source,
                    hiddenRanges: hiddenRanges,
                    references: references,
                    builder: builder
                )
                continue
            }

            if lineText.hasPrefix("    ") || lineText.hasPrefix("\t") {
                lineIndex = renderIndentedCode(
                    startingAt: lineIndex,
                    lines: lines,
                    source: source,
                    builder: builder
                )
                continue
            }

            lineIndex = renderParagraph(
                startingAt: lineIndex,
                lines: lines,
                source: source,
                hiddenRanges: hiddenRanges,
                references: references,
                builder: builder
            )
        }

        return Result(
            attributedString: builder.output.copy() as! NSAttributedString,
            sourceMappings: builder.mappings
        )
    }

    @discardableResult
    func display(_ markdown: String, in textView: NSTextView) -> Result {
        Self.prepare(textView, theme: theme)
        let result = render(markdown)
        textView.textStorage?.setAttributedString(result.attributedString)
        return result
    }

    private func renderHeading(
        sourceRange: NSRange,
        level: Int,
        source: NSString,
        hiddenRanges: [NSRange],
        references: [String: String],
        builder: Builder
    ) {
        let index = min(max(level - 1, 0), theme.headingFonts.count - 1)
        let paragraph = headingParagraphStyle(level: level)
        let attributes = baseAttributes(
            font: theme.headingFonts[index],
            color: theme.textColor,
            paragraph: paragraph
        )
        renderInline(
            range: sourceRange,
            source: source,
            attributes: attributes,
            hiddenRanges: hiddenRanges,
            references: references,
            builder: builder
        )
        builder.append("\n", attributes: attributes)
    }

    private func renderFencedCode(
        startingAt start: Int,
        openingFence: Fence,
        lines: [SourceLine],
        source: NSString,
        builder: Builder
    ) -> Int {
        let attributes = baseAttributes(
            font: theme.codeFont,
            color: theme.textColor,
            paragraph: theme.codeParagraphStyle,
            additional: [.backgroundColor: theme.codeBackgroundColor]
        )

        var index = start + 1
        while index < lines.count {
            let line = lines[index]
            if let candidate = fence(in: line, source: source),
               candidate.character == openingFence.character,
               candidate.count >= openingFence.count,
               candidate.hasOnlyTrailingWhitespace {
                if builder.output.length == 0 || !builder.output.string.hasSuffix("\n") {
                    builder.append("\n", attributes: attributes)
                }
                return index + 1
            }

            builder.append(
                source.substring(with: line.contentRange),
                attributes: attributes,
                sourceRange: line.contentRange,
                kind: .code
            )
            builder.append("\n", attributes: attributes)
            index += 1
        }
        return index
    }

    private func renderIndentedCode(
        startingAt start: Int,
        lines: [SourceLine],
        source: NSString,
        builder: Builder
    ) -> Int {
        let attributes = baseAttributes(
            font: theme.codeFont,
            color: theme.textColor,
            paragraph: theme.codeParagraphStyle,
            additional: [.backgroundColor: theme.codeBackgroundColor]
        )
        var index = start
        while index < lines.count {
            let text = source.substring(with: lines[index].contentRange)
            let prefixLength = text.hasPrefix("    ") ? 4 : (text.hasPrefix("\t") ? 1 : 0)
            guard prefixLength > 0 else { break }
            let contentRange = NSRange(
                location: lines[index].contentRange.location + prefixLength,
                length: lines[index].contentRange.length - prefixLength
            )
            builder.append(
                source.substring(with: contentRange),
                attributes: attributes,
                sourceRange: contentRange,
                kind: .code
            )
            builder.append("\n", attributes: attributes)
            index += 1
        }
        return index
    }

    private func renderBlockquote(
        startingAt start: Int,
        firstMatch initialMatch: NSTextCheckingResult,
        lines: [SourceLine],
        source: NSString,
        hiddenRanges: [NSRange],
        references: [String: String],
        builder: Builder
    ) -> Int {
        _ = initialMatch
        let italic = font(byAdding: .italicFontMask, to: theme.bodyFont)
        let attributes = baseAttributes(
            font: italic,
            color: theme.secondaryTextColor,
            paragraph: theme.quoteParagraphStyle
        )
        var index = start
        while index < lines.count,
              let match = firstMatch(Patterns.blockquote, in: lines[index].contentRange, source: source) {
            let contentRange = match.range(at: 3)
            renderInline(
                range: contentRange,
                source: source,
                attributes: attributes,
                hiddenRanges: hiddenRanges,
                references: references,
                builder: builder
            )
            builder.append("\n", attributes: attributes)
            index += 1
        }
        return index
    }

    private func renderList(
        startingAt start: Int,
        firstMatch initialMatch: NSTextCheckingResult,
        lines: [SourceLine],
        source: NSString,
        hiddenRanges: [NSRange],
        references: [String: String],
        builder: Builder
    ) -> Int {
        _ = initialMatch
        var index = start
        while index < lines.count,
              let match = firstMatch(Patterns.listItem, in: lines[index].contentRange, source: source) {
            let indentation = match.range(at: 1).length
            let depth = max(0, indentation / 2)
            let sourceMarker = source.substring(with: match.range(at: 2))
            let checkboxRange = match.range(at: 3)
            let marker: String
            let markerColor: NSColor

            if checkboxRange.location != NSNotFound {
                let state = source.substring(with: checkboxRange).lowercased()
                marker = state == "x" ? "☑" : "☐"
                markerColor = state == "x" ? theme.accentColor : theme.secondaryTextColor
            } else if sourceMarker.first?.isNumber == true {
                marker = sourceMarker
                markerColor = theme.secondaryTextColor
            } else {
                marker = "•"
                markerColor = theme.secondaryTextColor
            }

            let paragraph = listParagraphStyle(depth: depth)
            let attributes = baseAttributes(
                font: theme.bodyFont,
                color: theme.textColor,
                paragraph: paragraph
            )
            builder.append(
                marker + "\t",
                attributes: baseAttributes(
                    font: theme.bodyFont,
                    color: markerColor,
                    paragraph: paragraph
                )
            )
            renderInline(
                range: match.range(at: 4),
                source: source,
                attributes: attributes,
                hiddenRanges: hiddenRanges,
                references: references,
                builder: builder
            )
            builder.append("\n", attributes: attributes)
            index += 1
        }
        return index
    }

    private func renderParagraph(
        startingAt start: Int,
        lines: [SourceLine],
        source: NSString,
        hiddenRanges: [NSRange],
        references: [String: String],
        builder: Builder
    ) -> Int {
        let attributes = baseAttributes(
            font: theme.bodyFont,
            color: theme.textColor,
            paragraph: theme.bodyParagraphStyle
        )
        var index = start
        var appendedLine = false
        var previousLineHadHardBreak = false

        while index < lines.count {
            let line = lines[index]
            let text = source.substring(with: line.contentRange)
            if text.trimmingCharacters(in: .whitespaces).isEmpty { break }
            if index > start, isBlockStart(at: index, lines: lines, source: source) { break }
            if isRangeHidden(line.contentRange, hiddenRanges: hiddenRanges) {
                index += 1
                continue
            }

            let hardBreak = text.hasSuffix("  ") || text.hasSuffix("\\")
            var contentRange = trimmed(line.contentRange, in: source)
            if hardBreak, contentRange.length > 0,
               source.character(at: NSMaxRange(contentRange) - 1) == 0x5C {
                contentRange.length -= 1
                contentRange = trimmed(contentRange, in: source)
            }

            if appendedLine {
                builder.append(
                    previousLineHadHardBreak ? "\n" : " ",
                    attributes: attributes
                )
            }
            renderInline(
                range: contentRange,
                source: source,
                attributes: attributes,
                hiddenRanges: hiddenRanges,
                references: references,
                builder: builder
            )
            appendedLine = true
            previousLineHadHardBreak = hardBreak
            index += 1
        }

        if appendedLine {
            builder.append("\n", attributes: attributes)
        }
        return max(index, start + 1)
    }

    private func renderThematicBreak(builder: Builder) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacingBefore = 14
        paragraph.paragraphSpacing = 17
        let attributes = baseAttributes(
            font: theme.bodyFont,
            color: theme.separatorColor,
            paragraph: paragraph,
            additional: [
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .underlineColor: theme.separatorColor,
            ]
        )
        builder.append(String(repeating: "\u{2003}", count: 12), attributes: attributes)
        builder.append("\n", attributes: attributes)
    }

    private func renderTable(
        startingAt start: Int,
        lines: [SourceLine],
        source: NSString,
        hiddenRanges: [NSRange],
        references: [String: String],
        builder: Builder
    ) -> Int {
        var index = start
        var isHeader = true
        let columnCount = max(tableCells(in: lines[start].contentRange, source: source).count, 1)
        let paragraph = tableParagraphStyle(columnCount: columnCount)

        while index < lines.count {
            if index == start + 1 {
                index += 1
                continue
            }
            let cells = tableCells(in: lines[index].contentRange, source: source)
            guard !cells.isEmpty else { break }

            let font = isHeader
                ? font(byAdding: .boldFontMask, to: theme.bodyFont)
                : theme.bodyFont
            let attributes = baseAttributes(
                font: font,
                color: theme.textColor,
                paragraph: paragraph
            )
            for (cellIndex, cellRange) in cells.enumerated() {
                if cellIndex > 0 {
                    builder.append("\t", attributes: attributes)
                }
                renderInline(
                    range: cellRange,
                    source: source,
                    attributes: attributes,
                    hiddenRanges: hiddenRanges,
                    references: references,
                    builder: builder
                )
            }
            builder.append("\n", attributes: attributes)
            isHeader = false
            index += 1

            if index < lines.count,
               !source.substring(with: lines[index].contentRange).contains("|") {
                break
            }
        }
        return index
    }

    private func renderInline(
        range: NSRange,
        source: NSString,
        attributes: [NSAttributedString.Key: Any],
        hiddenRanges: [NSRange],
        references: [String: String],
        builder: Builder
    ) {
        guard range.location != NSNotFound, range.length > 0 else { return }
        var cursor = range.location
        let end = NSMaxRange(range)

        for hidden in hiddenRanges where rangesIntersect(hidden, range) {
            if cursor < hidden.location {
                renderVisibleInline(
                    range: NSRange(location: cursor, length: hidden.location - cursor),
                    source: source,
                    attributes: attributes,
                    references: references,
                    builder: builder
                )
            }
            cursor = max(cursor, min(NSMaxRange(hidden), end))
        }
        if cursor < end {
            renderVisibleInline(
                range: NSRange(location: cursor, length: end - cursor),
                source: source,
                attributes: attributes,
                references: references,
                builder: builder
            )
        }
    }

    private func renderVisibleInline(
        range: NSRange,
        source: NSString,
        attributes: [NSAttributedString.Key: Any],
        references: [String: String],
        builder: Builder
    ) {
        guard range.length > 0 else { return }
        var cursor = range.location
        let end = NSMaxRange(range)

        while cursor < end {
            let search = NSRange(location: cursor, length: end - cursor)
            guard let token = nextInlineToken(in: search, source: source) else {
                builder.append(
                    source.substring(with: search),
                    attributes: attributes,
                    sourceRange: search
                )
                break
            }

            if token.match.range.location > cursor {
                let literal = NSRange(
                    location: cursor,
                    length: token.match.range.location - cursor
                )
                builder.append(
                    source.substring(with: literal),
                    attributes: attributes,
                    sourceRange: literal
                )
            }

            render(
                token: token,
                source: source,
                attributes: attributes,
                references: references,
                builder: builder
            )
            cursor = NSMaxRange(token.match.range)
        }
    }

    private func render(
        token: InlineToken,
        source: NSString,
        attributes: [NSAttributedString.Key: Any],
        references: [String: String],
        builder: Builder
    ) {
        switch token.kind {
        case .code:
            let content = token.match.range(at: 2)
            var codeAttributes = attributes
            codeAttributes[.font] = theme.codeFont
            codeAttributes[.backgroundColor] = theme.codeBackgroundColor
            builder.append(
                source.substring(with: content),
                attributes: codeAttributes,
                sourceRange: content,
                kind: .code
            )

        case .image:
            let altRange = token.match.range(at: 1)
            let destination = source.substring(with: token.match.range(at: 2))
            let italic = font(
                byAdding: .italicFontMask,
                to: attributes[.font] as? NSFont ?? theme.bodyFont
            )
            var imageAttributes = attributes
            imageAttributes[.font] = italic
            imageAttributes[.foregroundColor] = theme.secondaryTextColor
            builder.append("Image: ", attributes: imageAttributes)
            let rendered = builder.append(
                source.substring(with: altRange),
                attributes: imageAttributes,
                sourceRange: altRange,
                kind: .imageDescription
            )
            if let url = resolvedURL(destination) {
                builder.addAttributes([.link: url], range: rendered)
            }

        case .link:
            let label = token.match.range(at: 1)
            let destination = source.substring(with: token.match.range(at: 2))
            let start = builder.output.length
            renderVisibleInline(
                range: label,
                source: source,
                attributes: attributes,
                references: references,
                builder: builder
            )
            let rendered = NSRange(location: start, length: builder.output.length - start)
            if let url = resolvedURL(destination) {
                builder.addAttributes(
                    [.link: url, .foregroundColor: theme.linkColor],
                    range: rendered
                )
            }
            retagMappings(in: rendered, as: .linkLabel, builder: builder)

        case .referenceLink:
            let label = token.match.range(at: 1)
            let referenceRange = token.match.range(at: 2)
            let rawReference = referenceRange.length > 0
                ? source.substring(with: referenceRange)
                : source.substring(with: label)
            let key = normalizedReference(rawReference)
            guard let destination = references[key] else {
                builder.append(
                    source.substring(with: token.match.range),
                    attributes: attributes,
                    sourceRange: token.match.range
                )
                return
            }
            let start = builder.output.length
            renderVisibleInline(
                range: label,
                source: source,
                attributes: attributes,
                references: references,
                builder: builder
            )
            let rendered = NSRange(location: start, length: builder.output.length - start)
            if let url = resolvedURL(destination) {
                builder.addAttributes(
                    [.link: url, .foregroundColor: theme.linkColor],
                    range: rendered
                )
            }
            retagMappings(in: rendered, as: .linkLabel, builder: builder)

        case .strongEmphasis:
            var styled = attributes
            let base = attributes[.font] as? NSFont ?? theme.bodyFont
            styled[.font] = font(
                byAdding: [.boldFontMask, .italicFontMask],
                to: base
            )
            renderVisibleInline(
                range: token.match.range(at: 1),
                source: source,
                attributes: styled,
                references: references,
                builder: builder
            )

        case .strong:
            var styled = attributes
            styled[.font] = font(
                byAdding: .boldFontMask,
                to: attributes[.font] as? NSFont ?? theme.bodyFont
            )
            renderVisibleInline(
                range: token.match.range(at: 1),
                source: source,
                attributes: styled,
                references: references,
                builder: builder
            )

        case .emphasis:
            var styled = attributes
            styled[.font] = font(
                byAdding: .italicFontMask,
                to: attributes[.font] as? NSFont ?? theme.bodyFont
            )
            renderVisibleInline(
                range: token.match.range(at: 1),
                source: source,
                attributes: styled,
                references: references,
                builder: builder
            )

        case .strikethrough:
            let start = builder.output.length
            renderVisibleInline(
                range: token.match.range(at: 1),
                source: source,
                attributes: attributes,
                references: references,
                builder: builder
            )
            builder.addAttributes(
                [
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .strikethroughColor: theme.secondaryTextColor,
                ],
                range: NSRange(location: start, length: builder.output.length - start)
            )

        case .autolink:
            let visible = token.match.range(at: 1)
            let value = source.substring(with: visible)
            let rendered = builder.append(
                value,
                attributes: attributes,
                sourceRange: visible,
                kind: .linkLabel
            )
            if let url = resolvedURL(value) {
                builder.addAttributes(
                    [.link: url, .foregroundColor: theme.linkColor],
                    range: rendered
                )
            }

        case .escape:
            let escaped = token.match.range(at: 1)
            builder.append(
                source.substring(with: escaped),
                attributes: attributes,
                sourceRange: token.match.range
            )
        }
    }

    private func nextInlineToken(in range: NSRange, source: NSString) -> InlineToken? {
        let candidates: [(InlineToken.Kind, NSRegularExpression)] = [
            (.code, Patterns.inlineCode),
            (.image, Patterns.image),
            (.link, Patterns.link),
            (.referenceLink, Patterns.referenceLink),
            (.strongEmphasis, Patterns.strongEmphasisAsterisk),
            (.strongEmphasis, Patterns.strongEmphasisUnderscore),
            (.strong, Patterns.strongAsterisk),
            (.strong, Patterns.strongUnderscore),
            (.emphasis, Patterns.emphasisAsterisk),
            (.emphasis, Patterns.emphasisUnderscore),
            (.strikethrough, Patterns.strikethrough),
            (.autolink, Patterns.autolink),
            (.escape, Patterns.escape),
        ]

        var best: InlineToken?
        for (priority, candidate) in candidates.enumerated() {
            guard let match = candidate.1.firstMatch(
                in: source as String,
                range: range
            ) else { continue }
            let token = InlineToken(kind: candidate.0, match: match, priority: priority)
            if best == nil
                || match.range.location < best!.match.range.location
                || (match.range.location == best!.match.range.location
                    && priority < best!.priority) {
                best = token
            }
        }
        return best
    }

    private func sourceLines(in source: NSString) -> [SourceLine] {
        guard source.length > 0 else { return [] }
        var lines: [SourceLine] = []
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
            lines.append(
                SourceLine(
                    contentRange: NSRange(
                        location: lineStart,
                        length: contentsEnd - lineStart
                    ),
                    fullRange: NSRange(
                        location: lineStart,
                        length: lineEnd - lineStart
                    )
                )
            )
            cursor = max(lineEnd, cursor + 1)
        }
        return lines
    }

    private func firstMatch(
        _ regex: NSRegularExpression,
        in range: NSRange,
        source: NSString
    ) -> NSTextCheckingResult? {
        regex.firstMatch(in: source as String, range: range)
    }

    private func fence(in line: SourceLine, source: NSString) -> Fence? {
        let text = source.substring(with: line.contentRange) as NSString
        var cursor = 0
        while cursor < min(3, text.length), text.character(at: cursor) == 0x20 {
            cursor += 1
        }
        guard cursor < text.length else { return nil }
        let character = text.character(at: cursor)
        guard character == 0x60 || character == 0x7E else { return nil }

        let markerStart = cursor
        while cursor < text.length, text.character(at: cursor) == character {
            cursor += 1
        }
        let count = cursor - markerStart
        guard count >= 3 else { return nil }
        let trailing = text.substring(from: cursor)
        return Fence(
            character: character,
            count: count,
            markerRange: NSRange(
                location: line.contentRange.location + markerStart,
                length: count
            ),
            hasOnlyTrailingWhitespace: trailing
                .trimmingCharacters(in: .whitespaces)
                .isEmpty
        )
    }

    private func isBlockStart(
        at index: Int,
        lines: [SourceLine],
        source: NSString
    ) -> Bool {
        let line = lines[index]
        let text = source.substring(with: line.contentRange)
        if text.trimmingCharacters(in: .whitespaces).isEmpty { return true }
        if fence(in: line, source: source) != nil { return true }
        if firstMatch(Patterns.atxHeading, in: line.contentRange, source: source) != nil { return true }
        if firstMatch(Patterns.blockquote, in: line.contentRange, source: source) != nil { return true }
        if firstMatch(Patterns.listItem, in: line.contentRange, source: source) != nil { return true }
        if firstMatch(Patterns.thematicBreak, in: line.contentRange, source: source) != nil { return true }
        if referenceDefinition(on: line, source: source) != nil { return true }
        if text.hasPrefix("    ") || text.hasPrefix("\t") { return true }
        return isTableHeader(at: index, lines: lines, source: source)
    }

    private func referenceDefinition(
        on line: SourceLine,
        source: NSString
    ) -> (key: String, destination: String)? {
        guard let match = firstMatch(
            Patterns.referenceDefinition,
            in: line.contentRange,
            source: source
        ) else { return nil }
        let destinationRange = match.range(at: 2).location != NSNotFound
            ? match.range(at: 2)
            : match.range(at: 3)
        return (
            normalizedReference(source.substring(with: match.range(at: 1))),
            source.substring(with: destinationRange)
        )
    }

    private func referenceDefinitions(
        in source: NSString,
        lines: [SourceLine],
        hiddenRanges: [NSRange]
    ) -> [String: String] {
        var definitions: [String: String] = [:]
        for line in lines where !isRangeHidden(line.contentRange, hiddenRanges: hiddenRanges) {
            if let definition = referenceDefinition(on: line, source: source) {
                definitions[definition.key] = definition.destination
            }
        }
        return definitions
    }

    private func normalizedReference(_ value: String) -> String {
        value
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .lowercased()
    }

    private func isTableHeader(
        at index: Int,
        lines: [SourceLine],
        source: NSString
    ) -> Bool {
        guard index + 1 < lines.count else { return false }
        let header = source.substring(with: lines[index].contentRange)
        guard header.contains("|") else { return false }
        return firstMatch(
            Patterns.tableDelimiter,
            in: lines[index + 1].contentRange,
            source: source
        ) != nil
    }

    private func tableCells(in range: NSRange, source: NSString) -> [NSRange] {
        let text = source.substring(with: range) as NSString
        var start = 0
        var end = text.length
        while start < end, text.character(at: start) == 0x20 { start += 1 }
        while end > start, text.character(at: end - 1) == 0x20 { end -= 1 }
        if start < end, text.character(at: start) == 0x7C { start += 1 }
        if end > start, text.character(at: end - 1) == 0x7C { end -= 1 }

        var cells: [NSRange] = []
        var cellStart = start
        var cursor = start
        var escaped = false
        while cursor <= end {
            let isBoundary = cursor == end
                || (text.character(at: cursor) == 0x7C && !escaped)
            if isBoundary {
                let local = NSRange(location: cellStart, length: cursor - cellStart)
                cells.append(
                    trimmed(
                        NSRange(
                            location: range.location + local.location,
                            length: local.length
                        ),
                        in: source
                    )
                )
                cellStart = cursor + 1
            }
            if cursor < end {
                escaped = text.character(at: cursor) == 0x5C && !escaped
                if text.character(at: cursor) != 0x5C { escaped = false }
            }
            cursor += 1
        }
        return cells.filter { $0.length > 0 }
    }

    private func htmlCommentRanges(in source: NSString) -> [NSRange] {
        var ranges: [NSRange] = []
        var cursor = 0
        while cursor < source.length {
            let opening = source.range(
                of: "<!--",
                range: NSRange(location: cursor, length: source.length - cursor)
            )
            guard opening.location != NSNotFound else { break }
            let searchStart = NSMaxRange(opening)
            let closing = source.range(
                of: "-->",
                range: NSRange(
                    location: searchStart,
                    length: source.length - searchStart
                )
            )
            let end = closing.location == NSNotFound ? source.length : NSMaxRange(closing)
            ranges.append(
                NSRange(location: opening.location, length: end - opening.location)
            )
            cursor = max(end, searchStart)
        }
        return ranges
    }

    private func frontMatterRange(
        in source: NSString,
        lines: [SourceLine]
    ) -> NSRange? {
        guard let first = lines.first else { return nil }
        let opening = source.substring(with: first.contentRange)
            .trimmingCharacters(in: .whitespaces)
        guard opening == "---" else { return nil }

        for line in lines.dropFirst() {
            let marker = source.substring(with: line.contentRange)
                .trimmingCharacters(in: .whitespaces)
            if marker == "---" || marker == "..." {
                return NSRange(
                    location: first.fullRange.location,
                    length: NSMaxRange(line.fullRange) - first.fullRange.location
                )
            }
        }
        return nil
    }

    private func isRangeHidden(
        _ range: NSRange,
        hiddenRanges: [NSRange]
    ) -> Bool {
        hiddenRanges.contains { hidden in
            hidden.location <= range.location && NSMaxRange(hidden) >= NSMaxRange(range)
        }
    }

    private func trimmed(_ range: NSRange, in source: NSString) -> NSRange {
        guard range.location != NSNotFound else { return range }
        var location = range.location
        var end = NSMaxRange(range)
        while location < end {
            let character = source.character(at: location)
            guard character == 0x20 || character == 0x09 else { break }
            location += 1
        }
        while end > location {
            let character = source.character(at: end - 1)
            guard character == 0x20 || character == 0x09 else { break }
            end -= 1
        }
        return NSRange(location: location, length: end - location)
    }

    private func baseAttributes(
        font: NSFont,
        color: NSColor,
        paragraph: NSParagraphStyle,
        additional: [NSAttributedString.Key: Any] = [:]
    ) -> [NSAttributedString.Key: Any] {
        var attributes = additional
        attributes[.font] = font
        attributes[.foregroundColor] = color
        attributes[.paragraphStyle] = paragraph
        return attributes
    }

    private func headingParagraphStyle(level: Int) -> NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        switch level {
        case 1:
            paragraph.paragraphSpacingBefore = 28
            paragraph.paragraphSpacing = 13
        case 2:
            paragraph.paragraphSpacingBefore = 23
            paragraph.paragraphSpacing = 11
        case 3:
            paragraph.paragraphSpacingBefore = 18
            paragraph.paragraphSpacing = 8
        default:
            paragraph.paragraphSpacingBefore = 13
            paragraph.paragraphSpacing = 6
        }
        return paragraph
    }

    private func listParagraphStyle(depth: Int) -> NSParagraphStyle {
        let paragraph = theme.bodyParagraphStyle.mutableCopy() as! NSMutableParagraphStyle
        let baseIndent = CGFloat(depth) * 22
        paragraph.firstLineHeadIndent = baseIndent
        paragraph.headIndent = baseIndent + 27
        paragraph.tabStops = [
            NSTextTab(
                textAlignment: .left,
                location: baseIndent + 27,
                options: [:]
            ),
        ]
        paragraph.paragraphSpacing = 5
        return paragraph
    }

    private func tableParagraphStyle(columnCount: Int) -> NSParagraphStyle {
        let paragraph = theme.bodyParagraphStyle.mutableCopy() as! NSMutableParagraphStyle
        paragraph.lineSpacing = 4
        paragraph.paragraphSpacing = 5
        let columnWidth = max(118, 650 / CGFloat(max(columnCount, 1)))
        paragraph.tabStops = (1..<columnCount).map { index in
            NSTextTab(
                textAlignment: .left,
                location: CGFloat(index) * columnWidth,
                options: [:]
            )
        }
        return paragraph
    }

    private func font(
        byAdding traits: NSFontTraitMask,
        to font: NSFont
    ) -> NSFont {
        NSFontManager.shared.convert(font, toHaveTrait: traits)
    }

    private func resolvedURL(_ rawValue: String) -> URL? {
        let value = rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        if let absolute = URL(string: value), absolute.scheme != nil {
            return absolute
        }
        guard let baseURL else { return URL(string: value) }
        return URL(string: value, relativeTo: baseURL)?.absoluteURL
    }

    private func retagMappings(
        in renderedRange: NSRange,
        as kind: MappingKind,
        builder: Builder
    ) {
        for index in builder.mappings.indices
        where rangesIntersect(builder.mappings[index].renderedRange, renderedRange) {
            builder.mappings[index].kind = kind
        }
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
