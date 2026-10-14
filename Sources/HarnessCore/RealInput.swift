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

    /// Takes a turn with the mouse and keyboard for a step that opens a menu or brings an app
    /// forward, with a notice when it had to wait.
    public func takeTurn() async throws -> (token: UUID, notice: Notice?) {
        let grant = try await RealInput.Lease.shared.acquire(owner: owner, name: ownerName)
        guard let wait = grant.wait, wait.seconds >= 0.3 else { return (grant.token, nil) }
        return (grant.token, Notice(
            kind: "waitedForInput",
            message: String(format: "Waited %.1f s for %@ to finish with the mouse and keyboard.", wait.seconds, wait.behind)
        ))
    }

    /// Ends a turn from `takeTurn`, keeping it while the app `pid` shows a menu the step opened.
    public func endTurn(_ token: UUID, holdingMenuOf pid: pid_t? = nil) async {
        await RealInput.Lease.shared.finish(token, holdingMenuOf: pid)
    }

    /// Claims the window, or the simulator or Android device it shows, for this session before
    /// acting in it; unattended runs don't claim.
    public func claim(_ window: WindowService.Window, app: AppRef) async throws {
        if let simulator = window.info.simulator { return try await claim(simulator: simulator) }
        if let android = window.info.android { return try await claim(android: android) }
        let place = "\(app.name) window \(window.info.id) “\(window.info.title)”"
        try await claim(WindowClaims.key(window: window.info.id), place: place)
    }

    /// Claims a simulator for this session before acting on it.
    public func claim(simulator: SimulatorInfo) async throws {
        try await claim(WindowClaims.key(simulator: simulator.udid), place: "the simulator “\(simulator.name)”")
    }

    /// Claims an Android device for this session before acting on it.
    public func claim(android device: AndroidDeviceInfo) async throws {
        try await claim(WindowClaims.key(android: device.serial.isEmpty ? device.name : device.serial), place: "the Android device “\(device.name)”")
    }

    private func claim(_ key: String, place: String) async throws {
        guard owner != Self.unattended.owner else { return }
        try await WindowClaims.shared.claim(key, place: place, owner: owner, ownerName: ownerName)
    }
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
    /// One agent session at a time holds the real mouse, keyboard and frontmost app, in the order
    /// they asked.
    actor Lease {
        static let shared = Lease()

        /// How a session got its turn after waiting for others.
        struct Wait: Sendable, Equatable {
            var seconds: TimeInterval
            /// Who held the turn when the session started waiting.
            var behind: String
        }

        /// A session's turn; it ends with its token.
        struct Grant: Sendable, Equatable {
            var token: UUID
            /// How long the session waited, or nil when the turn was free.
            var wait: Wait?
        }

        private struct Holder {
            var owner: String
            var name: String
            var token: UUID
            /// The turn is held only because a menu the holder opened is still open.
            var menuOpen: Bool
        }

        private struct Waiter {
            let token: UUID
            let owner: String
            let name: String
            let continuation: CheckedContinuation<Void, Error>
        }

        private var holder: Holder?
        private var queue: [Waiter] = []

        /// Takes a turn, waiting in line behind earlier sessions for up to `timeout`; exclusive
        /// even for the same session, except that a session holding the turn for a menu it opened
        /// gets it back at once.
        func acquire(owner: String, name: String, timeout: Double = 20) async throws -> Grant {
            if let current = holder, current.menuOpen, current.owner == owner {
                let token = UUID()
                holder = Holder(owner: owner, name: name, token: token, menuOpen: false)
                return Grant(token: token, wait: nil)
            }
            guard let ahead = holder?.name ?? queue.first?.name else {
                let token = UUID()
                holder = Holder(owner: owner, name: name, token: token, menuOpen: false)
                return Grant(token: token, wait: nil)
            }
            let token = UUID()
            let started = Date()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.append(Waiter(token: token, owner: owner, name: name, continuation: continuation))
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(timeout))
                    await self?.giveUp(token)
                }
            }
            return Grant(token: token, wait: Wait(seconds: Date().timeIntervalSince(started), behind: ahead))
        }

        /// Ends a turn, handing it to the next session in line; nothing when the token's turn has
        /// already ended.
        func release(_ token: UUID) {
            guard holder?.token == token else { return }
            holder = nil
            guard !queue.isEmpty else { return }
            let next = queue.removeFirst()
            holder = Holder(owner: next.owner, name: next.name, token: next.token, menuOpen: false)
            next.continuation.resume()
        }

        /// Keeps the turn while a menu the holder opened stays open, so another session's step
        /// doesn't close it. Returns the token that ends the hold, or nil when `token` doesn't hold
        /// the turn.
        func holdForMenu(_ token: UUID) -> UUID? {
            guard var current = holder, current.token == token else { return nil }
            let held = UUID()
            current.token = held
            current.menuOpen = true
            holder = current
            return held
        }

        /// Ends a menu hold once the app shows no menu, or after `limit`.
        nonisolated func releaseWhenMenuCloses(_ token: UUID, pid: pid_t, limit: TimeInterval = 30) {
            Task {
                let deadline = Date().addingTimeInterval(limit)
                while Date() < deadline, MenuExtras.menuOnScreen(pid: pid) {
                    try? await Task.sleep(for: .milliseconds(150))
                }
                await release(token)
            }
        }

        /// Ends a turn, keeping it while the app shows a menu the turn opened.
        func finish(_ token: UUID, holdingMenuOf pid: pid_t?) {
            if let pid, MenuExtras.menuOnScreen(pid: pid), let held = holdForMenu(token) {
                releaseWhenMenuCloses(held, pid: pid)
            } else {
                release(token)
            }
        }

        /// Who holds the turn and who waits for it, in order.
        func status() -> (holder: String?, waiting: [String]) {
            (holder?.name, queue.map(\.name))
        }

        private func giveUp(_ token: UUID) {
            guard let index = queue.firstIndex(where: { $0.token == token }) else { return }
            let waiter = queue.remove(at: index)
            let ahead = index == 0 ? "" : " (with \(index) more session\(index == 1 ? "" : "s") ahead of you)"
            waiter.continuation.resume(throwing: RPCError(
                code: RPCErrorCode.inputBusy,
                message: "\(holder?.name ?? "Another session") is using the mouse and keyboard\(ahead), so no real input was sent. Try again shortly, or use an accessibility action."
            ))
        }
    }

    /// Has a made-up session hold the mouse and keyboard for 10 s with another waiting behind it,
    /// so the panel's and HUD's waiting lines can be reviewed.
    public static func turnDemo() async -> String {
        guard let grant = try? await Lease.shared.acquire(owner: "Demo Agent#1", name: "Demo Agent · demo-project", timeout: 1) else {
            return "someone has the mouse and keyboard right now; try again in a moment"
        }
        Task {
            let waiter = try? await Lease.shared.acquire(owner: "Demo Agent#2", name: "Demo Agent · other-project", timeout: 15)
            if let waiter { await Lease.shared.release(waiter.token) }
        }
        Task {
            try? await Task.sleep(for: .seconds(10))
            await Lease.shared.release(grant.token)
        }
        return "a made-up Demo Agent session has the mouse and keyboard for 10 s, with another waiting behind it"
    }

    /// Who has the mouse and keyboard right now and who waits for them, in order.
    public static func turns() async -> Turns {
        let status = await Lease.shared.status()
        return Turns(holder: status.holder, waiting: status.waiting)
    }

    /// Who has the mouse and keyboard and who waits for them.
    public struct Turns: Sendable, Equatable {
        public var holder: String?
        public var waiting: [String]

        public init(holder: String? = nil, waiting: [String] = []) {
            self.holder = holder
            self.waiting = waiting
        }
    }

    private static let clock = NSLock()
    nonisolated(unsafe) private static var lastSyntheticEvent = Date.distantPast
    nonisolated(unsafe) private static var lastSyntheticKey = Date.distantPast
    nonisolated(unsafe) private static var lastWarp: CGPoint?

    /// How long after the harness posts a key a key press can still be that key arriving late.
    static let keySettle: TimeInterval = 0.25

    static func markSynthetic(key: Bool = false) {
        clock.withLock {
            lastSyntheticEvent = Date()
            if key { lastSyntheticKey = lastSyntheticEvent }
        }
    }

    /// Whether the user pressed a key after `start`; keys the harness posted don't count.
    static func userTyped(after start: Date) -> Bool {
        let keyDown = Date().addingTimeInterval(-UserActivity.secondsSinceTyping())
        return typedByUser(keyDown: keyDown, after: start, lastPosted: clock.withLock { lastSyntheticKey })
    }

    /// Whether the latest key press, at `keyDown`, was the user's: after `start`, and late enough
    /// after the harness's own last key, posted at `lastPosted`, not to be that key.
    static func typedByUser(keyDown: Date, after start: Date, lastPosted: Date) -> Bool {
        keyDown > start && keyDown.timeIntervalSince(lastPosted) > keySettle
    }

    /// Moves the cursor to `point` without an event and remembers where.
    static func warpCursor(to point: CGPoint) {
        clock.withLock { lastWarp = point }
        CGWarpMouseCursorPosition(point)
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    /// Where the harness last warped the cursor to, if it has.
    static var lastWarpedCursor: CGPoint? {
        clock.withLock { lastWarp }
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
        markSynthetic(key: true)
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

/// The window a drag ends in when it isn't the one it starts in, and that window's app.
struct DropTarget {
    var app: AppRef
    var window: WindowService.Window
}

/// The window under a screen point: its app and window server ID.
struct WindowHit: Equatable {
    var pid: pid_t
    var appName: String
    var windowID: CGWindowID
}

/// One foreground step with real input: holds the lease from bringing the app forward until the
/// result has settled, checks the user is idle and the target is really under the point, aborts if
/// the user moves the mouse, types or stops the agent, puts the cursor back, and gives the front
/// back to the app that had it.
final class RealInputSession {
    enum Button { case left, right, middle }

    let app: AppRef
    /// The window the action starts in.
    let window: WindowService.Window?
    let context: ActionContext
    /// Whether the session only types, leaving the cursor alone.
    private let keyboardOnly: Bool
    private let savedCursor: CGPoint
    /// Where the session's events have put the cursor.
    private var trail: CursorTrail
    /// When the session started; keys pressed after it, other than the harness's, are the user's.
    private let started = Date()
    /// Where an unfinished drag started; ending the session there cancels the drag instead of dropping.
    private var dragStart: CGPoint?
    private let source = CGEventSource(stateID: .hidSystemState)
    private var buttonDown: (Button, CGPoint)?
    /// Modifiers held for a click or drag, released at the end.
    private var heldFlags: CGEventFlags = []
    /// Things the caller should pass on in its result.
    private(set) var notices: [Notice] = []
    /// The session's turn with the mouse and keyboard.
    private let token: UUID
    /// The app that was frontmost before the session brought its app forward.
    private var previousFront: pid_t?
    /// Whether the session waited for another to finish, so a picture taken before it started
    /// may be out of date.
    private(set) var waited = false
    private var finished = false

    private init(app: AppRef, window: WindowService.Window?, context: ActionContext, keyboardOnly: Bool, token: UUID) {
        self.token = token
        self.app = app
        self.window = window
        self.context = context
        self.keyboardOnly = keyboardOnly
        savedCursor = RealInput.cursorLocation
        trail = CursorTrail(resting: [savedCursor] + [RealInput.lastWarpedCursor].compactMap { $0 })
    }

    /// Starts a session: takes the lease, waits for the user to be idle, releases stale modifiers
    /// and brings the app to the front, with a drag's `drop` window right behind it.
    static func begin(
        app: AppRef, window: WindowService.Window?, context: ActionContext, keyboard: Bool, drop: DropTarget? = nil
    ) async throws -> RealInputSession {
        try WindowService.requireAccessibility()
        guard CGPreflightPostEventAccess() else {
            throw RPCError(code: RPCErrorCode.permissionMissing, message: "macOS Harness can't post input events; check Accessibility in `macos-harness doctor`.")
        }
        if keyboard, Permissions.secureInputEnabled {
            throw RPCError(code: RPCErrorCode.failed, message: "Secure Input is on (a password field has focus), so macOS blocks synthetic typing.")
        }
        let grant = try await RealInput.Lease.shared.acquire(owner: context.owner, name: context.ownerName)
        do {
            guard await RealInput.waitForUserIdle() else {
                throw RPCError(code: RPCErrorCode.failed, message: "The user is using the mouse or keyboard, so no real input was sent. Try again in a moment.")
            }
            if await context.shouldAbort() {
                throw RPCError(code: RPCErrorCode.stoppedByUser, message: "The user stopped this agent.")
            }
            let session = RealInputSession(app: app, window: window, context: context, keyboardOnly: keyboard, token: grant.token)
            session.waited = grant.wait != nil
            if let wait = grant.wait, wait.seconds >= 0.3 {
                session.notices.append(Notice(
                    kind: "waitedForInput",
                    message: String(format: "Waited %.1f s for %@ to finish with the mouse and keyboard.", wait.seconds, wait.behind)
                ))
            }
            let front = await AppControl.frontmostPID()
            session.previousFront = front == app.pid || front == getpid() ? nil : front
            let released = RealInput.releaseStaleModifiers(source: session.source)
            if !released.isEmpty {
                session.notices.append(Notice(kind: "modifiers", message: "macOS reported \(released.joined()) as held with no key pressed (a lost key-up); released it first so input isn't read as shortcuts."))
            }
            try await session.bringToFront(window: window, drop: drop)
            return session
        } catch {
            await RealInput.Lease.shared.release(grant.token)
            throw error
        }
    }

    /// Releases any held button and modifiers and puts the cursor back where the user left it. The
    /// session keeps the lease until `finish`.
    func end(restoreCursor: Bool = true) async {
        if let (button, point) = buttonDown {
            if let start = dragStart {
                RealInput.postKey(53, down: true, flags: [], source: source)
                RealInput.postKey(53, down: false, flags: [], source: source)
                post(type: dragType(button), at: start, button: button)
                post(type: upType(button), at: start, button: button)
                dragStart = nil
            } else {
                post(type: upType(button), at: point, button: button)
            }
        }
        releaseModifiers()
        if restoreCursor, !keyboardOnly {
            RealInput.warpCursor(to: savedCursor)
        }
    }

    /// Ends the foreground step once its result has settled: gives the front back to the app
    /// that had it (unless `keepFront`, a menu is open, someone else took the front, or the user
    /// is typing) and hands the turn to the next session in line, or, with `holdOpenMenu`, keeps
    /// it while a menu the step opened stays open. Returns a notice when it gave the front back.
    @discardableResult
    func finish(keepFront: Bool = false, holdOpenMenu: Bool = false) async -> Notice? {
        guard !finished else { return nil }
        finished = true
        let notice = await giveBackFront(keepFront: keepFront)
        await RealInput.Lease.shared.finish(token, holdingMenuOf: holdOpenMenu ? app.pid : nil)
        return notice
    }

    private func giveBackFront(keepFront: Bool) async -> Notice? {
        guard let previous = previousFront else { return nil }
        let menuOpen = MenuExtras.menuOnScreen(pid: app.pid)
        guard Self.shouldGiveBackFront(
            previous: previous, frontmost: await AppControl.frontmostPID(), target: app.pid, menuOpen: menuOpen, keepFront: keepFront
        ), let running = NSRunningApplication(processIdentifier: previous), !running.isTerminated,
              (try? await UserActivity.guardFocusChange(for: running.localizedName ?? "the previous app")) != nil else { return nil }
        _ = AX.set(AX.application(previous), "AXFrontmost", kCFBooleanTrue)
        return Notice(kind: "frontRestored", message: "Gave the front back to \(running.localizedName ?? "the app that had it"); \(app.name) stays as it is behind it.")
    }

    /// Whether to give the front back after a step: the session brought its app forward, it's
    /// still in front, no menu is open in it, and the action didn't ask to keep it there.
    static func shouldGiveBackFront(previous: pid_t?, frontmost: pid_t?, target: pid_t, menuOpen: Bool, keepFront: Bool) -> Bool {
        guard let previous, previous != target, !keepFront, !menuOpen else { return false }
        return frontmost == target
    }

    private func bringToFront(window: WindowService.Window?, drop: DropTarget?) async throws {
        if let drop {
            try await raise(drop.app, window: drop.window)
            if drop.app.pid != app.pid { await waitUntilFrontmost(drop.app.pid) }
        }
        try await raise(app, window: window)
        try? await Task.sleep(for: .milliseconds(250))
        guard await AppControl.frontmostPID() == app.pid else {
            throw RPCError(code: RPCErrorCode.failed, message: "\(app.name) couldn't be brought to the front (a system dialog may be in the way), so no real input was sent.")
        }
    }

    /// Activates `owner` (once the user stops typing) and raises its window above its others.
    private func raise(_ owner: AppRef, window: WindowService.Window?) async throws {
        if await AppControl.frontmostPID() != owner.pid {
            try await UserActivity.guardFocusChange(for: owner.name)
            _ = AX.set(AX.application(owner.pid), "AXFrontmost", kCFBooleanTrue)
        }
        if let window {
            if window.info.minimized { _ = AX.set(window.element, "AXMinimized", kCFBooleanFalse) }
            _ = AX.perform(window.element, "AXRaise")
        }
    }

    private func waitUntilFrontmost(_ pid: pid_t, timeout: Double = 1) async {
        let deadline = Date().addingTimeInterval(timeout)
        while await AppControl.frontmostPID() != pid, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        try? await Task.sleep(for: .milliseconds(100))
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

    /// Throws unless `point` is on a screen and the window under it is the drop window, so a drop
    /// there lands in it rather than in something covering it.
    func checkDrop(_ point: CGPoint, on drop: DropTarget) throws {
        let onScreen = NSScreen.screens.contains { Self.cgFrame(of: $0).contains(point) }
        if let refusal = Self.dropRefusal(
            at: point, onScreen: onScreen, hit: onScreen ? Self.windowHit(at: point) : nil,
            destination: drop.window.info, source: window?.info, actor: app
        ) {
            throw RPCError(code: RPCErrorCode.failed, message: refusal)
        }
    }

    /// Why a drop at a global point wouldn't land in `destination`, given the window under it, or
    /// nil when it would. `source` is the window the drag starts in and `actor` its app.
    static func dropRefusal(
        at point: CGPoint, onScreen: Bool, hit: WindowHit?, destination: WindowInfo, source: WindowInfo?, actor: AppRef
    ) -> String? {
        let x = Int((point.x - destination.frame.x).rounded())
        let y = Int((point.y - destination.frame.y).rounded())
        let place = "The drop point (\(x), \(y)) in \(destination.name(besides: actor))"
        guard onScreen else { return "\(place) isn't on any screen, so nothing was dragged." }
        guard let hit else {
            return "\(place) has no window under it (\(destination.app.name) may be hidden, or the window on another Space), so nothing was dragged."
        }
        if hit.pid == destination.app.pid, hit.windowID == destination.id { return nil }
        if let source, hit.pid == source.app.pid, hit.windowID == source.id {
            return "\(place) is covered by the window the drag starts in, so nothing was dragged; move the windows apart (`window move`) and try again."
        }
        if hit.pid == destination.app.pid {
            return "\(place) is covered by another \(hit.appName) window (\(hit.windowID)), so nothing was dragged."
        }
        return "\(place) is covered by \(hit.appName), so nothing was dragged; move the windows apart (`window move`) and try again."
    }

    /// The app window under a global point, ignoring the harness's own overlays; nil when there's none.
    static func windowHit(at point: CGPoint) -> WindowHit? {
        var hit: AXUIElement?
        var pid: pid_t = 0
        if AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit) == .success,
           let hit, AXUIElementGetPid(hit, &pid) == .success, pid != getpid(),
           let window = topLevelWindow(of: hit), let id = WindowService.windowID(of: window) {
            let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "another app"
            return WindowHit(pid: pid, appName: name, windowID: id)
        }
        let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        for window in windows {
            guard let owner = window[kCGWindowOwnerPID as String] as? pid_t, owner != getpid(),
                  (window[kCGWindowLayer as String] as? Int ?? 0) == 0,
                  let id = window[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let rect = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
            guard rect.contains(point) else { continue }
            return WindowHit(pid: owner, appName: window[kCGWindowOwnerName as String] as? String ?? "another app", windowID: id)
        }
        return nil
    }

    /// The window an element is in, as its app lists it: past sheets, drawers and popovers.
    static func topLevelWindow(of element: AXUIElement) -> AXUIElement? {
        var current = AX.element(element, "AXWindow") ?? element
        for _ in 0..<64 {
            guard let parent = AX.element(current, "AXParent") else {
                return AX.role(current) == "AXWindow" ? current : nil
            }
            if AX.role(parent) == "AXApplication" { return current }
            current = parent
        }
        return nil
    }

    /// Throws if the user stopped the agent, moved the mouse, typed or brought another app to the
    /// front; puts the cursor back when the system moved it back to where it rested.
    func checkInterruption() async throws {
        if await context.shouldAbort() { throw Self.stoppedPartway }
        if let cursor = CGEvent(source: nil)?.location {
            switch trail.place(of: cursor) {
            case .moved:
                throw RPCError(code: RPCErrorCode.failed, message: "The user moved the mouse, so the action stopped partway.")
            case .resting:
                if let latest = trail.latest { move(to: latest) }
            case .placed, .behind:
                break
            }
        }
        if RealInput.userTyped(after: started) {
            try? await Task.sleep(for: .milliseconds(150))
            if await context.shouldAbort() { throw Self.stoppedPartway }
            throw RPCError(code: RPCErrorCode.failed, message: "The user typed, so the action stopped partway.")
        }
        if await AppControl.frontmostPID() != app.pid {
            throw RPCError(code: RPCErrorCode.failed, message: "\(app.name) stopped being frontmost, so the action stopped partway.")
        }
    }

    private static var stoppedPartway: RPCError {
        RPCError(code: RPCErrorCode.stoppedByUser, message: "The user stopped this agent partway through the action.")
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

    /// Presses at `start`, moves to `end` and releases there; with `drop`, `end` must be in that window.
    func drag(
        from start: CGPoint, to end: CGPoint, hold: Double, duration: Double, flags: CGEventFlags = [], drop: DropTarget? = nil
    ) async throws {
        try checkTarget(start)
        if let drop { try checkDrop(end, on: drop) }
        move(to: start)
        try await pause(0.08)
        try await checkInterruption()
        pressModifiers(flags)
        defer { releaseModifiers() }
        post(type: .leftMouseDown, at: start, button: .left, clickState: 1, flags: flags)
        buttonDown = (.left, start)
        dragStart = start
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
        dragStart = nil
    }

    func hover(at point: CGPoint, dwell: Double) async throws {
        try checkTarget(point)
        move(to: point)
        let deadline = Date().addingTimeInterval(dwell)
        while Date() < deadline {
            try await pause(0.1)
        }
    }

    /// Scrolls by `dx`, `dy` pixels at `point`, which must reach the app, or `drop`'s window when given.
    func scroll(at point: CGPoint, dx: Double, dy: Double, drop: DropTarget? = nil) async throws {
        if let drop { try checkDrop(point, on: drop) } else { try checkTarget(point) }
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
            RealInput.markSynthetic(key: true)
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
        trail.post(point)
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
