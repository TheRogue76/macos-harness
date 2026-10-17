import ApplicationServices
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

    @Test func withoutADiffTheyStillTryTheBackgroundUnchecked() {
        #expect(BackgroundInput.gesture(for: params(.click, diff: false)) == .click(count: 1, button: .left))
        #expect(BackgroundInput.gesture(for: params(.scroll, dy: -200, diff: false)) == .scroll(dx: 0, dy: -200))
        #expect(BackgroundInput.stands(.unchecked))
    }

    @Test func theRestUsesTheRealMouse() {
        #expect(BackgroundInput.gesture(for: params(.hover)) == nil)
        #expect(BackgroundInput.gesture(for: params(.drag)) == nil)
        #expect(BackgroundInput.gesture(for: params(.longPress)) == nil)
        #expect(BackgroundInput.gesture(for: params(.scroll)) == nil)
        #expect(BackgroundInput.gesture(for: params(.click, modifiers: ["cmd"])) == nil)
        #expect(BackgroundInput.gesture(for: params(.click, real: true)) == nil)
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

    @Test func scrollsPostEachEventOnce() {
        #expect(BackgroundClick.ScrollPosting.route != .both)
    }

    @Test func pixelChangesBeyondNoiseCount() {
        let plain = image(200, 100)
        #expect(!BackgroundInput.differs(plain, image(200, 100)))
        #expect(!BackgroundInput.differs(plain, image(200, 100, painting: CGRect(x: 0, y: 0, width: 2, height: 2))))
        #expect(BackgroundInput.differs(plain, image(200, 100, painting: CGRect(x: 10, y: 10, width: 20, height: 10))))
        #expect(BackgroundInput.differs(plain, image(100, 100)))
        #expect(!BackgroundInput.differs(nil, plain))
    }

    @Test func aWindowTurningActiveIsNoEffect() {
        let plain = image(480, 309)
        let button = CGRect(x: 8, y: 6, width: 8, height: 8)
        let recolored = image(480, 309, painting: CGRect(x: 8, y: 309 - 6 - 8, width: 8, height: 8))
        #expect(BackgroundInput.turnedActive(plain, recolored, closeButton: button))
        #expect(!BackgroundInput.turnedActive(plain, image(480, 309, painting: CGRect(x: 100, y: 100, width: 40, height: 40)), closeButton: button))
        #expect(!BackgroundInput.turnedActive(plain, recolored, closeButton: nil))
    }

    @Test func aBlinkingCaretIsNoEffect() {
        let plain = image(480, 309)
        #expect(!BackgroundInput.differs(plain, image(480, 309, painting: CGRect(x: 6, y: 23, width: 3, height: 40))))
        #expect(BackgroundInput.differs(plain, image(480, 309, painting: CGRect(x: 6, y: 23, width: 12, height: 12))))
    }
}

struct MissingSkyLightTests {
    private let window = WindowService.Window(
        info: WindowInfo(
            id: 1, app: AppRef(name: "Test", bundleIdentifier: nil, pid: getpid()), title: "Test",
            frame: Rect(x: 100, y: 50, width: 400, height: 300), onScreen: true, minimized: false,
            focused: true, main: true, subrole: nil, hasSheet: false
        ),
        element: AXUIElementCreateApplication(getpid())
    )
    private let inside = CGPoint(x: 200, y: 100)
    private let onScreen: (UInt32) -> Bool = { _ in true }

    private func routes(_ action: PointerAction, dy: Double = 0) -> Bool {
        let params = PointerMethod.Params(target: Target(app: "Test"), action: action, dy: dy, diff: true)
        return BackgroundInput.route(for: params, at: inside, in: window, isOnScreen: onScreen) != nil
    }

