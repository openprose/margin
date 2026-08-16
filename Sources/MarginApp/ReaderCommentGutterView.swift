import AppKit

struct ReaderCommentMarkerCandidate: Equatable {
    var id: String
    var summary: String
    var minY: CGFloat
    var maxY: CGFloat
    var isActive: Bool
    var isResolved: Bool
}

struct ReaderCommentMarkerGroup: Equatable {
    var ids: [String]
    var summaries: [String]
    var frame: NSRect
    var activeID: String?
    var isResolvedOnly: Bool
}

enum ReaderCommentMarkerLayout {
    static func groups(
        from candidates: [ReaderCommentMarkerCandidate],
        x: CGFloat,
        width: CGFloat = 30,
        minimumHeight: CGFloat = 16,
        mergeTolerance: CGFloat = 4
    ) -> [ReaderCommentMarkerGroup] {
        let sorted = candidates.sorted {
            if $0.minY != $1.minY { return $0.minY < $1.minY }
            if $0.maxY != $1.maxY { return $0.maxY < $1.maxY }
            return $0.id < $1.id
        }
        guard let first = sorted.first else { return [] }

        var result: [ReaderCommentMarkerGroup] = []
        var current = [first]
        var currentMaximumY = first.maxY

        func makeGroup(_ values: [ReaderCommentMarkerCandidate]) -> ReaderCommentMarkerGroup {
            var seen = Set<String>()
            let unique = values.filter { seen.insert($0.id).inserted }
            let minY = unique.map(\.minY).min() ?? 0
            let maxY = unique.map(\.maxY).max() ?? minY
            let height = max(minimumHeight, maxY - minY)
            let adjustedY = minY - max(0, minimumHeight - (maxY - minY)) / 2
            return ReaderCommentMarkerGroup(
                ids: unique.map(\.id),
                summaries: unique.map(\.summary),
                frame: NSRect(x: x, y: adjustedY, width: width, height: height),
                activeID: unique.first(where: \.isActive)?.id,
                isResolvedOnly: unique.allSatisfy(\.isResolved)
            )
        }

        for candidate in sorted.dropFirst() {
            if candidate.minY <= currentMaximumY + mergeTolerance {
                current.append(candidate)
                currentMaximumY = max(currentMaximumY, candidate.maxY)
            } else {
                result.append(makeGroup(current))
                current = [candidate]
                currentMaximumY = candidate.maxY
            }
        }
        result.append(makeGroup(current))
        return result
    }
}

/// Transparent reader overlay whose only hit targets are restrained markers in
/// the outer measure. It never changes the text container width.
final class ReaderCommentGutterView: NSView {
    var onSelectComment: ((String) -> Void)?
    private(set) var markerButtons: [ReaderCommentMarkerButton] = []

    override var isFlipped: Bool { true }

    func update(groups: [ReaderCommentMarkerGroup]) {
        markerButtons.forEach { $0.removeFromSuperview() }
        markerButtons = groups.map { group in
            let button = ReaderCommentMarkerButton(group: group) { [weak self] id in
                self?.onSelectComment?(id)
            }
            button.frame = group.frame
            addSubview(button)
            return button
        }
        setAccessibilityChildren(markerButtons)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

final class ReaderCommentMarkerButton: NSButton {
    let group: ReaderCommentMarkerGroup
    private let handler: (String) -> Void
    private var trackingAreaReference: NSTrackingArea?
    private var isHovered = false

    init(group: ReaderCommentMarkerGroup, handler: @escaping (String) -> Void) {
        self.group = group
        self.handler = handler
        super.init(frame: group.frame)
        title = ""
        isBordered = false
        setButtonType(.momentaryChange)
        target = self
        action = #selector(invoke(_:))
        focusRingType = .exterior

        if group.ids.count == 1 {
            let summary = group.summaries.first ?? "Comment thread"
            toolTip = summary
            setAccessibilityLabel(summary)
        } else {
            let title = "\(group.ids.count) overlapping comment threads"
            toolTip = ([title] + group.summaries).joined(separator: "\n")
            setAccessibilityLabel(title)
            setAccessibilityValue(group.summaries.joined(separator: "; "))
        }
        setAccessibilityHelp(
            group.ids.count > 1
                ? "Selects the next overlapping comment thread"
                : "Selects and opens this comment thread"
        )
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
        let active = group.activeID != nil
        let color: NSColor
        if active || isHovered || isHighlighted {
            color = .controlAccentColor
        } else if group.isResolvedOnly {
            color = .tertiaryLabelColor
        } else {
            color = NSColor.controlAccentColor.withAlphaComponent(0.58)
        }

        let railWidth: CGFloat = active ? 3 : 2
        let railRect = NSRect(
            x: 3,
            y: 1,
            width: railWidth,
            height: max(2, bounds.height - 2)
        )
        color.setFill()
        NSBezierPath(
            roundedRect: railRect,
            xRadius: railWidth / 2,
            yRadius: railWidth / 2
        ).fill()

        if group.ids.count > 1 {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold),
                .foregroundColor: color,
            ]
            let count = NSString(string: String(group.ids.count))
            let size = count.size(withAttributes: attributes)
            count.draw(
                at: NSPoint(x: 9, y: floor((bounds.height - size.height) / 2)),
                withAttributes: attributes
            )
        }
    }

    @objc private func invoke(_ sender: Any?) {
        guard !group.ids.isEmpty else { return }
        let nextID: String
        if let activeID = group.activeID,
           let activeIndex = group.ids.firstIndex(of: activeID),
           group.ids.count > 1 {
            nextID = group.ids[(activeIndex + 1) % group.ids.count]
        } else {
            nextID = group.ids[0]
        }
        handler(nextID)
    }
}
