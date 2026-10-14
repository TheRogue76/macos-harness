import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import HarnessProtocol

/// Private SkyLight calls that deliver mouse events to one process and make one of its windows
/// key without raising it or activating the app (spike S9).
enum SkyLight {
    private typealias PostToPid = @convention(c) (pid_t, CGEvent) -> Void
    private typealias SetIntegerField = @convention(c) (CGEvent, UInt32, Int64) -> Void
    private typealias SetWindowLocation = @convention(c) (CGEvent, CGPoint) -> Void
    private typealias MainConnectionID = @convention(c) () -> UInt32
    private typealias GetWindowOwner = @convention(c) (UInt32, UInt32, UnsafeMutablePointer<UInt32>) -> Int32
    private typealias GetConnectionPSN = @convention(c) (UInt32, UnsafeMutableRawPointer) -> Int32
    private typealias PostEventRecordTo = @convention(c) (UnsafeRawPointer, UnsafePointer<UInt8>) -> Int32
    private typealias GetFrontProcess = @convention(c) (UnsafeMutableRawPointer) -> Int32
    private typealias GetKeyFocusProcess = @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer) -> Int32
    private typealias GetProcessPID = @convention(c) (UnsafeRawPointer, UnsafeMutablePointer<pid_t>) -> Int32
    private typealias GetProcessForPID = @convention(c) (pid_t, UnsafeMutableRawPointer) -> Int32
    private typealias GetActiveSpace = @convention(c) (UInt32) -> UInt64

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard !pretendUnresolved.contains(name) else { return nil }
        _ = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_GLOBAL)
        guard let pointer = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }

    /// The private calls the background route needs.
    static let required = [
        "SLEventPostToPid", "SLEventSetIntegerValueField", "CGEventSetWindowLocation", "CGSMainConnectionID",
        "SLSGetWindowOwner", "SLSGetConnectionPSN", "SLPSPostEventRecordTo", "_SLPSGetFrontProcess",
        "SLPSGetKeyFocusProcess", "GetProcessPID", "CGSGetActiveSpace",
    ]

    /// Calls treated as unresolved in the current task, as if this macOS didn't have them; empty
    /// outside tests of the fallback.
    @TaskLocal static var pretendUnresolved: Set<String> = []

    private static let unresolved: Set<String> = Set(required.filter { dlsymResolves($0) == false })

    /// The private calls this needs that didn't resolve on this macOS.
    static var missing: [String] {
        required.filter { unresolved.contains($0) || pretendUnresolved.contains($0) }
    }

    private static func dlsymResolves(_ name: String) -> Bool {
        _ = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_GLOBAL)
        return dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) != nil
    }

    /// Posts an event to one process the way WindowServer posts live input, which the public
    /// `CGEvent.postToPid` doesn't.
    static func post(_ event: CGEvent, to pid: pid_t) -> Bool {
        guard let post = symbol("SLEventPostToPid", as: PostToPid.self) else { return false }
        post(pid, event)
        return true
    }

    static func setField(_ event: CGEvent, _ field: UInt32, _ value: Int64) {
        symbol("SLEventSetIntegerValueField", as: SetIntegerField.self)?(event, field, value)
    }

    static func setWindowLocation(_ event: CGEvent, _ point: CGPoint) {
        symbol("CGEventSetWindowLocation", as: SetWindowLocation.self)?(event, point)
    }

    /// The 8-byte process serial number of the process owning a window, or of a pid.
    static func psn(forWindow window: UInt32, pid: pid_t) -> [UInt8]? {
        var psn = [UInt8](repeating: 0, count: 8)
        if let connection = symbol("CGSMainConnectionID", as: MainConnectionID.self),
           let owner = symbol("SLSGetWindowOwner", as: GetWindowOwner.self),
           let connectionPSN = symbol("SLSGetConnectionPSN", as: GetConnectionPSN.self) {
            var ownerConnection: UInt32 = 0
            if owner(connection(), window, &ownerConnection) == 0, ownerConnection != 0,
               psn.withUnsafeMutableBytes({ connectionPSN(ownerConnection, $0.baseAddress!) }) == 0 {
                return psn
            }
        }
        if let forPID = symbol("GetProcessForPID", as: GetProcessForPID.self),
           psn.withUnsafeMutableBytes({ forPID(pid, $0.baseAddress!) }) == 0 {
            return psn
        }
        return nil
    }

    /// Makes `window` key in its app without raising it, activating the app or taking key
    /// status from the user's window.
    static func focusWithoutRaise(pid: pid_t, window: UInt32) -> Bool {
        guard let postRecord = symbol("SLPSPostEventRecordTo", as: PostEventRecordTo.self),
              let target = psn(forWindow: window, pid: pid) else { return false }
        var record = [UInt8](repeating: 0, count: 0xF8)
        record[0x04] = 0xF8
        record[0x08] = 0x0D
        withUnsafeBytes(of: window.littleEndian) { bytes in
            for (index, byte) in bytes.enumerated() { record[0x3C + index] = byte }
        }
        record[0x8A] = 0x01
        return target.withUnsafeBytes { psnBytes in
            record.withUnsafeBufferPointer { postRecord(psnBytes.baseAddress!, $0.baseAddress!) == 0 }
        }
    }

    private static func pid(fromPSN psn: [UInt8]) -> pid_t? {
        guard let toPID = symbol("GetProcessPID", as: GetProcessPID.self), psn != [UInt8](repeating: 0, count: 8) else { return nil }
        var pid: pid_t = 0
        let status = psn.withUnsafeBytes { toPID($0.baseAddress!, &pid) }
        return status == 0 && pid > 0 ? pid : nil
    }

    /// The pid WindowServer has frontmost, without waiting for AppKit's activation notice.
    static func frontProcessPID() -> pid_t? {
        guard let front = symbol("_SLPSGetFrontProcess", as: GetFrontProcess.self) else { return nil }
        var psn = [UInt8](repeating: 0, count: 8)
        guard psn.withUnsafeMutableBytes({ front($0.baseAddress!) }) == 0 else { return nil }
        return pid(fromPSN: psn)
    }

    /// The pid WindowServer sends keystrokes to.
    static func keyFocusPID() -> pid_t? {
        guard let keyFocus = symbol("SLPSGetKeyFocusProcess", as: GetKeyFocusProcess.self) else { return nil }
        var psn = [UInt8](repeating: 0, count: 8)
        var connection = [UInt64](repeating: 0, count: 2)
        let status = psn.withUnsafeMutableBytes { psnBytes in
            connection.withUnsafeMutableBytes { keyFocus(psnBytes.baseAddress!, $0.baseAddress!) }
        }
        return status == 0 ? pid(fromPSN: psn) : nil
    }

    /// The Space the user is on.
    static func activeSpace() -> UInt64? {
        guard let connection = symbol("CGSMainConnectionID", as: MainConnectionID.self),
              let space = symbol("CGSGetActiveSpace", as: GetActiveSpace.self) else { return nil }
        return space(connection())
    }
}

