#!/usr/bin/env swift
// Renders Otto's app icon from Resources/branding/otto/otto-icon.svg to an .icns, on the macOS icon grid:
//   swift scripts/render-icon.swift [Resources/AppIcon.icns]
import AppKit

let output = CommandLine.arguments.dropFirst().first ?? "Resources/AppIcon.icns"
let source = URL(fileURLWithPath: "Resources/branding/otto/otto-icon.svg")
guard let artwork = NSImage(contentsOf: source) else {
    FileHandle.standardError.write(Data("Couldn't read \(source.path)\n".utf8))
    exit(1)
}

func render(size: Int) -> CGImage {
    let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    let scale = CGFloat(size) / 1024
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let unit = tile.width / 60
    let canvas = CGRect(x: tile.minX - 2 * unit, y: tile.minY - 2 * unit, width: 64 * unit, height: 64 * unit)
    context.scaleBy(x: scale, y: scale)
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: CGColor(gray: 0, alpha: 0.35))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    artwork.draw(in: canvas, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
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
