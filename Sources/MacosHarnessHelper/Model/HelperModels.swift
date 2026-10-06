import AppKit
import Combine
import Darwin
import HarnessCore
import HarnessProtocol

/// What agents have been doing, and which ones the user has stopped.
@MainActor
final class ActivityCenter: ObservableObject {
    @Published private(set) var sessions: [AgentSession] = []
    @Published private(set) var recent: [ActivityEntry] = []
    /// Agents the user stopped individually, by key, with their display names.
    @Published private(set) var stoppedAgents: [String: String] = [:]
    @Published private(set) var allStopped = false
    @Published private(set) var thumbnails: [UInt32: NSImage] = [:]

    /// Called for every recorded entry (the on-screen highlight listens).
    var onEntry: ((ActivityEntry) -> Void)?
    private var tracker = SessionTracker()

    /// Where stops are saved, so they survive a helper restart.
    private let defaults = UserDefaults.standard

    init() {
        stoppedAgents = defaults.dictionary(forKey: "stoppedAgents") as? [String: String] ?? [:]
        allStopped = defaults.bool(forKey: "allStopped")
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                self?.refresh()
            }
        }
    }

    private func saveStops() {
        defaults.set(stoppedAgents, forKey: "stoppedAgents")
        defaults.set(allStopped, forKey: "allStopped")
    }

    func record(_ entry: ActivityEntry) {
        tracker.record(entry)
        refresh()
        onEntry?(entry)
    }

    func refresh() {
        tracker.expire(at: Date())
        sessions = tracker.active(at: Date())
        recent = tracker.recent
    }

    func isStopped(_ key: String) -> Bool {
        allStopped || stoppedAgents[key] != nil
    }

    func stop(key: String, name: String) {
        stoppedAgents[key] = name
        saveStops()
    }

    func resume(key: String) {
        stoppedAgents.removeValue(forKey: key)
        saveStops()
    }

    /// Stops every agent, including ones that haven't shown up yet, until the user resumes.
    func stopAll() {
        allStopped = true
        for session in sessions { stoppedAgents[session.agentKey] = session.agentName }
        saveStops()
    }

    func resumeAll() {
        allStopped = false
        stoppedAgents = [:]
        saveStops()
    }

    /// Refreshes the small window pictures on the session cards.
    func refreshThumbnails() async {
        for session in sessions {
            guard let id = session.lastWindowID, let image = await Thumbnailer.capture(windowID: id) else { continue }
            thumbnails[id] = image
        }
    }
}

/// Pending pairing requests, shown in the panel until the user answers.
@MainActor
final class PairingCoordinator: ObservableObject, PairingGate {
    enum Decision { case allow, session, deny }

    struct Request: Identifiable {
        let id = UUID()
        let caller: CallerIdentity
        var waiters: [CheckedContinuation<Bool, Never>]
    }

    @Published private(set) var pending: [Request] = []
    @Published private(set) var paired: [PairingStore.Pairing] = []
    var onNewRequest: (() -> Void)?

    private let store: PairingStore
    /// "This session only" approvals: valid while the agent process that asked is alive.
    private var sessionApprovals: [String: pid_t] = [:]

    init(store: PairingStore) {
        self.store = store
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

    nonisolated func isPaired(_ caller: CallerIdentity) async -> Bool {
        await isApproved(caller)
    }

    nonisolated func requestApproval(for caller: CallerIdentity) async -> Bool {
        await ask(caller)
    }

    func isApproved(_ caller: CallerIdentity) -> Bool {
        if store.isPaired(caller.key) { return true }
        guard let pid = sessionApprovals[caller.key] else { return false }
        if pid > 0, kill(pid, 0) == 0 || errno == EPERM { return true }
        sessionApprovals.removeValue(forKey: caller.key)
        return false
    }

    private func ask(_ caller: CallerIdentity) async -> Bool {
        if isApproved(caller) { return true }
        return await withCheckedContinuation { continuation in
            if let index = pending.firstIndex(where: { $0.caller.key == caller.key }) {
                pending[index].waiters.append(continuation)
                return
            }
            pending.append(Request(caller: caller, waiters: [continuation]))
            onNewRequest?()
        }
    }

    func resolve(_ id: Request.ID, _ decision: Decision) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        let request = pending.remove(at: index)
        switch decision {
        case .allow: store.approve(key: request.caller.key, displayName: request.caller.displayName)
        case .session: sessionApprovals[request.caller.key] = request.caller.agentPID ?? 0
        case .deny: break
        }
        paired = store.all
        for waiter in request.waiters {
            waiter.resume(returning: decision != .deny)
        }
    }

    func revoke(key: String) {
        store.revoke(key: key)
        sessionApprovals.removeValue(forKey: key)
        paired = store.all
    }
}

/// Live permission state, polled while some UI shows it.
@MainActor
final class PermissionsModel: ObservableObject {
    @Published private(set) var accessibility = Permissions.accessibility
    @Published private(set) var screenRecording = Permissions.screenRecording
    /// Set once the user asked for Screen Recording, so the UI can offer a restart.
    @Published var screenRecordingRequested = false

    var allGranted: Bool { accessibility && screenRecording }
    var grantedCount: Int { (accessibility ? 1 : 0) + (screenRecording ? 1 : 0) }

    /// Debug: pretend some permissions are missing, to review the setup window.
    var preview: (accessibility: Bool, screenRecording: Bool)?

    func refresh() {
        let ax = preview?.accessibility ?? Permissions.accessibility
        let sr = preview?.screenRecording ?? Permissions.screenRecording
        if ax != accessibility { accessibility = ax }
        if sr != screenRecording { screenRecording = sr }
    }
}

/// User preferences kept in the helper's defaults.
@MainActor
final class HelperSettings: ObservableObject {
    private let defaults = UserDefaults.standard

    /// Briefly outline windows agents read or capture.
    @Published var showActivityOnScreen: Bool {
        didSet { defaults.set(showActivityOnScreen, forKey: "showActivityOnScreen") }
    }

    init() {
        showActivityOnScreen = defaults.object(forKey: "showActivityOnScreen") as? Bool ?? true
    }
}

/// Refuses requests from stopped agents and feeds the activity log.
struct HelperObserver: RequestObserver {
    let activity: ActivityCenter
    let policy: PolicyStore
    let journal: Journal

    func refusal(for request: RPCRequest, context: RequestContext) async -> RPCError? {
        if await activity.isStopped(context.caller.key) {
            return RPCError(
                code: RPCErrorCode.stoppedByUser,
                message: "The user stopped \(context.caller.displayName) from the macOS Harness menu bar (or with ⌃⌥⌘.). Ask them to resume it before trying again."
            )
        }
        return await PolicyEnforcer.refusal(for: request, store: policy)
    }

    func didHandle(_ request: RPCRequest, context: RequestContext, response: RPCResponse, milliseconds: Int) async {
        await journal.record(request, response: response, caller: context.caller, milliseconds: milliseconds)
        guard let entry = ActivityDescriber.entry(
            for: request, response: response, agentKey: context.caller.key, agentName: context.caller.displayName
        ) else { return }
        await activity.record(entry)
    }
}