/// Mouse clicks delivered to a background window without moving the cursor (spike S9).
enum BackgroundClick {
    enum Button: String { case left, right }

    /// Where `CGEventSetWindowLocation` points: the screen point, or the point inside the window.
    enum Location: String { case screen, window }

    struct Step {
        var type: CGEventType
        var at: CGPoint
        var phase: Int64
        var clickState: Int64
        var button: Int64
        var pause: UInt32
    }

    /// The events of a click: a move to prime the window's tracking, for a left click an
    /// off-screen press that opens Chromium's user-activation gate, then the press pairs.
    static func plan(at point: CGPoint, count: Int, button: Button) -> [Step] {
        if button == .right {
            return [
                Step(type: .mouseMoved, at: point, phase: 2, clickState: 0, button: 1, pause: 12_000),
                Step(type: .rightMouseDown, at: point, phase: 3, clickState: 1, button: 1, pause: 28_000),
                Step(type: .rightMouseUp, at: point, phase: 3, clickState: 1, button: 1, pause: 0),
            ]
        }
        let offScreen = CGPoint(x: -1, y: -1)
        var steps = [
            Step(type: .mouseMoved, at: point, phase: 2, clickState: 0, button: 0, pause: 15_000),
            Step(type: .leftMouseDown, at: offScreen, phase: 1, clickState: 1, button: 0, pause: 1_000),
            Step(type: .leftMouseUp, at: offScreen, phase: 2, clickState: 1, button: 0, pause: 100_000),
        ]
        let pairs = min(max(count, 1), 2)
        for pair in 1...pairs {
            steps.append(Step(type: .leftMouseDown, at: point, phase: 3, clickState: Int64(pair), button: 0, pause: 1_000))
            steps.append(Step(type: .leftMouseUp, at: point, phase: 3, clickState: Int64(pair), button: 0, pause: pair < pairs ? 80_000 : 0))
        }
        return steps
    }

