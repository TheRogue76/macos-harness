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

    @Test func windowPointsBecomeScreenPoints() throws {
        let (point, node) = try PointerService.resolve(nil, point: Point(x: 30, y: 20), window: window, app: window.info.app, role: "target")
        #expect(point == CGPoint(x: 130, y: 70))
        #expect(node == nil)
    }

    @Test func pointsOutsideTheWindowAreRefused() {
        #expect(throws: RPCError.self) {
            try PointerService.resolve(nil, point: Point(x: 401, y: 20), window: window, app: window.info.app, role: "target")
        }
        #expect(throws: RPCError.self) {
            try PointerService.resolve(nil, point: nil, window: window, app: window.info.app, role: "drag destination")
        }
    }

    @Test func modifiersParseAndRejectUnknownNames() throws {
        let flags = try PointerService.modifierFlags(["cmd", "Shift"])
        #expect(flags.contains(.maskCommand) && flags.contains(.maskShift))
        #expect(!flags.contains(.maskAlternate))
        #expect(throws: RPCError.self) { try PointerService.modifierFlags(["hyper"]) }
    }

    @Test func modifiersArePressedInKeyboardOrder() {
        // Control, option, shift, command: released in reverse so the state ends clean.
        #expect(RealInput.modifierKeys.map(\.symbol).joined() == "⌃⌥⇧⌘")
        #expect(RealInput.rightModifierKeys.map(\.flag) == RealInput.modifierKeys.map(\.flag))
    }
}

struct InputLeaseTests {
    @Test func oneAgentAtATime() async throws {
        let lease = RealInput.Lease()
        try await lease.acquire(owner: "a", name: "Codex")
        await #expect(throws: RPCError.self) {
            try await lease.acquire(owner: "b", name: "pi", timeout: 0.2)
        }
        // Even the same agent waits: two gestures at once would fight over the cursor.
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
