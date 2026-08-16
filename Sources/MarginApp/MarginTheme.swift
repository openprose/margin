import AppKit

/// Margin's small visual vocabulary. The values are intentionally expressed as
/// adaptive AppKit colors so the application keeps native appearance, contrast,
/// and accent behavior without paying for a parallel theme engine.
enum MarginTheme {
    // These surfaces are sRGB encodings of low-chroma OKLCH neutrals: a warm
    // proofing sheet for the document and a slightly cooler technical surround.
    static let documentBackground = adaptive(
        light: srgb(0.973, 0.969, 0.948),
        dark: srgb(0.090, 0.098, 0.105)
    )
    static let inspectorBackground = adaptive(
        light: srgb(0.950, 0.955, 0.951),
        dark: srgb(0.071, 0.080, 0.086)
    )
    static let paletteBackground = adaptive(
        light: srgb(0.965, 0.967, 0.960),
        dark: srgb(0.084, 0.093, 0.099)
    )
    static let codeBackground = adaptive(
        light: srgb(0.923, 0.927, 0.912),
        dark: srgb(0.136, 0.151, 0.160)
    )
    static let syntax = adaptive(
        light: srgb(0.390, 0.425, 0.440),
        dark: srgb(0.585, 0.625, 0.645)
    )
    static let activeSyntax = adaptive(
        light: srgb(0.235, 0.270, 0.286),
        dark: srgb(0.730, 0.765, 0.780)
    )
    static let secondaryInk = adaptive(
        light: srgb(0.330, 0.350, 0.350),
        dark: srgb(0.680, 0.700, 0.700)
    )
    static let rule = adaptive(
        light: srgb(0.790, 0.800, 0.785).withAlphaComponent(0.72),
        dark: srgb(0.250, 0.275, 0.285).withAlphaComponent(0.78)
    )

    static var annotationFill: NSColor {
        NSColor.controlAccentColor.withAlphaComponent(0.085)
    }

    static var annotationRail: NSColor {
        NSColor.controlAccentColor.withAlphaComponent(0.42)
    }

    static func sourceBodyFont(size: CGFloat = 15.5) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: .regular)
    }

    static func sourceHeadingFont(level: Int, baseSize: CGFloat = 15.5) -> NSFont {
        let sizes: [CGFloat] = [22, 19, 17.25, 16.25, 15.75, 15.5]
        let size = sizes[min(max(level - 1, 0), sizes.count - 1)] * (baseSize / 15.5)
        let weight: NSFont.Weight = level <= 2 ? .bold : (level == 3 ? .semibold : .medium)
        return serifFont(ofSize: size, weight: weight)
    }

    static func serifFont(ofSize size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let fallback = NSFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = fallback.fontDescriptor.withDesign(.serif),
              let font = NSFont(descriptor: descriptor, size: size) else { return fallback }
        return font
    }

    static func sourceParagraphStyle() -> NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 5.5
        paragraph.paragraphSpacing = 3
        paragraph.lineBreakMode = .byWordWrapping
        return paragraph
    }

    static func sourceHeadingParagraphStyle(level: Int) -> NSParagraphStyle {
        let paragraph = sourceParagraphStyle().mutableCopy() as! NSMutableParagraphStyle
        switch level {
        case 1:
            paragraph.paragraphSpacingBefore = 17
            paragraph.paragraphSpacing = 8
        case 2:
            paragraph.paragraphSpacingBefore = 14
            paragraph.paragraphSpacing = 7
        case 3:
            paragraph.paragraphSpacingBefore = 11
            paragraph.paragraphSpacing = 5
        default:
            paragraph.paragraphSpacingBefore = 8
            paragraph.paragraphSpacing = 4
        }
        return paragraph
    }

    static func microLabel(_ text: String) -> NSAttributedString {
        NSAttributedString(
            string: text.uppercased(),
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 9.5, weight: .medium),
                .foregroundColor: NSColor.tertiaryLabelColor,
                .kern: 0.75,
            ]
        )
    }

    private static func srgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }

    private static func adaptive(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [
                .accessibilityHighContrastDarkAqua,
                .darkAqua,
                .accessibilityHighContrastAqua,
                .aqua,
            ])
            return match == .darkAqua || match == .accessibilityHighContrastDarkAqua
                ? dark
                : light
        }
    }
}

/// A dynamic-color surface that redraws correctly when macOS appearance changes.
final class MarginSurfaceView: NSView {
    var fillColor: NSColor {
        didSet { needsDisplay = true }
    }

    init(fillColor: NSColor) {
        self.fillColor = fillColor
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fillColor = MarginTheme.documentBackground
        super.init(coder: coder)
    }

    override func draw(_ dirtyRect: NSRect) {
        fillColor.setFill()
        dirtyRect.fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// One physical-pixel rule, used where structure needs a precise edge.
final class MarginHairlineView: NSView {
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 1) }

    override func draw(_ dirtyRect: NSRect) {
        MarginTheme.rule.setFill()
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        NSRect(x: 0, y: 0, width: bounds.width, height: 1 / scale).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