    /// Clicks `point` (screen coordinates) in window `window` of `pid` without raising it.
    static func click(
        pid: pid_t, window: UInt32, at point: CGPoint, windowOrigin: CGPoint, count: Int, button: Button,
        location: Location, focusFirst: Bool
    ) async -> Bool {
        if focusFirst {
            _ = SkyLight.focusWithoutRaise(pid: pid, window: window)
            try? await Task.sleep(for: .milliseconds(50))
        }
        let source = CGEventSource(stateID: .hidSystemState)
        let group = Int64(Date().timeIntervalSince1970 * 1_000_000) & 0x7FFF_FFFF
        for step in plan(at: point, count: count, button: button) {
            let mouseButton: CGMouseButton = button == .right ? .right : .left
            guard let event = CGEvent(mouseEventSource: source, mouseType: step.type, mouseCursorPosition: step.at, mouseButton: mouseButton) else {
                return false
            }
            SkyLight.setField(event, 0, step.phase)
            SkyLight.setField(event, 1, step.clickState)
            SkyLight.setField(event, 3, step.button)
            SkyLight.setField(event, 7, 3)
            SkyLight.setField(event, 40, Int64(pid))
            SkyLight.setField(event, 51, Int64(window))
            SkyLight.setField(event, 91, Int64(window))
            SkyLight.setField(event, 92, Int64(window))
            SkyLight.setField(event, 58, group)
            let stamped = location == .window && step.at.x >= 0
                ? CGPoint(x: step.at.x - windowOrigin.x, y: step.at.y - windowOrigin.y)
                : step.at
            SkyLight.setWindowLocation(event, stamped)
            guard SkyLight.post(event, to: pid) else { return false }
            if step.pause > 0 { try? await Task.sleep(for: .microseconds(Int(step.pause))) }
        }
        return true
    }
}

extension BackgroundClick {
    /// The wheel events of a scroll by `dx`, `dy` pixels: about 40 pixels each, like the real wheel.
    static func wheelSteps(dx: Double, dy: Double) -> [(dx: Int32, dy: Int32)] {
        let count = max(1, Int(max(abs(dx), abs(dy)) / 40))
        return Array(repeating: (Int32(dx / Double(count)), Int32(dy / Double(count))), count: count)
    }

    /// Scrolls by `dx`, `dy` pixels at `point` (screen coordinates) in a background window;
    /// positive `dy` scrolls the content up.
    static func scroll(
        pid: pid_t, window: UInt32, at point: CGPoint, windowOrigin: CGPoint, dx: Double, dy: Double, posting: ScrollPosting = .route
    ) async -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)
        let local = CGPoint(x: point.x - windowOrigin.x, y: point.y - windowOrigin.y)
        func stamp(_ event: CGEvent) {
            SkyLight.setField(event, 40, Int64(pid))
            SkyLight.setField(event, 51, Int64(window))
            SkyLight.setField(event, 91, Int64(window))
            SkyLight.setField(event, 92, Int64(window))
            SkyLight.setWindowLocation(event, local)
        }
        func deliver(_ event: CGEvent) -> Bool {
            if posting != .publicCall, !SkyLight.post(event, to: pid) { return false }
            if posting != .skyLight { event.postToPid(pid) }
            return true
        }
        guard let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) else { return false }
        stamp(move)
        guard deliver(move) else { return false }
        try? await Task.sleep(for: .milliseconds(15))
        for step in wheelSteps(dx: dx, dy: dy) {
            guard let wheel = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: step.dy, wheel2: step.dx, wheel3: 0) else {
                return false
            }
            wheel.location = point
            stamp(wheel)
            guard deliver(wheel) else { return false }
            try? await Task.sleep(for: .milliseconds(16))
        }
        return true
    }

    /// Which calls post each event of a background scroll.
    enum ScrollPosting: String {
        case skyLight = "skylight"
        case publicCall = "public"
        case both

        /// The calls the background route posts through: one, since apps take each posting.
        static let route = ScrollPosting.skyLight
    }
}

extension Spikes {
    /// What the user's side of the screen looks like: front app, key focus, cursor, Space.
    struct Posture: Equatable {
        var frontPID: pid_t?
        var keyFocusPID: pid_t?
        var frontFocusedWindow: CGWindowID?
        var cursor: CGPoint
        var space: UInt64?
        var targetAbove: UInt32?
    }

    @MainActor
    static func posture(target window: UInt32, targetPID: pid_t) -> Posture {
        let front = NSWorkspace.shared.frontmostApplication
        let frontRef = front.map { AppRef(name: $0.localizedName ?? "?", bundleIdentifier: $0.bundleIdentifier, pid: $0.processIdentifier) }
        return Posture(
            frontPID: SkyLight.frontProcessPID(),
            keyFocusPID: SkyLight.keyFocusPID(),
            frontFocusedWindow: frontRef.flatMap { WindowService.focusedWindowID(of: $0) },
            cursor: CGEvent(source: nil)?.location ?? .zero,
            space: SkyLight.activeSpace(),
            targetAbove: OnScreenWindow.current(of: window, ignoring: targetPID).flatMap(\.nearestAbove)
        )
    }

