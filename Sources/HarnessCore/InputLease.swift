import Foundation
import HarnessProtocol

/// Who is acting and when to give up, passed from the helper into actions.
public struct ActionContext: Sendable {
    public var owner: String
    public var ownerName: String
    /// True once the user stopped this agent (or all agents): abort between steps.
    public var shouldAbort: @Sendable () async -> Bool
    /// The agent works in the background only: no real mouse or keyboard, no bringing apps forward.
    public var backgroundOnly: Bool

    public init(
        owner: String, ownerName: String, backgroundOnly: Bool = false, shouldAbort: @escaping @Sendable () async -> Bool
    ) {
        self.owner = owner
        self.ownerName = ownerName
        self.backgroundOnly = backgroundOnly
        self.shouldAbort = shouldAbort
    }

    public static let unattended = ActionContext(owner: "unattended", ownerName: "an agent") { false }

    /// Takes a turn with the mouse and keyboard for a step that opens a menu or brings an app
    /// forward, with a notice when it had to wait.
    public func takeTurn() async throws -> (token: UUID, notice: Notice?) {
        let grant = try await InputLease.shared.acquire(owner: owner, name: ownerName)
        guard let wait = grant.wait, wait.seconds >= 0.3 else { return (grant.token, nil) }
        return (grant.token, Notice(
            kind: "waitedForInput",
            message: "Waited \(wait.seconds.fixed(1)) s for \(wait.behind) to finish with the mouse and keyboard."
        ))
    }

    /// Ends a turn from `takeTurn`, keeping it while `menuOpen` says a menu the step opened is
    /// still showing.
    public func endTurn(_ token: UUID, holdingMenuWhile menuOpen: (@Sendable () -> Bool)?) async {
        await InputLease.shared.finish(token, holdingMenuWhile: menuOpen)
    }

    /// Claims a simulator for this session before acting on it.
    public func claim(simulator: SimulatorInfo) async throws {
        try await claim(WindowClaims.key(simulator: simulator.udid), place: "the simulator “\(simulator.name)”")
    }

    /// Claims an Android device for this session before acting on it.
    public func claim(android device: AndroidDeviceInfo) async throws {
        try await claim(WindowClaims.key(android: device.serial.isEmpty ? device.name : device.serial), place: "the Android device “\(device.name)”")
    }

    package func claim(_ key: String, place: String) async throws {
        guard owner != Self.unattended.owner else { return }
        try await WindowClaims.shared.claim(key, place: place, owner: owner, ownerName: ownerName)
    }
}

/// One agent session at a time holds the real mouse, keyboard and frontmost app, in the order
/// they asked.
package actor InputLease {
    package static let shared = InputLease()

    package init() {}

    /// How a session got its turn after waiting for others.
    package struct Wait: Sendable, Equatable {
        package var seconds: TimeInterval
        /// Who held the turn when the session started waiting.
        package var behind: String
    }

    /// A session's turn; it ends with its token.
    package struct Grant: Sendable, Equatable {
        package var token: UUID
        /// How long the session waited, or nil when the turn was free.
        package var wait: Wait?
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
    package func acquire(owner: String, name: String, timeout: Double = 20) async throws -> Grant {
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
    package func release(_ token: UUID) {
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
    package func holdForMenu(_ token: UUID) -> UUID? {
        guard var current = holder, current.token == token else { return nil }
        let held = UUID()
        current.token = held
        current.menuOpen = true
        holder = current
        return held
    }

    /// Ends a menu hold once `menuOpen` says the menu is gone, or after `limit`.
    package nonisolated func releaseWhenMenuCloses(_ token: UUID, menuOpen: @escaping @Sendable () -> Bool, limit: TimeInterval = 30) {
        Task {
            let deadline = Date().addingTimeInterval(limit)
            while Date() < deadline, menuOpen() {
                try? await Task.sleep(for: .milliseconds(150))
            }
            await release(token)
        }
    }

    /// Ends a turn, keeping it while `menuOpen` says a menu the turn opened is still showing.
    package func finish(_ token: UUID, holdingMenuWhile menuOpen: (@Sendable () -> Bool)?) {
        if let menuOpen, menuOpen(), let held = holdForMenu(token) {
            releaseWhenMenuCloses(held, menuOpen: menuOpen)
        } else {
            release(token)
        }
    }

    /// Who holds the turn and who waits for it, in order.
    package func status() -> (holder: String?, waiting: [String]) {
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

/// Who has the mouse and keyboard and who waits for them.
public struct InputTurns: Sendable, Equatable {
    public var holder: String?
    public var waiting: [String]

    public init(holder: String? = nil, waiting: [String] = []) {
        self.holder = holder
        self.waiting = waiting
    }
}
