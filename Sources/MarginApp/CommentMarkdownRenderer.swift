import AppKit

/// Comment bodies are Markdown too. This adapts Margin's existing native
/// reader parser to inspector-scale typography, so comment text is legible
/// without WebKit, HTML, or a second parsing dependency.
struct CommentMarkdownRenderer {
    static func render(
        _ markdown: String,
        foregroundColor: NSColor = .labelColor
    ) -> NSAttributedString {
        guard !markdown.isEmpty else { return NSAttributedString(string: "") }

        var theme = baseTheme
        theme.textColor = foregroundColor
        theme.secondaryTextColor = foregroundColor.withAlphaComponent(0.78)
        let rendered = MarkdownReaderRenderer(theme: theme).render(markdown).attributedString
        let result = NSMutableAttributedString(attributedString: rendered)

        while result.length > 0,
              (result.string as NSString).character(at: result.length - 1) == 0x0A {
            result.deleteCharacters(in: NSRange(location: result.length - 1, length: 1))
        }
        return result
    }

    private static let baseTheme: MarkdownReaderRenderer.Theme = {
        let bodySize: CGFloat = 13.25
        let bodyParagraph = NSMutableParagraphStyle()
        bodyParagraph.lineSpacing = 2.5
        bodyParagraph.paragraphSpacing = 5
        bodyParagraph.lineBreakMode = .byWordWrapping

        let quoteParagraph = bodyParagraph.mutableCopy() as! NSMutableParagraphStyle
        quoteParagraph.headIndent = 14
        quoteParagraph.firstLineHeadIndent = 14
        quoteParagraph.tailIndent = -8

        let codeParagraph = bodyParagraph.mutableCopy() as! NSMutableParagraphStyle
        codeParagraph.headIndent = 8
        codeParagraph.firstLineHeadIndent = 8
        codeParagraph.tailIndent = -8
        codeParagraph.lineSpacing = 2

        return MarkdownReaderRenderer.Theme(
            bodyFont: .systemFont(ofSize: bodySize),
            headingFonts: [
                .systemFont(ofSize: 15.5, weight: .semibold),
                .systemFont(ofSize: 14.5, weight: .semibold),
                .systemFont(ofSize: 13.75, weight: .semibold),
                .systemFont(ofSize: bodySize, weight: .semibold),
                .systemFont(ofSize: bodySize, weight: .medium),
                .systemFont(ofSize: bodySize, weight: .medium),
            ],
            codeFont: .monospacedSystemFont(ofSize: 12, weight: .regular),
            textColor: .labelColor,
            secondaryTextColor: .secondaryLabelColor,
            linkColor: .linkColor,
            accentColor: .controlAccentColor,
            codeBackgroundColor: MarginTheme.codeBackground,
            separatorColor: MarginTheme.rule,
            bodyParagraphStyle: bodyParagraph,
            quoteParagraphStyle: quoteParagraph,
            codeParagraphStyle: codeParagraph
        )
    }()
}
