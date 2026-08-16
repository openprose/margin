import AppKit

/// Hosts reader mode in a native, selectable text view with a centered measure.
/// Source selections and comment ranges stay in literal Markdown coordinates;
/// this controller translates them through `MarkdownReaderRenderer.Result`.
final class ReaderViewController: NSViewController {
    struct CommentHighlight {
        enum State {
            case normal
            case active
            case resolved
        }

        var id: String
        var sourceRange: NSRange
        var state: State

        init(id: String, sourceRange: NSRange, state: State = .normal) {
            self.id = id
            self.sourceRange = sourceRange
            self.state = state
        }
    }

    private struct PreservedState {
        var selectionInSource: NSRange?
        var scrollAnchorInSource: NSRange?
        var scrollAnchorOffset: CGFloat
        var scrollFraction: CGFloat
    }

    private final class CenteredReaderTextView: NSTextView {
        var maximumTextWidth: CGFloat = 690 {
            didSet { updateCenteredInset() }
        }
        var minimumHorizontalInset: CGFloat = 44 {
            didSet { updateCenteredInset() }
        }
        var verticalInset: CGFloat = 64 {
            didSet { updateCenteredInset() }
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            updateCenteredInset()
        }

        func updateCenteredInset() {
            let centeredInset = floor((bounds.width - maximumTextWidth) / 2)
            let horizontalInset = max(minimumHorizontalInset, centeredInset)
            let next = NSSize(width: horizontalInset, height: verticalInset)
            guard abs(textContainerInset.width - next.width) > 0.5
                    || abs(textContainerInset.height - next.height) > 0.5
            else { return }
            textContainerInset = next
        }
    }

    private let theme: MarkdownReaderRenderer.Theme
    private let readerTextView: CenteredReaderTextView
    private let readerScrollView: NSScrollView

    private(set) var renderResult: MarkdownReaderRenderer.Result?
    private(set) var markdown: String = ""
    private(set) var baseURL: URL?
    private var commentHighlights: [CommentHighlight] = []
    private var renderedHighlightRanges: [NSRange] = []
    private var renderGeneration = UUID()

    var textView: NSTextView { readerTextView }

    var maximumTextWidth: CGFloat {
        get { readerTextView.maximumTextWidth }
        set {
            readerTextView.maximumTextWidth = max(newValue, 320)
            sizeDocumentViewToContent()
        }
    }

    var selectedSourceRange: NSRange? {
        sourceRange(forReaderRange: readerTextView.selectedRange())
    }

    init(theme: MarkdownReaderRenderer.Theme = .system()) {
        self.theme = theme

        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(
            containerSize: NSSize(
                width: 690,
                height: CGFloat.greatestFiniteMagnitude
            )
        )
        textStorage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)
        textContainer.widthTracksTextView = true

