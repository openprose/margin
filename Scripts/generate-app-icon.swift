import AppKit
import Foundation

private struct IconVariant {
    let filename: String
    let pixels: Int
}

private let variants = [
    IconVariant(filename: "icon_16x16.png", pixels: 16),
    IconVariant(filename: "icon_16x16@2x.png", pixels: 32),
    IconVariant(filename: "icon_32x32.png", pixels: 32),
    IconVariant(filename: "icon_32x32@2x.png", pixels: 64),
    IconVariant(filename: "icon_128x128.png", pixels: 128),
    IconVariant(filename: "icon_128x128@2x.png", pixels: 256),
    IconVariant(filename: "icon_256x256.png", pixels: 256),
    IconVariant(filename: "icon_256x256@2x.png", pixels: 512),
    IconVariant(filename: "icon_512x512.png", pixels: 512),
    IconVariant(filename: "icon_512x512@2x.png", pixels: 1024),
]

private func drawIcon(pixels: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw CocoaError(.fileWriteUnknown)
    }

    let size = CGFloat(pixels)
    let canvas = NSRect(x: 0, y: 0, width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.shouldAntialias = true
    NSColor.clear.setFill()
    canvas.fill()

    let paperRect = canvas.insetBy(dx: size * 0.065, dy: size * 0.065)
    let paper = NSBezierPath(roundedRect: paperRect, xRadius: size * 0.19, yRadius: size * 0.19)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(calibratedWhite: 0.05, alpha: 0.22)
    shadow.shadowBlurRadius = size * 0.045
    shadow.shadowOffset = NSSize(width: 0, height: -size * 0.018)
    shadow.set()
    NSColor(calibratedRed: 0.95, green: 0.93, blue: 0.88, alpha: 1).setFill()
    paper.fill()
    NSGraphicsContext.restoreGraphicsState()

    let gradient = NSGradient(
        starting: NSColor(calibratedRed: 0.985, green: 0.975, blue: 0.945, alpha: 1),
        ending: NSColor(calibratedRed: 0.90, green: 0.87, blue: 0.80, alpha: 1)
    )
    gradient?.draw(in: paper, angle: -90)

    NSColor(calibratedWhite: 0.20, alpha: 0.14).setStroke()
    paper.lineWidth = max(0.6, size * 0.006)
    paper.stroke()

    let rule = NSBezierPath()
    rule.move(to: NSPoint(x: size * 0.30, y: size * 0.22))
    rule.line(to: NSPoint(x: size * 0.30, y: size * 0.78))
    rule.lineWidth = max(1, size * 0.014)
    rule.lineCapStyle = .round
    NSColor(calibratedRed: 0.36, green: 0.33, blue: 0.29, alpha: 0.58).setStroke()
    rule.stroke()

    let mark = NSBezierPath()
    mark.move(to: NSPoint(x: size * 0.40, y: size * 0.32))
    mark.line(to: NSPoint(x: size * 0.40, y: size * 0.68))
    mark.line(to: NSPoint(x: size * 0.525, y: size * 0.51))
    mark.line(to: NSPoint(x: size * 0.65, y: size * 0.68))
    mark.line(to: NSPoint(x: size * 0.65, y: size * 0.32))
    mark.lineWidth = max(1.2, size * 0.043)
    mark.lineCapStyle = .round
    mark.lineJoinStyle = .round
    NSColor(calibratedRed: 0.22, green: 0.20, blue: 0.18, alpha: 0.94).setStroke()
    mark.stroke()

    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    return data
}

guard CommandLine.arguments.count == 2 else {
    fputs("usage: generate-app-icon OUTPUT.iconset\n", stderr)
    exit(64)
}

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
do {
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    for variant in variants {
        let data = try drawIcon(pixels: variant.pixels)
        try data.write(to: outputDirectory.appendingPathComponent(variant.filename), options: .atomic)
    }
} catch {
    fputs("generate-app-icon: \(error.localizedDescription)\n", stderr)
    exit(1)
}
