import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import HarnessProtocol

/// Who is acting and when to give up, passed from the helper into actions.
public struct ActionContext: Sendable {
    public var owner: String
    public var ownerName: String
    /// True once the user stopped this agent (or all agents): abort between steps.
    public var shouldAbort: @Sendable () async -> Bool

    public init(owner: String, ownerName: String, shouldAbort: @escaping @Sendable () async -> Bool) {
        self.owner = owner
        self.ownerName = ownerName
        self.shouldAbort = shouldAbort
    }

    public static let unattended = ActionContext(owner: "unattended", ownerName: "an agent") { false }
}

/// Lets the helper show where real input is about to land.
public final class RealInputHooks: @unchecked Sendable {
    public static let shared = RealInputHooks()
    /// Called before the first event of a real-input action, with the global point, a description
    /// and the acting agent (key and display name).
    public var willAct: (@Sendable (_ point: CGPoint, _ description: String, _ owner: String, _ ownerName: String) async -> Void)?
}

/// Real mouse and keyboard events, and the state every real-input session shares.
public enum RealInput {
    /// One agent at a time drives the real mouse and keyboard.
    actor Lease {
        static let shared = Lease()
        private var holder: (owner: String, name: String)?

        /// Takes the lease, waiting up to `timeout` for it; exclusive even for the same agent.
        func acquire(owner: String, name: String, timeout: Double = 10) async throws {
            let deadline = Date().addingTimeInterval(timeout)
            while let current = holder {
                guard Date() < deadline else {
                    throw RPCError(code: RPCErrorCode.failed, message: "\(current.name) is using the mouse and keyboard right now; try again shortly.")
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            holder = (owner, name)
        }

        func release(owner: String) {
            holder = nil
        }
    }

    private static let clock = NSLock()
    nonisolated(unsafe) private static var lastSyntheticEvent = Date.distantPast

    static func markSynthetic() {
        clock.withLock { lastSyntheticEvent = Date() }
    }

    /// Seconds since the user's own mouse or keyboard input, ignoring events the harness posted.
    public static func secondsSinceUserInput() -> Double {
        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .rightMouseDown, .leftMouseDragged, .scrollWheel, .keyDown, .flagsChanged]
        let sinceInput = types.map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }.min() ?? .infinity
        let sinceOurs = clock.withLock { Date().timeIntervalSince(lastSyntheticEvent) }
        return sinceInput + 0.05 < sinceOurs ? sinceInput : .infinity
    }

    static func waitForUserIdle(quiet: Double = 1.0, timeout: Double = 8) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while secondsSinceUserInput() < quiet {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return true
    }

    static var cursorLocation: CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    /// Left-hand modifier keys, in the order they're pressed.
    static let modifierKeys: [(code: CGKeyCode, flag: CGEventFlags, symbol: String)] = [
        (59, .maskControl, "⌃"), (58, .maskAlternate, "⌥"), (56, .maskShift, "⇧"), (55, .maskCommand, "⌘"),
    ]
    /// Right-hand modifier keys, in the same order.
    static let rightModifierKeys: [(code: CGKeyCode, flag: CGEventFlags, symbol: String)] = [
        (62, .maskControl, "⌃"), (61, .maskAlternate, "⌥"), (60, .maskShift, "⇧"), (54, .maskCommand, "⌘"),
    ]

    /// Posts a key combination as a keyboard would: modifiers down, the key, modifiers up.
    public static func postCombo(keyCode: CGKeyCode, flags: CGEventFlags, source: CGEventSource?) {
        let modifiers = modifierKeys.filter { flags.contains($0.flag) }
        var held: CGEventFlags = []
        for modifier in modifiers {
            held.insert(modifier.flag)
            postKey(modifier.code, down: true, flags: held, source: source)
        }
        postKey(keyCode, down: true, flags: held, source: source)
        postKey(keyCode, down: false, flags: held, source: source)
        for modifier in modifiers.reversed() {
            held.remove(modifier.flag)
            postKey(modifier.code, down: false, flags: held, source: source)
        }
        markSynthetic()
    }

    static func postKey(_ code: CGKeyCode, down: Bool, flags: CGEventFlags, source: CGEventSource?) {
        let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
    }

