import AppKit
import Foundation

struct IconSize {
    let filename: String
    let pixels: CGFloat
}

let sizes: [IconSize] = [
    IconSize(filename: "icon_16x16.png", pixels: 16),
    IconSize(filename: "icon_16x16@2x.png", pixels: 32),
    IconSize(filename: "icon_32x32.png", pixels: 32),
    IconSize(filename: "icon_32x32@2x.png", pixels: 64),
    IconSize(filename: "icon_128x128.png", pixels: 128),
    IconSize(filename: "icon_128x128@2x.png", pixels: 256),
    IconSize(filename: "icon_256x256.png", pixels: 256),
    IconSize(filename: "icon_256x256@2x.png", pixels: 512),
    IconSize(filename: "icon_512x512.png", pixels: 512),
    IconSize(filename: "icon_512x512@2x.png", pixels: 1024)
]

let outputDirectory = URL(fileURLWithPath: "Assets.xcassets/AppIcon.appiconset", isDirectory: true)

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(size),
        pixelsHigh: Int(size),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        fatalError("Unable to create bitmap")
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    let scale = size / 1024
    let context = NSGraphicsContext.current!.cgContext
    context.interpolationQuality = .high
    context.setShouldAntialias(true)

    let background = NSBezierPath(roundedRect: rect.insetBy(dx: 48 * scale, dy: 48 * scale), xRadius: 220 * scale, yRadius: 220 * scale)
    let backgroundGradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.06, green: 0.18, blue: 0.29, alpha: 1.0),
        NSColor(calibratedRed: 0.03, green: 0.43, blue: 0.49, alpha: 1.0),
        NSColor(calibratedRed: 0.91, green: 0.64, blue: 0.24, alpha: 1.0)
    ])!
    backgroundGradient.draw(in: background, angle: 42)

    NSColor(calibratedWhite: 1, alpha: 0.18).setStroke()
    background.lineWidth = max(1, 5 * scale)
    background.stroke()

    let bubbleRect = CGRect(x: 202 * scale, y: 250 * scale, width: 620 * scale, height: 470 * scale)
    let bubble = NSBezierPath(roundedRect: bubbleRect, xRadius: 120 * scale, yRadius: 120 * scale)
    bubble.appendArc(withCenter: CGPoint(x: 706 * scale, y: 242 * scale), radius: 116 * scale, startAngle: 120, endAngle: 218, clockwise: false)
    bubble.line(to: CGPoint(x: 642 * scale, y: 292 * scale))
    bubble.close()

    NSColor(calibratedWhite: 1, alpha: 0.94).setFill()
    bubble.fill()

    NSColor(calibratedRed: 0.02, green: 0.12, blue: 0.18, alpha: 0.12).setStroke()
    bubble.lineWidth = max(1, 4 * scale)
    bubble.stroke()

    let routePath = NSBezierPath()
    routePath.move(to: CGPoint(x: 330 * scale, y: 464 * scale))
    routePath.curve(to: CGPoint(x: 536 * scale, y: 536 * scale), controlPoint1: CGPoint(x: 396 * scale, y: 606 * scale), controlPoint2: CGPoint(x: 474 * scale, y: 334 * scale))
    routePath.curve(to: CGPoint(x: 706 * scale, y: 496 * scale), controlPoint1: CGPoint(x: 586 * scale, y: 696 * scale), controlPoint2: CGPoint(x: 638 * scale, y: 450 * scale))
    NSColor(calibratedRed: 0.04, green: 0.28, blue: 0.37, alpha: 1.0).setStroke()
    routePath.lineCapStyle = .round
    routePath.lineJoinStyle = .round
    routePath.lineWidth = max(2, 56 * scale)
    routePath.stroke()

    let arrow = NSBezierPath()
    arrow.move(to: CGPoint(x: 704 * scale, y: 496 * scale))
    arrow.line(to: CGPoint(x: 614 * scale, y: 542 * scale))
    arrow.line(to: CGPoint(x: 640 * scale, y: 434 * scale))
    arrow.close()
    NSColor(calibratedRed: 0.04, green: 0.28, blue: 0.37, alpha: 1.0).setFill()
    arrow.fill()

    let dotColor = NSColor(calibratedRed: 0.91, green: 0.55, blue: 0.16, alpha: 1.0)
    for point in [
        CGPoint(x: 322 * scale, y: 464 * scale),
        CGPoint(x: 528 * scale, y: 536 * scale)
    ] {
        let dotRect = CGRect(x: point.x - 38 * scale, y: point.y - 38 * scale, width: 76 * scale, height: 76 * scale)
        dotColor.setFill()
        NSBezierPath(ovalIn: dotRect).fill()
        NSColor.white.withAlphaComponent(0.9).setStroke()
        let dotStroke = NSBezierPath(ovalIn: dotRect.insetBy(dx: 7 * scale, dy: 7 * scale))
        dotStroke.lineWidth = max(1, 8 * scale)
        dotStroke.stroke()
    }

    NSGraphicsContext.restoreGraphicsState()
    return bitmap
}

for iconSize in sizes {
    let bitmap = drawIcon(size: iconSize.pixels)
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Unable to render \(iconSize.filename)")
    }

    let outputURL = outputDirectory.appendingPathComponent(iconSize.filename)
    try png.write(to: outputURL)
}

print("Generated \(sizes.count) app icon files in \(outputDirectory.path)")
