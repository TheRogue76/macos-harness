import ApplicationServices
import CoreGraphics
import Foundation
import HarnessProtocol
import Testing
@testable import HarnessCore

struct PointerTests {
    private let window = WindowService.Window(
        info: WindowInfo(
            id: 1, app: AppRef(name: "Test", bundleIdentifier: nil, pid: getpid()), title: "Test",
            frame: Rect(x: 100, y: 50, width: 400, height: 300), onScreen: true, minimized: false,
            focused: true, main: true, subrole: nil, hasSheet: false
        ),
        element: AXUIElementCreateApplication(getpid())
    )

    @Test func windowPointsBecomeScreenPoints() async throws {
        let placement = try await PointerService.place(nil, point: Point(x: 30, y: 20), window: window, app: window.info.app, role: "target")
        #expect(placement.point == CGPoint(x: 130, y: 70))
        #expect(placement.node == nil)
    }

    @Test func pointsOutsideTheWindowAreRefused() async {
        for point in [Point(x: 401, y: 20), nil] {
            do {
                _ = try await PointerService.place(nil, point: point, window: window, app: window.info.app, role: "target")
                Issue.record("expected a refusal for \(String(describing: point))")
            } catch {
                #expect(error is RPCError)
            }
        }
    }

    @Test func modifiersParseAndRejectUnknownNames() throws {
        let flags = try PointerService.modifierFlags(["cmd", "Shift"])
        #expect(flags.contains(.maskCommand) && flags.contains(.maskShift))
        #expect(!flags.contains(.maskAlternate))
        #expect(throws: RPCError.self) { try PointerService.modifierFlags(["hyper"]) }
    }

    @Test func modifiersArePressedInKeyboardOrder() {
        #expect(RealInput.modifierKeys.map(\.symbol).joined() == "⌃⌥⇧⌘")
        #expect(RealInput.rightModifierKeys.map(\.flag) == RealInput.modifierKeys.map(\.flag))
    }

