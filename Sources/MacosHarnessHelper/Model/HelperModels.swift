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
    /// Agent sessions the user stopped individually, by instance key (or an agent's key, from
    /// before sessions were told apart), with their display names.
    @Published private(set) var stoppedAgents: [String: String] = [:]
    @Published private(set) var allStopped = false
    @Published private(set) var thumbnails: [UInt32: NSImage] = [:]

    /// Called for every recorded entry (the on-screen highlight listens).
    var onEntry: ((ActivityEntry) -> Void)?
    private var tracker = SessionTracker()
    private var instanceNames = InstanceNames()

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
        let ended = stoppedAgents.keys.filter { InstanceNames.pid(of: $0) != nil && !Self.isRunning($0) }
        if !ended.isEmpty {
            ended.forEach { stoppedAgents.removeValue(forKey: $0) }
            saveStops()
        }
    }

    /// Whether a session, by its instance key, is stopped.
    func isStopped(_ key: String) -> Bool {
        allStopped || stoppedAgents[key] != nil
    }

    /// Whether a caller is stopped: everyone is, its session is, or it descends from a stopped
    /// session's process.
    func isStopped(_ caller: CallerIdentity) -> Bool {
        allStopped || StopRules.covers(caller, stopped: stoppedAgents.keys)
    }

    func stop(key: String, name: String) {
        stoppedAgents[key] = name
        saveStops()
        Task { await WindowClaims.shared.release(owner: key) }
    }

    /// Stops every active session of the agent a session belongs to.
    func stopSessions(of kindKey: String) {
        for session in sessions where session.kindKey == kindKey {
            stoppedAgents[session.agentKey] = fullName(of: session)
            Task { await WindowClaims.shared.release(owner: session.agentKey) }
        }
        saveStops()
    }

    /// The name telling a caller's process apart from other sessions of its agent: its folder,
    /// numbered when two share one.
    func instanceName(for caller: CallerIdentity) -> String {
        instanceNames.name(for: caller.instanceKey, folder: caller.folder, isRunning: Self.isRunning)
    }

    /// "Claude Code", or "Claude Code · macos-harness" while another session of the same agent is
    /// active.
    func label(agentKey: String, agentName: String, instance: String?) -> String {
        guard let instance, !instance.isEmpty else { return agentName }
        let kind = InstanceNames.kindKey(of: agentKey)
        let others = sessions.contains { $0.kindKey == kind && $0.agentKey != agentKey }
        return others ? "\(agentName) · \(instance)" : agentName
    }

    /// The agent's name with the session's folder, e.g. "Claude Code · macos-harness".
    func fullName(of session: AgentSession) -> String {
        guard let instance = session.instance, !instance.isEmpty else { return session.agentName }
        return "\(session.agentName) · \(instance)"
    }

    /// How many active sessions the agent a session belongs to has.
    func sessionCount(of kindKey: String) -> Int {
        sessions.filter { $0.kindKey == kindKey }.count
    }

    /// Whether the agent process in an instance key still runs; true for keys without one.
    nonisolated static func isRunning(_ instanceKey: String) -> Bool {
        guard let pid = InstanceNames.pid(of: instanceKey) else { return true }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    func resume(key: String) {
        stoppedAgents.removeValue(forKey: key)
        saveStops()
    }

    /// Stops every agent, including ones that haven't shown up yet, until the user resumes.
    func stopAll() {
        allStopped = true
        for session in sessions { stoppedAgents[session.agentKey] = fullName(of: session) }
        saveStops()
        Task { await WindowClaims.shared.releaseAll() }
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
    /// "This session only" approvals, by instance key: valid while the agent process that asked
    /// is alive, and only for that process.
    private var sessionApprovals: Set<String> = []
    /// Approve every caller without asking, for CI runs where nobody can answer.
    let approvesEveryone: Bool

    init(store: PairingStore, approvesEveryone: Bool = false) {
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

    nonisolated func isPaired(_ caller: CallerIdentity) async -> Bool {
        await isApproved(caller)
    }

    nonisolated func requestApproval(for caller: CallerIdentity) async -> Bool {
        await ask(caller)
    }

    func isApproved(_ caller: CallerIdentity) -> Bool {
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
            onNewRequest?()
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.approvalTimeout))
                self?.resolve(request.id, .deny)
            }
        }
    }

    /// How long a pairing prompt waits for the user before the request is refused.
    static let approvalTimeout: Double = 120

    func resolve(_ id: Request.ID, _ decision: Decision) {
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

    func revoke(key: String) {
        store.revoke(key: key)
        sessionApprovals = sessionApprovals.filter { InstanceNames.kindKey(of: $0) != key }
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
        if await activity.isStopped(context.caller) {
            return RPCError(
                code: RPCErrorCode.stoppedByUser,
                message: "The user stopped \(context.caller.displayName) from the macOS Harness menu bar (or with ⌃⌥⌘.). Ask them to resume it before trying again."
            )
        }
        return await PolicyEnforcer.refusal(for: request, store: policy, restrictions: context.connection.restrictions)
    }

    func didHandle(_ request: RPCRequest, context: RequestContext, response: RPCResponse, milliseconds: Int) async {
        await journal.record(request, response: response, caller: context.caller, milliseconds: milliseconds)
        if let window = response.result?["window"]?["id"]?.numberValue {
            await WindowClaims.shared.renew(UInt32(window), owner: context.caller.instanceKey)
        }
        let instance = await activity.instanceName(for: context.caller)
        guard let entry = ActivityDescriber.entry(
            for: request, response: response, agentKey: context.caller.instanceKey, agentName: context.caller.displayName,
            instance: instance
        ) else { return }
        await activity.record(entry)
    }
}
