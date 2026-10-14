import CoreGraphics
import Foundation
import HarnessProtocol
import Testing
@testable import HarnessCore

struct BackgroundInputTests {
    private func params(_ action: PointerAction, modifiers: [String] = [], dy: Double = 0, diff: Bool = true, real: Bool? = nil, toTarget: Target? = nil) -> PointerMethod.Params {
        PointerMethod.Params(target: Target(app: "TextEdit"), action: action, toTarget: toTarget, modifiers: modifiers, dy: dy, diff: diff, real: real)
    }

    @Test func clicksAndScrollsTryTheBackground() {
        #expect(BackgroundInput.gesture(for: params(.click)) == .click(count: 1, button: .left))
        #expect(BackgroundInput.gesture(for: params(.doubleClick)) == .click(count: 2, button: .left))
        #expect(BackgroundInput.gesture(for: params(.rightClick)) == .click(count: 1, button: .right))
        #expect(BackgroundInput.gesture(for: params(.scroll, dy: -200)) == .scroll(dx: 0, dy: -200))
    }

    @Test func theRestUsesTheRealMouse() {
        #expect(BackgroundInput.gesture(for: params(.hover)) == nil)
        #expect(BackgroundInput.gesture(for: params(.drag)) == nil)
        #expect(BackgroundInput.gesture(for: params(.longPress)) == nil)
        #expect(BackgroundInput.gesture(for: params(.scroll)) == nil)
        #expect(BackgroundInput.gesture(for: params(.click, modifiers: ["cmd"])) == nil)
        #expect(BackgroundInput.gesture(for: params(.click, real: true)) == nil)
        #expect(BackgroundInput.gesture(for: params(.click, diff: false)) == nil)
        #expect(BackgroundInput.gesture(for: params(.click, toTarget: Target(app: "Finder"))) == nil)
    }

    @Test func aLeftClickPrimesThenPresses() {
        let point = CGPoint(x: 100, y: 50)
        let single = BackgroundClick.plan(at: point, count: 1, button: .left)
        #expect(single.map(\.type) == [.mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDown, .leftMouseUp])
        #expect(single[1].at == CGPoint(x: -1, y: -1))
        #expect(single.suffix(2).allSatisfy { $0.at == point && $0.phase == 3 })
        let double = BackgroundClick.plan(at: point, count: 2, button: .left)
        #expect(double.filter { $0.type == .leftMouseDown && $0.at == point }.map(\.clickState) == [1, 2])
        let right = BackgroundClick.plan(at: point, count: 1, button: .right)
        #expect(right.map(\.type) == [.mouseMoved, .rightMouseDown, .rightMouseUp])
    }

    @Test func scrollsInWheelSizedSteps() {
        #expect(BackgroundClick.wheelSteps(dx: 0, dy: -200).count == 5)
        #expect(BackgroundClick.wheelSteps(dx: 0, dy: -200).allSatisfy { $0.dy == -40 && $0.dx == 0 })
        #expect(BackgroundClick.wheelSteps(dx: 10, dy: 0).count == 1)
    }

    private func image(_ width: Int, _ height: Int, painting rect: CGRect? = nil) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if let rect {
            context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            context.fill(rect)
        }
        return context.makeImage()!
    }

    @Test func pixelChangesBeyondNoiseCount() {
        let plain = image(200, 100)
        #expect(!BackgroundInput.differs(plain, image(200, 100)))
        #expect(!BackgroundInput.differs(plain, image(200, 100, painting: CGRect(x: 0, y: 0, width: 2, height: 2))))
        #expect(BackgroundInput.differs(plain, image(200, 100, painting: CGRect(x: 10, y: 10, width: 20, height: 10))))
        #expect(BackgroundInput.differs(plain, image(100, 100)))
        #expect(!BackgroundInput.differs(nil, plain))
    }
}
