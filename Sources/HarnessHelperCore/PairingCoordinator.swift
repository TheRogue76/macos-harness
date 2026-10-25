#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import HarnessCore
import HarnessProtocol
import Observation

/// Pending pairing requests, shown in the panel until the user answers.
@MainActor
@Observable
package final class PairingCoordinator: PairingGate {
    package enum Decision: Sendable { case allow, session, deny }

    package struct Request: Identifiable {
        package let id = UUID()
        package let caller: CallerIdentity
        package var waiters: [CheckedContinuation<Bool, Never>]
    }

    package private(set) var pending: [Request] = []
    package private(set) var paired: [PairingStore.Pairing] = []
    /// Called with each new request, to ask the user.
    @ObservationIgnored package var onNewRequest: ((Request) -> Void)?

    @ObservationIgnored private let store: PairingStore
    /// "This session only" approvals, by instance key: valid while the agent process that asked
    /// is alive, and only for that process.
    @ObservationIgnored private var sessionApprovals: Set<String> = []
    /// Approve every caller without asking, for CI runs where nobody can answer.
    package let approvesEveryone: Bool

    package init(store: PairingStore, approvesEveryone: Bool = false) {
        self.store = store
        self.approvesEveryone = approvesEveryone
        paired = store.all
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                self?.withdrawAbandoned()
            }
        }
    }

    private func withdrawAbandoned() {
        for request in pending {
            guard let pid = request.caller.chain.first?.pid, pid > 0, kill(pid, 0) != 0, errno == ESRCH else { continue }
            resolve(request.id, .deny)
        }
    }

    package nonisolated func isPaired(_ caller: CallerIdentity) async -> Bool {
        await isApproved(caller)
    }

    package nonisolated func requestApproval(for caller: CallerIdentity) async -> Bool {
        await ask(caller)
    }

    package func isApproved(_ caller: CallerIdentity) -> Bool {
        if approvesEveryone || store.isPaired(caller.key) { return true }
        guard sessionApprovals.contains(caller.instanceKey) else { return false }
        if InstanceNames.pid(of: caller.instanceKey) != nil, ActivityCenter.isRunning(caller.instanceKey) { return true }
        sessionApprovals.remove(caller.instanceKey)
        return false
    }

    private func ask(_ caller: CallerIdentity) async -> Bool {
        if isApproved(caller) { return true }
        return await withCheckedContinuation { continuation in
            if let index = pending.firstIndex(where: { $0.caller.instanceKey == caller.instanceKey }) {
                pending[index].waiters.append(continuation)
                return
            }
            let request = Request(caller: caller, waiters: [continuation])
            pending.append(request)
            onNewRequest?(request)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.approvalTimeout))
                self?.resolve(request.id, .deny)
            }
        }
    }

    /// How long a pairing prompt waits for the user before the request is refused.
    package static let approvalTimeout: Double = 120

    package func resolve(_ id: Request.ID, _ decision: Decision) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        let request = pending.remove(at: index)
        switch decision {
        case .allow: store.approve(key: request.caller.key, displayName: request.caller.displayName)
        case .session: sessionApprovals.insert(request.caller.instanceKey)
        case .deny: break
        }
        paired = store.all
        for waiter in request.waiters {
            waiter.resume(returning: decision != .deny)
        }
    }

    package func revoke(key: String) {
        store.revoke(key: key)
        sessionApprovals = sessionApprovals.filter { InstanceNames.kindKey(of: $0) != key }
        paired = store.all
    }

    /// The key of the made-up agent the debug commands show, which no real caller has.
    package static let demoKey = "Demo Agent|DEMO123456|preview"

    /// Pairs the made-up Demo Agent, so the settings' list and its Revoke can be reviewed.
    package func addDemoPairing() {
        store.approve(key: Self.demoKey, displayName: "Demo Agent")
        paired = store.all
    }
}
