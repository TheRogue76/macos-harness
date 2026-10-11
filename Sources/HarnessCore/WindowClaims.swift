import Darwin
import Foundation
import HarnessProtocol

/// Which agent session is working in which window. Acting in a window claims it for the session;
/// other sessions can read it but can't act there until the claim lapses.
public actor WindowClaims {
    public static let shared = WindowClaims()
    /// How long a claim lasts after the holder's last action or read in the window.
    public static let lifetime: TimeInterval = 30

    /// One session's claim on a window.
    public struct Claim: Sendable, Equatable {
        /// The holder's instance key.
        public var owner: String
        public var ownerName: String
        /// The window, as a person would name it: `TextEdit window 455 “Untitled”`.
        public var place: String
        public var last: Date
    }

    private var claims: [UInt32: Claim] = [:]
    private let patience: TimeInterval
    private let now: @Sendable () -> Date
    private let isRunning: @Sendable (String) -> Bool

    /// `patience` is how long an action waits for another session's claim to lapse.
    public init(
        patience: TimeInterval = 5, now: @escaping @Sendable () -> Date = { Date() },
        isRunning: @escaping @Sendable (String) -> Bool = WindowClaims.ownerIsRunning
    ) {
        self.patience = patience
        self.now = now
        self.isRunning = isRunning
    }

    /// Claims the window for the owner, or renews its claim, waiting up to the patience for
    /// another session's claim to lapse; throws saying who works there when it doesn't.
    public func claim(_ window: UInt32, place: String, owner: String, ownerName: String) async throws {
        let deadline = now().addingTimeInterval(patience)
        while let holder = holder(of: window, besides: owner) {
            guard now() < deadline else { throw Self.refusal(holder, now: now()) }
            try await Task.sleep(for: .milliseconds(200))
        }
        claims[window] = Claim(owner: owner, ownerName: ownerName, place: place, last: now())
    }

    /// Renews the owner's claim on a window it read or captured; nothing when it holds none.
    public func renew(_ window: UInt32, owner: String) {
        guard var claim = claims[window], claim.owner == owner, isLive(claim) else { return }
        claim.last = now()
        claims[window] = claim
    }

    /// The live claim on a window by a session other than `owner`.
    public func holder(of window: UInt32, besides owner: String) -> Claim? {
        guard let claim = claims[window] else { return nil }
        guard isLive(claim) else {
            claims.removeValue(forKey: window)
            return nil
        }
        return claim.owner == owner ? nil : claim
    }

    /// Ends an owner's claims, for a session that ended or was stopped.
    public func release(owner: String) {
        claims = claims.filter { $0.value.owner != owner }
    }

    /// Ends every claim.
    public func releaseAll() {
        claims = [:]
    }

    private func isLive(_ claim: Claim) -> Bool {
        now().timeIntervalSince(claim.last) <= Self.lifetime && isRunning(claim.owner)
    }

    /// The error for an action in a window another session holds.
    static func refusal(_ holder: Claim, now: Date) -> RPCError {
        let ago = max(0, Int(now.timeIntervalSince(holder.last).rounded()))
        let lapses = max(1, Int(lifetime) - ago)
        return RPCError(
            code: RPCErrorCode.windowClaimed,
            message: "\(holder.ownerName) is working in \(holder.place) (its last step was \(ago) s ago). Work in another window, or try again in about \(lapses) s, when its claim lapses unless it keeps going."
        )
    }

    /// Whether the agent process in an instance key still runs; true for keys without one.
    public static let ownerIsRunning: @Sendable (String) -> Bool = { owner in
        guard let pid = InstanceNames.pid(of: owner) else { return true }
        return kill(pid, 0) == 0 || errno == EPERM
    }
}