    /// Releases modifier keys macOS reports as held while the user is idle, and returns their
    /// symbols.
    static func releaseStaleModifiers(source: CGEventSource?) -> [String] {
        guard CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .flagsChanged) > 1 else { return [] }
        let held = (modifierKeys + rightModifierKeys).filter { CGEventSource.keyState(.hidSystemState, key: $0.code) }
        guard !held.isEmpty else { return [] }
        var flags = held.reduce(into: CGEventFlags()) { $0.insert($1.flag) }
        for key in held.reversed() {
            flags.remove(key.flag)
            postKey(key.code, down: false, flags: flags, source: source)
        }
        markSynthetic()
        return held.map(\.symbol)
    }
}

/// One real-input action: holds the lease, checks the user is idle and the target is really
/// under the point, aborts if the user moves the mouse or stops the agent, and puts the cursor back.
final class RealInputSession {
    enum Button { case left, right, middle }

    let app: AppRef
    let context: ActionContext
    /// Whether the session only types, leaving the cursor alone.
    private let keyboardOnly: Bool
    private let savedCursor: CGPoint
    private var expectedCursor: CGPoint
    private let source = CGEventSource(stateID: .hidSystemState)
    private var buttonDown: (Button, CGPoint)?
    /// Modifiers held for a click or drag, released at the end.
    private var heldFlags: CGEventFlags = []
    /// Things the caller should pass on in its result.
    private(set) var notices: [Notice] = []

    private init(app: AppRef, context: ActionContext, keyboardOnly: Bool) {
        self.app = app
        self.context = context
        self.keyboardOnly = keyboardOnly
        savedCursor = RealInput.cursorLocation
        expectedCursor = savedCursor
    }

    /// Starts a session: takes the lease, waits for the user to be idle, releases stale modifiers
    /// and brings the app to the front.
    static func begin(app: AppRef, window: WindowService.Window?, context: ActionContext, keyboard: Bool) async throws -> RealInputSession {
        try WindowService.requireAccessibility()
        guard CGPreflightPostEventAccess() else {
            throw RPCError(code: RPCErrorCode.permissionMissing, message: "macOS Harness can't post input events; check Accessibility in `macos-harness doctor`.")
        }
        if keyboard, Permissions.secureInputEnabled {
            throw RPCError(code: RPCErrorCode.failed, message: "Secure Input is on (a password field has focus), so macOS blocks synthetic typing.")
        }
        try await RealInput.Lease.shared.acquire(owner: context.owner, name: context.ownerName)
        do {
            guard await RealInput.waitForUserIdle() else {
                throw RPCError(code: RPCErrorCode.failed, message: "The user is using the mouse or keyboard, so no real input was sent. Try again in a moment.")
            }
            if await context.shouldAbort() {
                throw RPCError(code: RPCErrorCode.stoppedByUser, message: "The user stopped this agent.")
            }
            let session = RealInputSession(app: app, context: context, keyboardOnly: keyboard)
            let released = RealInput.releaseStaleModifiers(source: session.source)
            if !released.isEmpty {
                session.notices.append(Notice(kind: "modifiers", message: "macOS reported \(released.joined()) as held with no key pressed (a lost key-up); released it first so input isn't read as shortcuts."))
            }
            try await session.bringToFront(window: window)
            return session
        } catch {
            await RealInput.Lease.shared.release(owner: context.owner)
            throw error
        }
    }

    /// Releases any held button and modifiers, puts the cursor back where the user left it, and
    /// frees the lease.
    func end(restoreCursor: Bool = true) async {
        if let (button, point) = buttonDown {
            post(type: upType(button), at: point, button: button)
        }
        releaseModifiers()
        if restoreCursor, !keyboardOnly {
            CGWarpMouseCursorPosition(savedCursor)
            CGAssociateMouseAndMouseCursorPosition(1)
        }
        await RealInput.Lease.shared.release(owner: context.owner)
    }

    private func bringToFront(window: WindowService.Window?) async throws {
        if await AppControl.frontmostPID() != app.pid {
            try await UserActivity.guardFocusChange(for: app.name)
            _ = AX.set(AX.application(app.pid), "AXFrontmost", kCFBooleanTrue)
        }
        if let window {
            if window.info.minimized { _ = AX.set(window.element, "AXMinimized", kCFBooleanFalse) }
            _ = AX.perform(window.element, "AXRaise")
        }
        try? await Task.sleep(for: .milliseconds(250))
        guard await AppControl.frontmostPID() == app.pid else {
            throw RPCError(code: RPCErrorCode.failed, message: "\(app.name) couldn't be brought to the front (a system dialog may be in the way), so no real input was sent.")
        }
    }

