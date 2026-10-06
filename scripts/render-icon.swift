#!/usr/bin/env swift
// Renders the app icon (the "Control Tower" mark from the design canvas) to an .icns.
//
//   swift scripts/render-icon.swift Resources/AppIcon.icns
//
// Drawn in the canvas's 64-unit space, inside macOS's 824/1024 icon grid.
import AppKit

let output = CommandLine.arguments.dropFirst().first ?? "Resources/AppIcon.icns"

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: alpha
    )
}

/// Points along an SVG-style arc from `start` to `end` (radius r), bulging upward.
func arcPoints(from start: CGPoint, to end: CGPoint, radius r: CGFloat) -> [CGPoint] {
    let half = (end.x - start.x) / 2
    let center = CGPoint(x: start.x + half, y: start.y + (r * r - half * half).squareRoot())
    let a0 = atan2(start.y - center.y, start.x - center.x)
    let a1 = atan2(end.y - center.y, end.x - center.x)
    return (0...48).map { step in
        let t = a0 + (a1 - a0) * CGFloat(step) / 48
        return CGPoint(x: center.x + r * cos(t), y: center.y + r * sin(t))
    }
}

func render(size: Int) -> CGImage {
    let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    let s = CGFloat(size) / 1024
    // Work top-down like the SVG on the canvas.
    context.translateBy(x: 0, y: CGFloat(size))
    context.scaleBy(x: s, y: -s)

    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x000000, 0.35))
    context.addPath(squircle)
    context.setFillColor(color(0x1A1A1A))
    context.fillPath()
    context.restoreGState()
    context.addPath(squircle)
    context.setStrokeColor(color(0xFFFFFF, 0.08))
    context.setLineWidth(3)
    context.strokePath()

    // 64-unit design space mapped onto the tile.
    let unit = tile.width / 64
    context.translateBy(x: tile.minX, y: tile.minY)
    context.scaleBy(x: unit, y: unit)
    context.setLineCap(.round)
    context.setLineJoin(.round)

    let arcs: [(CGFloat, CGFloat, CGFloat, UInt32)] = [(14, 50, 24, 0x4D4D4D), (20, 44, 17, 0x8C8C8C), (26, 38, 9, 0xFF450F)]
    for (startX, endX, radius, hex) in arcs {
        let points = arcPoints(from: CGPoint(x: startX, y: 46), to: CGPoint(x: endX, y: 46), radius: radius)
        context.addLines(between: points)
        context.setStrokeColor(color(hex))
        context.setLineWidth(hex == 0xFF450F ? 3.5 : 3)
        context.strokePath()
    }

    let window = CGRect(x: 22, y: 20, width: 20, height: 14)
    context.addPath(CGPath(roundedRect: window, cornerWidth: 2.5, cornerHeight: 2.5, transform: nil))
    context.setStrokeColor(color(0xF4F4F4))
    context.setLineWidth(2.5)
    context.strokePath()
    context.move(to: CGPoint(x: 22, y: 24.5))
    context.addLine(to: CGPoint(x: 42, y: 24.5))
    context.setLineWidth(2)
    context.strokePath()

    return context.makeImage()!
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon-\(getpid()).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for (name, pixels) in [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
] {
    let rep = NSBitmapImageRep(cgImage: render(size: pixels))
    try rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent("\(name).png"))
}
try FileManager.default.createDirectory(
    at: URL(fileURLWithPath: output).deletingLastPathComponent(), withIntermediateDirectories: true
)
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(iconutil.terminationStatus == 0 ? "Wrote \(output)" : "iconutil failed")