    /// The window a spike acts on and its frame: one of the app's windows, or with `id` any
    /// on-screen window the window server lists, such as a sheet that accessibility doesn't.
    static func spikeWindow(_ query: String, id: UInt32?, app: AppRef) throws -> (id: UInt32, frame: CGRect) {
        do {
            let window = try WindowService.resolve(Target(app: query, window: id), app: app)
            return (window.info.id, window.info.frame.cgRect)
        } catch {
            guard let id, let shown = OnScreenWindow.current(of: id, ignoring: 0) else { throw error }
            return (id, shown.frame)
        }
    }

    /// S9: click a point in an app's window through SkyLight without raising it, and report
    /// whether the user's front app, key focus, cursor, Space and the window's stacking stayed.
    static func backgroundClick(_ arguments: [String]) async throws -> String {
        let usage = "bgclick <app> <x> <y> [count=1] [left|right] [screen|window] [nofocus] [window=<id>] [scroll=<pixels>] [post=skylight|public|both]"
        guard arguments.count >= 3, let x = Double(arguments[1]), let y = Double(arguments[2]) else {
            throw RPCError(code: RPCErrorCode.invalidParams, message: "usage: \(usage)")
        }
        let options = Array(arguments.dropFirst(3))
        let count = options.compactMap(Int.init).first ?? 1
        let button: BackgroundClick.Button = options.contains("right") ? .right : .left
        let location: BackgroundClick.Location = options.contains("window") ? .window : .screen
        let focusFirst = !options.contains("nofocus")
        let windowID = options.first { $0.hasPrefix("window=") }.flatMap { UInt32($0.dropFirst(7)) }

        let missing = SkyLight.missing
        guard missing.isEmpty || !missing.contains("SLEventPostToPid") else {
            return "SLEventPostToPid doesn't resolve on this macOS; missing: \(missing.joined(separator: ", "))"
        }
        let app = try await MainActor.run { try AppResolver.resolve(arguments[0]) }
        let (targetWindow, frame) = try spikeWindow(arguments[0], id: windowID, app: app)
        let screenPoint = CGPoint(x: frame.minX + x, y: frame.minY + y)
        let targetPID = app.pid

        let before = await MainActor.run { posture(target: targetWindow, targetPID: targetPID) }
        let scrollPixels = options.first { $0.hasPrefix("scroll=") }.flatMap { Double($0.dropFirst(7)) }
        let posting = options.first { $0.hasPrefix("post=") }.flatMap { BackgroundClick.ScrollPosting(rawValue: String($0.dropFirst(5))) } ?? .route
        let delivered = if let scrollPixels {
            await BackgroundClick.scroll(
                pid: app.pid, window: targetWindow, at: screenPoint, windowOrigin: frame.origin, dx: 0, dy: scrollPixels, posting: posting
            )
        } else {
            await BackgroundClick.click(
                pid: app.pid, window: targetWindow, at: screenPoint, windowOrigin: frame.origin,
                count: count, button: button, location: location, focusFirst: focusFirst
            )
        }
        try? await Task.sleep(for: .milliseconds(350))
        let after = await MainActor.run { posture(target: targetWindow, targetPID: targetPID) }

        func name(_ pid: pid_t?) -> String {
            guard let pid else { return "unknown" }
            return NSRunningApplication(processIdentifier: pid)?.localizedName.map { "\($0) (\(pid))" } ?? "pid \(pid)"
        }
        func row(_ label: String, _ old: String, _ new: String) -> String {
            "\(label): \(old == new ? "unchanged, \(new)" : "\(old) → \(new)")"
        }
        var lines = [
            "\(scrollPixels.map { "scroll \(Int($0)) px posted through \(posting.rawValue)" } ?? "\(button.rawValue) click ×\(count)") at window (\(Int(x)), \(Int(y))) = screen (\(Int(screenPoint.x)), \(Int(screenPoint.y))) in \(app.name) window \(targetWindow), location \(location.rawValue), focus record \(focusFirst ? "sent" : "skipped"): \(delivered ? "posted" : "not posted")",
            row("front app", name(before.frontPID), name(after.frontPID)),
            row("key focus", name(before.keyFocusPID), name(after.keyFocusPID)),
            row("front app's focused window", before.frontFocusedWindow.map(String.init) ?? "none", after.frontFocusedWindow.map(String.init) ?? "none"),
            row("cursor", "(\(Int(before.cursor.x)), \(Int(before.cursor.y)))", "(\(Int(after.cursor.x)), \(Int(after.cursor.y)))"),
            row("Space", before.space.map(String.init) ?? "?", after.space.map(String.init) ?? "?"),
            row("window directly above the target", before.targetAbove.map(String.init) ?? "none", after.targetAbove.map(String.init) ?? "none"),
        ]
        if !missing.isEmpty { lines.append("missing private calls: \(missing.joined(separator: ", "))") }
        return lines.joined(separator: "\n")
    }
}
