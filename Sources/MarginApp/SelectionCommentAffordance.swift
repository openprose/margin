import AppKit

/// Lazily reveals a native comment action in the trailing text margin after a
/// range selection settles. No control or observer exists for caret-only use.
final class SelectionCommentAffordance {
    static let settleDelay: TimeInterval = 0.18
    static let buttonSize = NSSize(width: 28, height: 28)

    private weak var hostView: NSView?
    private weak var textView: NSTextView?
    private let action: () -> Void
    private var pendingShow: DispatchWorkItem?
    private var boundsObserver: NSObjectProtocol?
    private var button: SelectionCommentBubbleButton?

    var isVisible: Bool { button?.isHidden == false }
    var buttonForTesting: NSButton? { button }

    init(hostView: NSView, action: @escaping () -> Void) {
        self.hostView = hostView
        self.action = action
    }

    deinit {
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
    }

    func selectionDidChange(in textView: NSTextView) {
        pendingShow?.cancel()
        let selection = textView.selectedRange()
        guard selection.location != NSNotFound, selection.length > 0 else {
            hide()
            return
        }

        button?.isHidden = true
        self.textView = textView
        let expectedRange = selection
        let work = DispatchWorkItem { [weak self, weak textView] in
            guard let self, let textView,
                  textView.selectedRange() == expectedRange,
                  textView.window?.firstResponder === textView else { return }
            self.show(in: textView)
        }
        pendingShow = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay, execute: work)
    }

    func hide() {
        pendingShow?.cancel()
        pendingShow = nil
        button?.isHidden = true
        stopObservingBounds()
    }

    func reset() {
        hide()
        textView = nil
        button?.removeFromSuperview()
        button = nil
    }

    func updatePosition() {
        guard let hostView, let textView, let button, !button.isHidden,
              let frame = Self.buttonFrame(
                  for: textView.selectedRange(),
                  in: textView,
                  hostView: hostView
              ) else {
            button?.isHidden = true
            return
        }
        button.frame = frame
    }

    /// Test seam for deterministic geometry/accessibility assertions.
    func showImmediatelyForTesting(in textView: NSTextView) {
        self.textView = textView
        show(in: textView)
    }

    static func buttonFrame(
        for selection: NSRange,
        in textView: NSTextView,
        hostView: NSView
    ) -> NSRect? {
        guard selection.location != NSNotFound, selection.length > 0,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return nil }

        let textLength = textView.string.utf16.count
        let lastCharacter = min(NSMaxRange(selection), textLength) - 1
        guard lastCharacter >= 0 else { return nil }
        layoutManager.ensureLayout(for: textContainer)
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: lastCharacter, length: 1),
            actualCharacterRange: nil
        )
        guard glyphRange.length > 0 else { return nil }
        var lineRect = layoutManager.lineFragmentUsedRect(
            forGlyphAt: glyphRange.location,
            effectiveRange: nil
        )
        lineRect = lineRect.offsetBy(
            dx: textView.textContainerOrigin.x,
            dy: textView.textContainerOrigin.y
        )
        let lineInHost = hostView.convert(lineRect, from: textView)
        guard lineInHost.intersects(hostView.bounds.insetBy(dx: 0, dy: -Self.buttonSize.height)) else {
            return nil
        }

        let textTrailingPoint = hostView.convert(
            NSPoint(
                x: textView.bounds.maxX - textView.textContainerInset.width,
                y: lineRect.midY
            ),
            from: textView
        )
        let maximumX = hostView.bounds.maxX - Self.buttonSize.width - 8
        let x = min(maximumX, textTrailingPoint.x + 9)
        let proposedY = lineInHost.midY - (Self.buttonSize.height / 2)
        let y = min(
            max(hostView.bounds.minY + 6, proposedY),
            hostView.bounds.maxY - Self.buttonSize.height - 6
        )
        guard x >= hostView.bounds.minX + 6 else { return nil }
        return NSRect(origin: NSPoint(x: floor(x), y: floor(y)), size: Self.buttonSize)
    }

    private func show(in textView: NSTextView) {
        guard let hostView,
              textView.selectedRange().length > 0,
              let frame = Self.buttonFrame(
                  for: textView.selectedRange(),
                  in: textView,
                  hostView: hostView
              ) else {
            hide()
            return
        }
        let button = ensureButton(in: hostView)
        button.frame = frame
        button.isHidden = false
        startObservingBounds(of: textView)
        NSAccessibility.post(element: button, notification: .layoutChanged)
    }

    private func ensureButton(in hostView: NSView) -> SelectionCommentBubbleButton {
        if let button { return button }
        let button = SelectionCommentBubbleButton(frame: .zero)
        button.target = self
        button.action = #selector(invoke(_:))
        hostView.addSubview(button, positioned: .above, relativeTo: nil)
        self.button = button
        return button
    }

    private func startObservingBounds(of textView: NSTextView) {
        stopObservingBounds()
        guard let clipView = textView.enclosingScrollView?.contentView else { return }
        clipView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clipView,
            queue: .main
        ) { [weak self] _ in
            self?.updatePosition()
        }
    }

    private func stopObservingBounds() {
        guard let boundsObserver else { return }
        NotificationCenter.default.removeObserver(boundsObserver)
        self.boundsObserver = nil
    }

    @objc private func invoke(_ sender: Any?) {
        hide()
        action()
    }
}

private final class SelectionCommentBubbleButton: NSButton {
    private var trackingAreaReference: NSTrackingArea?
    private var isHovered = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = ""
        image = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: nil)
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        contentTintColor = .secondaryLabelColor
        isBordered = false
        setButtonType(.momentaryChange)
        focusRingType = .exterior
        toolTip = "Comment on selection"
        setAccessibilityLabel("Comment on selection")
        setAccessibilityHelp("Opens the comment composer for the selected text")
    }

    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        if let trackingAreaReference { removeTrackingArea(trackingAreaReference) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaReference = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let fill = isHighlighted || isHovered
            ? NSColor.controlAccentColor.withAlphaComponent(0.13)
            : NSColor.controlBackgroundColor.withAlphaComponent(0.92)
        fill.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).fill()
        MarginTheme.rule.setStroke()
        let outline = NSBezierPath(ovalIn: bounds.insetBy(dx: 1.5, dy: 1.5))
        outline.lineWidth = 1
        outline.stroke()
        super.draw(dirtyRect)
    }
}
