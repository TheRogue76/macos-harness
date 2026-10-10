import CoreGraphics
import Foundation
import Testing
@testable import HarnessCore

@Suite struct WindowCornersTests {
    func corner(radius: CGFloat, side: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.clear(CGRect(x: 0, y: 0, width: side, height: side))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        let window = CGRect(x: 0, y: -CGFloat(side), width: CGFloat(side) * 2, height: CGFloat(side) * 2)
        context.addPath(CGPath(roundedRect: window, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.fillPath()
        return context.makeImage()
    }

    @Test func measuresACircularCorner() throws {
        for points in [10.0, 16.0, 26.0] {
            let image = try #require(corner(radius: points * 2, side: 96))
            let measured = try #require(WindowCorners.radius(of: image, scale: 2))
            #expect(abs(measured - points) < 0.75, "radius \(points) measured as \(measured)")
        }
    }

    @Test func measuresAtOneX() throws {
        let image = try #require(corner(radius: 16, side: 48))
        let measured = try #require(WindowCorners.radius(of: image, scale: 1))
        #expect(abs(measured - 16) < 1)
    }

    @Test func squareCornersHaveNoRadius() {
        #expect(WindowCorners.radius(width: 20, height: 20) { _, _ in 255 } == nil)
    }

    @Test func aFullyTransparentImageHasNoRadius() {
        #expect(WindowCorners.radius(width: 20, height: 20) { _, _ in 0 } == nil)
    }
}