        readerTextView = CenteredReaderTextView(
            frame: NSRect(x: 0, y: 0, width: 690, height: 640),
            textContainer: textContainer
        )
        readerScrollView = NSScrollView(
            frame: NSRect(x: 0, y: 0, width: 690, height: 640)
        )
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        theme = .system()

        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(
            containerSize: NSSize(
                width: 690,
                height: CGFloat.greatestFiniteMagnitude
            )
        )
        textStorage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)
        textContainer.widthTracksTextView = true

        readerTextView = CenteredReaderTextView(
            frame: NSRect(x: 0, y: 0, width: 690, height: 640),
            textContainer: textContainer
        )
        readerScrollView = NSScrollView(
            frame: NSRect(x: 0, y: 0, width: 690, height: 640)
        )
        super.init(coder: coder)
    }

    override func loadView() {
        ReaderViewController.configure(
            readerTextView,
            in: readerScrollView,
            theme: theme
        )
        view = readerScrollView
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        sizeDocumentViewToContent()
    }

    /// Re-renders Markdown while preserving the current reader selection and
    /// first visible source position whenever those positions still exist.
    @discardableResult
    func render(
        markdown: String,
        baseURL: URL?
    ) -> MarkdownReaderRenderer.Result {
        // Accessing `view` is the macOS 13-compatible way to force `loadView()`.
        _ = view
        let preserved = captureState()
        renderGeneration = UUID()

        let renderer = MarkdownReaderRenderer(theme: theme, baseURL: baseURL)
        let result = renderer.render(markdown)
        apply(
            result,
            markdown: markdown,
            baseURL: baseURL,
            preserved: preserved,
            preferredSourceSelection: nil
        )
        return result
    }

    /// Builds the attributed reader document away from the main interaction
    /// path, then installs it atomically. A newer request invalidates older
    /// work so rapidly switching files or modes never flashes stale content.
    func renderAsync(
        markdown: String,
        baseURL: URL?,
        preferredSourceSelection: NSRange? = nil,
        completion: ((Bool) -> Void)? = nil
    ) {
        _ = view
        let generation = UUID()
        renderGeneration = generation
        let preserved = captureState()
        let theme = theme

        if renderResult == nil {
            let preparing = NSAttributedString(
                string: "Preparing reader…",
                attributes: [
                    .font: theme.bodyFont,
                    .foregroundColor: theme.secondaryTextColor,
                    .paragraphStyle: theme.bodyParagraphStyle,
                ]
            )
            readerTextView.textStorage?.setAttributedString(preparing)
            sizeDocumentViewToContent()
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = MarkdownReaderRenderer(theme: theme, baseURL: baseURL).render(markdown)
            DispatchQueue.main.async {
                guard let self, self.renderGeneration == generation else {
                    completion?(false)
                    return
                }
                self.apply(
                    result,
                    markdown: markdown,
                    baseURL: baseURL,
                    preserved: preserved,
                    preferredSourceSelection: preferredSourceSelection
                )
                completion?(true)
            }
        }
    }

    func readerRange(forSourceRange sourceRange: NSRange) -> NSRange? {
        renderResult?.renderedRange(for: sourceRange)
    }

    func sourceRange(forReaderRange readerRange: NSRange) -> NSRange? {
        guard let result = renderResult else { return nil }
        if let direct = result.sourceRange(for: readerRange) {
            return direct
        }
        return nearestSourcePosition(toReaderLocation: readerRange.location, in: result)
    }

    func selectSourceRange(
        _ sourceRange: NSRange,
        scrollToVisible: Bool = true
    ) {
        guard let readerRange = readerRange(forSourceRange: sourceRange) else { return }
        let safeRange = clamped(readerRange, to: readerTextView.string.utf16.count)
        readerTextView.setSelectedRange(safeRange)
        if scrollToVisible {
            readerTextView.scrollRangeToVisible(safeRange)
        }
    }

    /// Replaces all comment annotations. Each source range is projected into
    /// one or more visible reader spans, so hidden Markdown punctuation and
    /// generated list markers are not painted as part of a comment selection.
    func setCommentHighlights(_ highlights: [CommentHighlight]) {
        commentHighlights = highlights
        applyCommentHighlights()
    }

    func clearCommentHighlights() {
        commentHighlights.removeAll()
        clearRenderedHighlights()
    }

    private func apply(
        _ result: MarkdownReaderRenderer.Result,
        markdown: String,
        baseURL: URL?,
        preserved: PreservedState?,
        preferredSourceSelection: NSRange?
    ) {
        clearRenderedHighlights()
        readerTextView.textStorage?.setAttributedString(result.attributedString)
        self.markdown = markdown
        self.baseURL = baseURL
        renderResult = result

        sizeDocumentViewToContent()
        applyCommentHighlights()
        if let preferredSourceSelection {
            selectSourceRange(preferredSourceSelection, scrollToVisible: true)
        } else {
            restore(preserved)
        }
    }

    func commentHighlightIDs(atReaderLocation location: Int) -> [String] {
        guard let result = renderResult else { return [] }
        return commentHighlights.compactMap { highlight in
            let renderedRanges = result.renderedRanges(
                intersecting: highlight.sourceRange
            )
            return renderedRanges.contains(where: { NSLocationInRange(location, $0) })
                ? highlight.id
                : nil
        }
    }

    private static func configure(
        _ textView: CenteredReaderTextView,
        in scrollView: NSScrollView,
        theme: MarkdownReaderRenderer.Theme
    ) {
        MarkdownReaderRenderer.prepare(textView, theme: theme)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: 690,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.updateCenteredInset()

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = MarginTheme.documentBackground
        scrollView.contentView.drawsBackground = true
        scrollView.contentView.backgroundColor = MarginTheme.documentBackground
    }

    private func sizeDocumentViewToContent() {
        guard isViewLoaded,
              let layoutManager = readerTextView.layoutManager,
              let textContainer = readerTextView.textContainer else { return }

        let viewport = readerScrollView.contentView.bounds.size
        let width = max(viewport.width, 1)
        if abs(readerTextView.frame.width - width) > 0.5 {
            readerTextView.setFrameSize(
                NSSize(width: width, height: max(readerTextView.frame.height, viewport.height))
            )
        } else {
            readerTextView.updateCenteredInset()
        }

        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        let contentHeight = ceil(
            used.maxY + (readerTextView.textContainerInset.height * 2)
        )
        let height = max(viewport.height, contentHeight, 1)
        if abs(readerTextView.frame.height - height) > 0.5 {
            readerTextView.setFrameSize(NSSize(width: width, height: height))
        }
    }

    private func captureState() -> PreservedState? {
        guard isViewLoaded, let result = renderResult else { return nil }
        let visibleRect = readerTextView.visibleRect
        let maxScroll = max(readerTextView.bounds.height - visibleRect.height, 0)
        let fraction = maxScroll > 0 ? visibleRect.minY / maxScroll : 0

        let readerLocation = readerTextView.characterIndexForInsertion(
            at: NSPoint(
                x: readerTextView.textContainerOrigin.x + 2,
                y: visibleRect.minY + 2
            )
        )
        let sourceAnchor = result.sourceRange(
            for: NSRange(location: readerLocation, length: 0)
        ) ?? nearestSourcePosition(toReaderLocation: readerLocation, in: result)

        let anchorRect = readerRect(atCharacterLocation: readerLocation)
        return PreservedState(
            selectionInSource: sourceRange(
                forReaderRange: readerTextView.selectedRange()
            ),
            scrollAnchorInSource: sourceAnchor,
            scrollAnchorOffset: visibleRect.minY - anchorRect.minY,
            scrollFraction: fraction
        )
    }

    private func restore(_ state: PreservedState?) {
        guard let state, let result = renderResult else {
            readerTextView.setSelectedRange(NSRange(location: 0, length: 0))
            readerTextView.scroll(.zero)
            return
        }

        if let sourceSelection = state.selectionInSource,
           let readerSelection = result.renderedRange(for: sourceSelection) {
            readerTextView.setSelectedRange(
                clamped(readerSelection, to: readerTextView.string.utf16.count)
            )
        }

        if let sourceAnchor = state.scrollAnchorInSource,
           let readerAnchor = result.renderedRange(for: sourceAnchor) {
            let rect = readerRect(atCharacterLocation: readerAnchor.location)
            let targetY = max(rect.minY + state.scrollAnchorOffset, 0)
            readerTextView.scroll(NSPoint(x: 0, y: targetY))
            return
        }

        let visibleHeight = readerTextView.visibleRect.height
        let maxScroll = max(readerTextView.bounds.height - visibleHeight, 0)
        readerTextView.scroll(
            NSPoint(x: 0, y: maxScroll * min(max(state.scrollFraction, 0), 1))
        )
    }

    private func readerRect(atCharacterLocation location: Int) -> NSRect {
        guard
            let layoutManager = readerTextView.layoutManager,
            let textContainer = readerTextView.textContainer,
            readerTextView.string.utf16.count > 0
        else {
            return NSRect(
                x: readerTextView.textContainerOrigin.x,
                y: readerTextView.textContainerOrigin.y,
                width: 0,
                height: theme.bodyFont.pointSize
            )
        }

        let safeLocation = min(max(location, 0), readerTextView.string.utf16.count - 1)
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: safeLocation, length: 1),
            actualCharacterRange: nil
        )
        let rect = layoutManager.boundingRect(
            forGlyphRange: glyphRange,
            in: textContainer
        )
        return rect.offsetBy(
            dx: readerTextView.textContainerOrigin.x,
            dy: readerTextView.textContainerOrigin.y
        )
    }

    private func nearestSourcePosition(
        toReaderLocation location: Int,
        in result: MarkdownReaderRenderer.Result
    ) -> NSRange? {
        guard let nearest = result.sourceMappings.min(by: { lhs, rhs in
            distance(from: location, to: lhs.renderedRange)
                < distance(from: location, to: rhs.renderedRange)
        }) else { return nil }

        let readerLocation = min(
            max(location, nearest.renderedRange.location),
            NSMaxRange(nearest.renderedRange)
        )
        if nearest.renderedRange.length == nearest.sourceRange.length {
            return NSRange(
                location: nearest.sourceRange.location
                    + readerLocation - nearest.renderedRange.location,
                length: 0
            )
        }
        return NSRange(location: nearest.sourceRange.location, length: 0)
    }

    private func applyCommentHighlights() {
        clearRenderedHighlights()
        guard
            let result = renderResult,
            let layoutManager = readerTextView.layoutManager
        else { return }

        for highlight in commentHighlights {
            let ranges = merged(
                result.renderedRanges(intersecting: highlight.sourceRange)
                    .filter { $0.length > 0 }
            )
            let attributes = highlightAttributes(for: highlight.state)
            for range in ranges {
                layoutManager.addTemporaryAttributes(
                    attributes,
                    forCharacterRange: range
                )
                renderedHighlightRanges.append(range)
            }
        }
        readerTextView.needsDisplay = true
    }

    private func clearRenderedHighlights() {
        guard let layoutManager = readerTextView.layoutManager else {
            renderedHighlightRanges.removeAll()
            return
        }
        for range in renderedHighlightRanges {
            layoutManager.removeTemporaryAttribute(
                .backgroundColor,
                forCharacterRange: range
            )
            layoutManager.removeTemporaryAttribute(
                .underlineStyle,
                forCharacterRange: range
            )
            layoutManager.removeTemporaryAttribute(
                .underlineColor,
                forCharacterRange: range
            )
        }
        renderedHighlightRanges.removeAll()
    }

    private func highlightAttributes(
        for state: CommentHighlight.State
    ) -> [NSAttributedString.Key: Any] {
        switch state {
        case .normal:
            return [
                .backgroundColor: NSColor.controlAccentColor.withAlphaComponent(0.075),
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .underlineColor: NSColor.controlAccentColor.withAlphaComponent(0.48),
            ]
        case .active:
            return [
                .backgroundColor: NSColor.controlAccentColor.withAlphaComponent(0.16),
                .underlineStyle: NSUnderlineStyle.thick.rawValue,
                .underlineColor: NSColor.controlAccentColor,
            ]
        case .resolved:
            return [
                .backgroundColor: NSColor.tertiaryLabelColor.withAlphaComponent(0.08),
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .underlineColor: NSColor.tertiaryLabelColor,
            ]
        }
    }

    private func merged(_ ranges: [NSRange]) -> [NSRange] {
        let sorted = ranges.sorted { $0.location < $1.location }
        guard var current = sorted.first else { return [] }
        var result: [NSRange] = []
        for range in sorted.dropFirst() {
            if range.location <= NSMaxRange(current) {
                current = NSUnionRange(current, range)
            } else {
                result.append(current)
                current = range
            }
        }
        result.append(current)
        return result
    }

    private func distance(from location: Int, to range: NSRange) -> Int {
        if location < range.location { return range.location - location }
        if location > NSMaxRange(range) { return location - NSMaxRange(range) }
        return 0
    }

    private func clamped(_ range: NSRange, to length: Int) -> NSRange {
        guard range.location != NSNotFound else {
            return NSRange(location: 0, length: 0)
        }
        let location = min(max(range.location, 0), length)
        return NSRange(
            location: location,
            length: min(max(range.length, 0), length - location)
        )
    }
}