    @Test func anyMissingCallMakesTheRouteUnavailable() {
        SkyLight.$pretendUnresolved.withValue(Set(SkyLight.required)) {
            #expect(SkyLight.missing == SkyLight.required)
            #expect(!BackgroundInput.isAvailable)
        }
        for name in SkyLight.required {
            SkyLight.$pretendUnresolved.withValue([name]) {
                #expect(SkyLight.missing.contains(name))
                #expect(!BackgroundInput.isAvailable)
            }
        }
    }

    @Test func pointerAndPressUseRealInputWithoutThem() {
        let available = SkyLight.missing.isEmpty
        #expect(routes(.click) == available)
        #expect(routes(.scroll, dy: -200) == available)
        #expect(BackgroundInput.reachable(inside, in: window, isOnScreen: onScreen) == available)
        SkyLight.$pretendUnresolved.withValue(["SLEventPostToPid"]) {
            #expect(!routes(.click))
            #expect(!routes(.doubleClick))
            #expect(!routes(.rightClick))
            #expect(!routes(.scroll, dy: -200))
            #expect(!BackgroundInput.reachable(inside, in: window, isOnScreen: onScreen))
        }
    }

    @Test func theCallsFailQuietlyWithoutThem() async {
        let gestures: [BackgroundInput.Gesture] = [
            .click(count: 1, button: .left), .click(count: 2, button: .left), .click(count: 1, button: .right), .scroll(dx: 0, dy: -120),
        ]
        await SkyLight.$pretendUnresolved.withValue(Set(SkyLight.required)) {
            #expect(SkyLight.frontProcessPID() == nil)
            #expect(SkyLight.keyFocusPID() == nil)
            #expect(SkyLight.activeSpace() == nil)
            #expect(!SkyLight.focusWithoutRaise(pid: getpid(), window: 1))
            for gesture in gestures {
                let sent = await BackgroundInput.send(gesture, app: window.info.app, window: window, at: inside)
                #expect(!sent)
            }
            let scrolled = await BackgroundClick.scroll(
                pid: getpid(), window: 1, at: inside, windowOrigin: .zero, dx: 0, dy: -40, posting: .skyLight
            )
            #expect(!scrolled)
        }
    }
}

struct BackgroundSkipTests {
    @Test func textInputsAndSheetsSkipTheBackground() {
        #expect(BackgroundInput.skipReason(role: "AXTextArea", ancestorRoles: ["AXScrollArea", "AXWindow"]) != nil)
        #expect(BackgroundInput.skipReason(role: "AXTextField", ancestorRoles: ["AXGroup", "AXWindow"]) != nil)
        #expect(BackgroundInput.skipReason(role: "AXButton", ancestorRoles: ["AXSheet", "AXWindow"]) != nil)
        #expect(BackgroundInput.skipReason(role: "AXButton", ancestorRoles: ["AXGroup", "AXWindow"]) == nil)
        #expect(BackgroundInput.skipReason(role: "AXCell", ancestorRoles: ["AXRow", "AXTable", "AXScrollArea", "AXWindow"]) == nil)
    }

    @Test func anUnconfirmedClickIsUnverifiableNotRepeated() {
        let assessed = ActionEffect.assess(
            step: .pointer(.click), via: "background click", changed: false, notices: ["backgroundUnconfirmed"], checked: true
        )
        #expect(assessed.effect == "unverifiable")
        #expect(assessed.suggestion?.contains("real=true") == true)
    }
}

struct BackgroundOutcomeTests {
    @Test func onlyRightClicksWithoutAMenuAndUnsentEventsFallBack() {
        #expect(BackgroundInput.stands(.effect))
        #expect(BackgroundInput.stands(.noEffect))
        #expect(!BackgroundInput.stands(.noMenu))
        #expect(!BackgroundInput.stands(.notSent))
        let notice = BackgroundInput.fallbackNotice(.click(count: 1, button: .right), outcome: .noMenu)
        #expect(notice.kind == "backgroundNoEffect")
        #expect(notice.message.contains("opened no menu"))
    }
}
