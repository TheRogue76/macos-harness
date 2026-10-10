import CoreGraphics
import Foundation
import ScreenCaptureKit

/// The corner radius of another app's window, measured from a capture of its top-left corner.
public enum WindowCorners {
    /// The radius used until a window has been measured.
    public static let fallback: CGFloat = 16
    /// How much of the corner is captured, in points.
    static let sample: CGFloat = 48

    /// Measures a window's corner radius in points; nil when it can't be captured or has square
    /// corners.
    public static func measure(windowID: UInt32) async -> CGFloat? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let window = content.windows.first(where: { $0.windowID == windowID }) else { return nil }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)
        let side = min(sample, filter.contentRect.width, filter.contentRect.height)
        guard side >= 8 else { return nil }
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = CGRect(x: 0, y: 0, width: side, height: side)
        configuration.width = Int(side * scale)
        configuration.height = Int(side * scale)
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) else {
            return nil
        }
        return radius(of: image, scale: scale)
    }

    /// The corner radius, in points, of the transparent top-left corner of a window image.
    public static func radius(of image: CGImage, scale: CGFloat) -> CGFloat? {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn, let pixelRadius = radius(width: width, height: height, alpha: { x, y in pixels[(y * width + x) * 4 + 3] }) else {
            return nil
        }
        return pixelRadius / max(scale, 1)
    }

    /// The radius, in pixels, of the circle that best fits a transparent top-left corner, given each
    /// pixel's alpha (row 0 at the top).
    public static func radius(width: Int, height: Int, alpha: (Int, Int) -> UInt8) -> CGFloat? {
        var estimates: [CGFloat] = []
        for y in 0..<height {
            guard let x = (0..<width).first(where: { alpha($0, y) >= 128 }) else { continue }
            let edge: CGFloat
            if x == 0 {
                edge = 0
            } else {
                let before = CGFloat(alpha(x - 1, y))
                let after = CGFloat(alpha(x, y))
                edge = CGFloat(x - 1) + 0.5 + (after > before ? (128 - before) / (after - before) : 0.5)
            }
            if edge <= 1 { break }
            let row = CGFloat(y) + 0.5
            estimates.append(edge + row + (2 * edge * row).squareRoot())
        }
        guard estimates.count >= 2 else { return nil }
        let sorted = estimates.sorted()
        return sorted[sorted.count / 2]
    }
}
