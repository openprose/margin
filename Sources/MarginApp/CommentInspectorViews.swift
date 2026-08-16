import AppKit

/// A thread is a single keyboard target. Its children remain native controls,
/// but Up/Down traverse review threads and Return selects the current thread.
final class CommentThreadView: NSStackView {
    var onActivate: (() -> Void)?
    var onMovePrevious: (() -> Void)?
    var onMoveNext: (() -> Void)?
    var onMoveFirst: (() -> Void)?
    var onMoveLast: (() -> Void)?

    private let active: Bool

    init(active: Bool, resolved: Bool) {
        self.active = active
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        orientation = .vertical
        alignment = .leading
        spacing = 7
        edgeInsets = NSEdgeInsets(top: 13, left: 8, bottom: 14, right: 8)
        focusRingType = .exterior
        wantsLayer = true
        layer?.cornerRadius = 7
        alphaValue = resolved && !active ? 0.76 : 1
        updateBackground()
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { needsDisplay = true }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { needsDisplay = true }
        return accepted
    }

    override func mouseDown(with event: NSEvent) {
        onActivate?()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 49, 76:
            onActivate?()
        case 126:
            onMovePrevious?()
        case 125:
            onMoveNext?()
        case 115:
            onMoveFirst?()
        case 119:
            onMoveLast?()
        default:
            super.keyDown(with: event)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        onActivate?()
        return true
    }

    override var focusRingMaskBounds: NSRect {
        bounds.insetBy(dx: 1, dy: 1)
    }

    override func drawFocusRingMask() {
        NSBezierPath(
            roundedRect: focusRingMaskBounds,
            xRadius: 7,
            yRadius: 7
        ).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackground()
    }

    private func updateBackground() {
        layer?.backgroundColor = active ? MarginTheme.annotationFill.cgColor : NSColor.clear.cgColor
    }
}

/// One rail owns the complete conversation, including the root. Reply rows add
/// branches to that rail without producing nested cards or duplicated gutters.
final class CommentConversationRailView: NSView {
    private let stack = NSStackView()
    private let railColor: NSColor

    override var isFlipped: Bool { true }

    init(active: Bool, resolved: Bool) {
        railColor = resolved && !active ? MarginTheme.rule : MarginTheme.annotationRail
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func addRoot(_ view: NSView) {
        add(InsetCommentContentView(contentView: view, leading: 16, top: 2, bottom: 7))
    }

    @discardableResult
    func addReply(_ view: NSView, depth: Int, selected: Bool) -> NSView {
        let row = CommentReplyRailRowView(depth: depth, selected: selected, contentView: view)
        add(row)
        return row
    }

    func addDisclosure(_ view: NSView) {
        add(InsetCommentContentView(contentView: view, leading: 16, top: 3, bottom: 5))
    }

    private func add(_ view: NSView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let lineWidth = 1 / scale
        railColor.setStroke()
        let path = NSBezierPath()
        path.lineWidth = lineWidth
        let x = 5 + lineWidth / 2
        path.move(to: NSPoint(x: x, y: 1))
        path.line(to: NSPoint(x: x, y: max(bounds.height - 1, 1)))
        path.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

private final class InsetCommentContentView: NSView {
    init(contentView: NSView, leading: CGFloat, top: CGFloat, bottom: CGFloat) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        contentView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.topAnchor.constraint(equalTo: topAnchor, constant: top),
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leading),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -bottom),
        ])
    }

    required init?(coder: NSCoder) { nil }
}

private final class CommentReplyRailRowView: NSView {
    private let visualDepth: Int
    private let selected: Bool

    override var isFlipped: Bool { true }

    init(depth: Int, selected: Bool, contentView: NSView) {
        visualDepth = min(max(depth, 1), 2)
        self.selected = selected
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 5
        updateBackground()

        contentView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentView)
        let leading = CGFloat(16 + visualDepth * 12)
        NSLayoutConstraint.activate([
            contentView.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leading),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let lineWidth = 1 / scale
        MarginTheme.annotationRail.setStroke()
        let branchY: CGFloat = 17
        let branchStart: CGFloat

        if visualDepth == 2 {
            branchStart = 17 + lineWidth / 2
            let nested = NSBezierPath()
            nested.lineWidth = lineWidth
            nested.move(to: NSPoint(x: branchStart, y: 0))
            nested.line(to: NSPoint(x: branchStart, y: bounds.height))
            nested.stroke()
        } else {
            branchStart = 5 + lineWidth / 2
        }

        let branch = NSBezierPath()
        branch.lineWidth = lineWidth
        branch.move(to: NSPoint(x: branchStart, y: branchY))
        branch.line(to: NSPoint(x: CGFloat(10 + visualDepth * 12), y: branchY))
        branch.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackground()
        needsDisplay = true
    }

    private func updateBackground() {
        layer?.backgroundColor = selected
            ? NSColor.controlAccentColor.withAlphaComponent(0.07).cgColor
            : NSColor.clear.cgColor
    }
}