    /// Throws unless `point` is on a screen and a click there would reach the target app.
    func checkTarget(_ point: CGPoint) throws {
        guard NSScreen.screens.contains(where: { Self.cgFrame(of: $0).contains(point) }) else {
            throw RPCError(code: RPCErrorCode.failed, message: "(\(Int(point.x)), \(Int(point.y))) isn't on any screen.")
        }
        var hit: AXUIElement?
        var pid: pid_t = 0
        if AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit) == .success,
           let hit, AXUIElementGetPid(hit, &pid) == .success, pid != getpid() {
            if pid == app.pid { return }
            let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "another app"
            throw RPCError(code: RPCErrorCode.failed, message: "(\(Int(point.x)), \(Int(point.y))) is covered by \(name), so nothing was clicked.")
        }
        let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        for window in windows {
            guard let owner = window[kCGWindowOwnerPID as String] as? pid_t, owner != getpid(),
                  (window[kCGWindowLayer as String] as? Int ?? 0) == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let rect = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
            guard rect.contains(point) else { continue }
            if owner == app.pid { return }
            let name = window[kCGWindowOwnerName as String] as? String ?? "another app"
            throw RPCError(code: RPCErrorCode.failed, message: "(\(Int(point.x)), \(Int(point.y))) is covered by \(name), so nothing was clicked.")
        }
        throw RPCError(code: RPCErrorCode.failed, message: "No window of \(app.name) is under (\(Int(point.x)), \(Int(point.y))).")
    }

    /// Throws if the user stopped the agent, moved the mouse or brought another app to the front.
    func checkInterruption() async throws {
        if await context.shouldAbort() {
            throw RPCError(code: RPCErrorCode.stoppedByUser, message: "The user stopped this agent partway through the action.")
        }
        let now = RealInput.cursorLocation
        if hypot(now.x - expectedCursor.x, now.y - expectedCursor.y) > 3 {
            throw RPCError(code: RPCErrorCode.failed, message: "The user moved the mouse, so the action stopped partway.")
        }
        if await AppControl.frontmostPID() != app.pid {
            throw RPCError(code: RPCErrorCode.failed, message: "\(app.name) stopped being frontmost, so the action stopped partway.")
        }
    }

    func move(to point: CGPoint) {
        post(type: buttonDown.map { dragType($0.0) } ?? .mouseMoved, at: point, button: buttonDown?.0 ?? .left)
    }

    func click(at point: CGPoint, button: Button = .left, count: Int = 1, flags: CGEventFlags = []) async throws {
        try checkTarget(point)
        move(to: point)
        try await pause(0.05)
        pressModifiers(flags)
        defer { releaseModifiers() }
        for index in 1...max(1, count) {
            post(type: downType(button), at: point, button: button, clickState: index, flags: flags)
            buttonDown = (button, point)
            post(type: upType(button), at: point, button: button, clickState: index, flags: flags)
            buttonDown = nil
            if index < count { try await pause(0.06) }
        }
    }

    /// Holds the left button down at a point for `hold` seconds: a long press.
    func press(at point: CGPoint, hold: Double, flags: CGEventFlags = []) async throws {
        try checkTarget(point)
        move(to: point)
        try await pause(0.05)
        pressModifiers(flags)
        defer { releaseModifiers() }
        post(type: .leftMouseDown, at: point, button: .left, clickState: 1, flags: flags)
        buttonDown = (.left, point)
        try await pause(hold)
        post(type: .leftMouseUp, at: point, button: .left, clickState: 1, flags: flags)
        buttonDown = nil
    }

    func drag(from start: CGPoint, to end: CGPoint, hold: Double, duration: Double, flags: CGEventFlags = []) async throws {
        try checkTarget(start)
        move(to: start)
        try await pause(0.08)
        try await checkInterruption()
        pressModifiers(flags)
        defer { releaseModifiers() }
        post(type: .leftMouseDown, at: start, button: .left, clickState: 1, flags: flags)
        buttonDown = (.left, start)
        try await pause(max(hold, 0.05))
        let steps = max(12, Int(duration / 0.016))
        for step in 1...steps {
            let t = Double(step) / Double(steps)
            let eased = t * t * (3 - 2 * t)
            let point = CGPoint(x: start.x + (end.x - start.x) * eased, y: start.y + (end.y - start.y) * eased)
            try await checkInterruption()
            post(type: .leftMouseDragged, at: point, button: .left, flags: flags)
            buttonDown = (.left, point)
            try await Task.sleep(for: .seconds(duration / Double(steps)))
        }
        try await pause(0.12)
        post(type: .leftMouseUp, at: end, button: .left, clickState: 1, flags: flags)
        buttonDown = nil
    }

    func hover(at point: CGPoint, dwell: Double) async throws {
        try checkTarget(point)
        move(to: point)
        let deadline = Date().addingTimeInterval(dwell)
        while Date() < deadline {
            try await pause(0.1)
        }
    }

    /// Scrolls by `dx`, `dy` pixels at `point`.
    func scroll(at point: CGPoint, dx: Double, dy: Double) async throws {
        try checkTarget(point)
        move(to: point)
        try await pause(0.05)
        let steps = max(1, Int(max(abs(dx), abs(dy)) / 40))
        for _ in 0..<steps {
            let event = CGEvent(
                scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                wheel1: Int32(dy / Double(steps)), wheel2: Int32(dx / Double(steps)), wheel3: 0
            )
            event?.location = point
            event?.post(tap: .cghidEventTap)
            RealInput.markSynthetic()
            try await pause(0.016)
        }
    }

    func key(_ combo: KeyCombo) async throws {
        try await checkFrontmost()
        RealInput.postCombo(keyCode: combo.keyCode, flags: combo.flags, source: source)
    }

    func type(_ text: String) async throws {
        for (index, unit) in text.utf16.enumerated() {
            if index % 20 == 0 { try await checkFrontmost() }
            for keyDown in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown)
                var character = unit
                event?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &character)
                event?.flags = []
                event?.post(tap: .cghidEventTap)
            }
            RealInput.markSynthetic()
            try await Task.sleep(for: .milliseconds(8))
        }
    }

    private func checkFrontmost() async throws {
        if await context.shouldAbort() {
            throw RPCError(code: RPCErrorCode.stoppedByUser, message: "The user stopped this agent partway through typing.")
        }
        guard await AppControl.frontmostPID() == app.pid else {
            throw RPCError(code: RPCErrorCode.failed, message: "\(app.name) stopped being frontmost, so typing stopped (keys would have gone elsewhere).")
        }
    }

    private func pressModifiers(_ flags: CGEventFlags) {
        for modifier in RealInput.modifierKeys where flags.contains(modifier.flag) && !heldFlags.contains(modifier.flag) {
            heldFlags.insert(modifier.flag)
            RealInput.postKey(modifier.code, down: true, flags: heldFlags, source: source)
        }
        RealInput.markSynthetic()
    }

    private func releaseModifiers() {
        guard !heldFlags.isEmpty else { return }
        for modifier in RealInput.modifierKeys.reversed() where heldFlags.contains(modifier.flag) {
            heldFlags.remove(modifier.flag)
            RealInput.postKey(modifier.code, down: false, flags: heldFlags, source: source)
        }
        RealInput.markSynthetic()
    }

    private func pause(_ seconds: Double) async throws {
        try await Task.sleep(for: .seconds(seconds))
        try await checkInterruption()
    }

    private func post(type: CGEventType, at point: CGPoint, button: Button, clickState: Int = 0, flags: CGEventFlags = []) {
        let mouseButton: CGMouseButton = switch button {
        case .left: .left
        case .right: .right
        case .middle: .center
        }
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: mouseButton) else { return }
        if clickState > 0 { event.setIntegerValueField(.mouseEventClickState, value: Int64(clickState)) }
        if !flags.isEmpty { event.flags = flags }
        event.post(tap: .cghidEventTap)
        RealInput.markSynthetic()
        expectedCursor = point
    }

    private func downType(_ button: Button) -> CGEventType {
        switch button { case .left: .leftMouseDown; case .right: .rightMouseDown; case .middle: .otherMouseDown }
    }

    private func upType(_ button: Button) -> CGEventType {
        switch button { case .left: .leftMouseUp; case .right: .rightMouseUp; case .middle: .otherMouseUp }
    }

    private func dragType(_ button: Button) -> CGEventType {
        switch button { case .left: .leftMouseDragged; case .right: .rightMouseDragged; case .middle: .otherMouseDragged }
    }

    /// The screen's frame in event coordinates, top-left origin of the primary display.
    static func cgFrame(of screen: NSScreen) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: screen.frame.minX, y: primaryHeight - screen.frame.maxY, width: screen.frame.width, height: screen.frame.height)
    }
}