    @Test func dragDestinationsOutsideTheWindowPointToAnotherWindow() async {
        do {
            _ = try await PointerService.place(nil, point: Point(x: 900, y: 300), window: window, app: window.info.app, role: "drag destination")
            Issue.record("expected a refusal")
        } catch let error as RPCError {
            #expect(error.message.hasPrefix("(900, 300) is outside the window (400x300)."))
            #expect(error.message.contains("--to-app and --to-window"))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func dragsIntoAnAndroidDeviceAreRefusedBeforeLookingForIt() async {
        do {
            _ = try await PointerService.dropTarget(Target(app: "android:booted"), from: window.info.app, window: window)
            Issue.record("expected a refusal")
        } catch let error as RPCError {
            #expect(error.message == PointerService.androidCrossing)
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func noDestinationTargetKeepsTheDragInItsWindow() async throws {
        #expect(try await PointerService.dropTarget(nil, from: window.info.app, window: window)?.window.info == nil)
    }
}

struct DropTests {
    private let finder = AppRef(name: "Finder", bundleIdentifier: "com.apple.finder", pid: 10)
    private let textEdit = AppRef(name: "TextEdit", bundleIdentifier: "com.apple.TextEdit", pid: 20)

    private func window(_ id: UInt32, of app: AppRef, simulator: SimulatorInfo? = nil, android: AndroidDeviceInfo? = nil) -> WindowInfo {
        WindowInfo(
            id: id, app: app, title: id == 455 ? "Untitled" : "", frame: Rect(x: 100, y: 50, width: 400, height: 300),
            onScreen: true, minimized: false, focused: true, main: true, subrole: nil, hasSheet: false,
            simulator: simulator, android: android
        )
    }

    private func refusal(_ hit: WindowHit?, onScreen: Bool = true) -> String? {
        RealInputSession.dropRefusal(
            at: CGPoint(x: 140, y: 110), onScreen: onScreen, hit: hit,
            destination: window(455, of: textEdit), source: window(3, of: finder), actor: finder
        )
    }

    @Test func aDropOnTheNamedWindowGoesAhead() {
        #expect(refusal(WindowHit(pid: 20, appName: "TextEdit", windowID: 455)) == nil)
    }

    @Test func aDropOnAnythingElseIsRefusedAndSaysWhatsInTheWay() {
        let place = "The drop point (40, 60) in TextEdit window 455 “Untitled”"
        #expect(refusal(WindowHit(pid: 10, appName: "Finder", windowID: 3))?.hasPrefix("\(place) is covered by the window the drag starts in") == true)
        #expect(refusal(WindowHit(pid: 20, appName: "TextEdit", windowID: 456))?.hasPrefix("\(place) is covered by another TextEdit window (456)") == true)
        #expect(refusal(WindowHit(pid: 30, appName: "Terminal", windowID: 9))?.hasPrefix("\(place) is covered by Terminal") == true)
        #expect(refusal(WindowHit(pid: 10, appName: "Finder", windowID: 4))?.hasPrefix("\(place) is covered by Finder") == true)
        #expect(refusal(nil)?.hasPrefix("\(place) has no window under it") == true)
        #expect(refusal(nil, onScreen: false)?.hasPrefix("\(place) isn't on any screen") == true)
    }

    @Test func macWindowsAndDevicesDontMix() {
        let iPhone = SimulatorInfo(udid: "A", name: "iPhone", runtime: "iOS 27", state: "Booted")
        let iPad = SimulatorInfo(udid: "B", name: "iPad", runtime: "iOS 27", state: "Booted")
        let pixel = AndroidDeviceInfo(serial: "emulator-5554", name: "Pixel", kind: "emulator", state: "running")
        let phone = AndroidDeviceInfo(serial: "R5CT", name: "Galaxy", kind: "phone", state: "running")
        let hub = AppRef(name: "Device Hub", bundleIdentifier: nil, pid: 40)
        #expect(PointerService.crossingRefusal(from: window(3, of: finder), to: window(455, of: textEdit)) == nil)
        #expect(PointerService.crossingRefusal(from: window(1, of: hub, simulator: iPhone), to: window(1, of: hub, simulator: iPhone)) == nil)
        #expect(PointerService.crossingRefusal(from: window(3, of: finder), to: window(1, of: hub, simulator: iPhone))?.contains("Mac window and an iOS Simulator") == true)
        #expect(PointerService.crossingRefusal(from: window(1, of: hub, simulator: iPhone), to: window(2, of: hub, simulator: iPad))?.contains("one simulator to another") == true)
        #expect(PointerService.crossingRefusal(from: window(0, of: hub, android: pixel), to: window(0, of: hub, android: pixel)) == nil)
        #expect(PointerService.crossingRefusal(from: window(0, of: hub, android: pixel), to: window(0, of: hub, android: phone))?.contains("one Android device to another") == true)
        #expect(PointerService.crossingRefusal(from: window(1, of: hub, simulator: iPhone), to: window(0, of: hub, android: pixel)) == PointerService.androidCrossing)
        #expect(PointerService.crossingRefusal(from: window(0, of: hub, android: pixel), to: window(3, of: finder)) == PointerService.androidCrossing)
    }
}

struct InputLeaseTests {
    @Test func oneAgentAtATime() async throws {
        let lease = RealInput.Lease()
        try await lease.acquire(owner: "a", name: "Codex")
        await #expect(throws: RPCError.self) {
            try await lease.acquire(owner: "b", name: "pi", timeout: 0.2)
        }
        await #expect(throws: RPCError.self) {
            try await lease.acquire(owner: "a", name: "Codex", timeout: 0.2)
        }
        await lease.release(owner: "a")
        try await lease.acquire(owner: "b", name: "pi", timeout: 0.2)
        await lease.release(owner: "b")
    }

    @Test func waitersGetTheLeaseWhenItFrees() async throws {
        let lease = RealInput.Lease()
        try await lease.acquire(owner: "a", name: "Codex")
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            await lease.release(owner: "a")
        }
        try await lease.acquire(owner: "b", name: "pi", timeout: 2)
        await lease.release(owner: "b")
    }
}

struct ActParamsTests {
    @Test func olderClientsWithoutRealStillDecode() throws {
        let json = #"{"target":{"app":"Notes"},"action":"type","value":"hi"}"#
        let params = try HarnessJSON.decoder.decode(ActMethod.Params.self, from: Data(json.utf8))
        #expect(params.real == false)
        #expect(params.diff == true)
        #expect(params.count == 1)
    }

    @Test func pointerParamsRoundTrip() throws {
        let params = PointerMethod.Params(
            target: Target(app: "Chess"), action: .drag, point: Point(x: 10, y: 20),
            to: ElementSelector(text: "f3"), modifiers: ["opt"], hold: 0.5
        )
        let data = try HarnessJSON.encoder.encode(params)
        let decoded = try HarnessJSON.decoder.decode(PointerMethod.Params.self, from: data)
        #expect(decoded.action == .drag)
        #expect(decoded.to == ElementSelector(text: "f3"))
        #expect(decoded.modifiers == ["opt"])
        #expect(decoded.hold == 0.5)
    }
}
