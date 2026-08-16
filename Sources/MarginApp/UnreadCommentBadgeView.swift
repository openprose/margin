import AppKit

/// Created only when an external collaborator adds comments to a background
/// or inspector-hidden document. Keeping it out of the ordinary tab path
/// preserves Margin's single-document launch profile.
final class UnreadCommentBadgeView: NSView {
    private let label = NSTextField(labelWithString: "")
    private var widthConstraint: NSLayoutConstraint!

    var count: Int = 0 {
        didSet { updatePresentation() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor.controlAccentColor.cgColor

        label.font = .monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
        label.textColor = .selectedMenuItemTextColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setAccessibilityElement(false)
        addSubview(label)

        widthConstraint = widthAnchor.constraint(equalToConstant: 16)
        NSLayoutConstraint.activate([
            widthConstraint,
            heightAnchor.constraint(equalToConstant: 16),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -0.5),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 3),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -3),
        ])
        setAccessibilityRole(.staticText)
        updatePresentation()
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = NSColor.controlAccentColor.cgColor
    }

    private func updatePresentation() {
        let display = min(max(count, 0), 99)
        label.stringValue = display >= 99 ? "99+" : String(display)
        widthConstraint.constant = display >= 10 ? (display >= 99 ? 28 : 22) : 16
        setAccessibilityLabel("New comments: \(count)")
        isHidden = count <= 0
    }
}
