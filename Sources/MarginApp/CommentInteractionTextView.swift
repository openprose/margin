import AppKit

/// Shared native selection and highlight behavior for source and reader text.
/// It owns no comment model and creates no views; callers opt in with closures.
class CommentInteractionTextView: NSTextView {
    static let commentAction = NSSelectorFromString("beginComment:")
    static let commentMenuIdentifier = NSUserInterfaceItemIdentifier("MarginCommentOnSelection")

    var onCommentOnSelection: ((NSRange) -> Void)?
    var onCommentHighlightClick: ((Int) -> Bool)?

    private var contextCommentSelection: NSRange?
    private var commentMouseDownPoint: NSPoint?
    private var commentMouseDownClickCount = 0

    override func menu(for event: NSEvent) -> NSMenu? {
        menuByAddingCommentAction(to: super.menu(for: event))
    }

    /// Kept internal so the native context-menu contract can be tested without
    /// synthesizing a WindowServer event.
    func menuByAddingCommentAction(to baseMenu: NSMenu?) -> NSMenu? {
        let selection = selectedRange()
        guard selection.location != NSNotFound, selection.length > 0 else {
            contextCommentSelection = nil
            return baseMenu
        }

        contextCommentSelection = selection
        let menu = baseMenu ?? NSMenu()
        guard !menu.items.contains(where: { $0.identifier == Self.commentMenuIdentifier }) else {
            return menu
        }
        if !menu.items.isEmpty, !menu.items.last!.isSeparatorItem {
            menu.addItem(.separator())
        }
        let item = NSMenuItem(
            title: "Comment on Selection",
            action: #selector(commentOnSelectionFromMenu(_:)),
            keyEquivalent: ""
        )
        item.identifier = Self.commentMenuIdentifier
        item.target = self
        item.image = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: nil)
        menu.addItem(item)
        return menu
    }

    @discardableResult
    func performCommentOnSelection() -> Bool {
        let source = contextCommentSelection ?? selectedRange()
        let limit = string.utf16.count
        guard source.location != NSNotFound, source.length > 0, source.location < limit else {
            return false
        }
        let range = NSRange(
            location: max(0, source.location),
            length: min(source.length, limit - max(0, source.location))
        )
        guard range.length > 0 else { return false }
        setSelectedRange(range)
        if let onCommentOnSelection {
            onCommentOnSelection(range)
            return true
        }
        return NSApp.sendAction(Self.commentAction, to: nil, from: self)
    }

    @discardableResult
    func activateCommentHighlight(at characterLocation: Int) -> Bool {
        onCommentHighlightClick?(characterLocation) ?? false
    }

    override func mouseDown(with event: NSEvent) {
        commentMouseDownPoint = convert(event.locationInWindow, from: nil)
        commentMouseDownClickCount = event.clickCount
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        let down = commentMouseDownPoint
        let clickCount = commentMouseDownClickCount
        commentMouseDownPoint = nil
        commentMouseDownClickCount = 0
        super.mouseUp(with: event)

        guard clickCount == 1, selectedRange().length == 0, let down else { return }
        let up = convert(event.locationInWindow, from: nil)
        guard hypot(up.x - down.x, up.y - down.y) <= 3 else { return }
        let location = characterIndexForInsertion(at: up)
        _ = activateCommentHighlight(at: location)
    }

    @objc private func commentOnSelectionFromMenu(_ sender: Any?) {
        _ = performCommentOnSelection()
    }
}
