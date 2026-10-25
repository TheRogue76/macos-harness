import AppKit
import Darwin
import HarnessCore
import HarnessMac
import HarnessProtocol
import Observation

/// What agents have been doing, and which ones the user has stopped.
@MainActor
@Observable
final class ActivityCenter {
    private(set) var sessions: [AgentSession] = []
    private(set) var recent: [ActivityEntry] = []
    /// Agent sessions the user stopped individually, by instance key (or an agent's key, from
    /// before sessions were told apart), with their display names.
    private(set) var stoppedAgents: [String: String] = [:]
    private(set) var allStopped = false
    private(set) var thumbnails: [UInt32: NSImage] = [:]
    /// Who has the mouse and keyboard and who waits for them.
    private(set) var turns = RealInput.Turns()

    /// Called for every recorded entry (the on-screen highlight listens).
    @ObservationIgnored var onEntry: ((ActivityEntry) -> Void)?
    @ObservationIgnored private var tracker = SessionTracker()
    @ObservationIgnored private var instanceNames = InstanceNames()

    /// Where stops are saved, so they survive a helper restart.
    @ObservationIgnored private let defaults = UserDefaults.standard

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
        Task { await refreshTurns() }
        onEntry?(entry)
    }

    /// Empties the recent activity list; sessions and the journal are left alone.
    func clearRecent() {
        tracker.clearRecent()
        recent = []
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

    /// Reads who has the mouse and keyboard and who waits for them.
    func refreshTurns() async {
        let now = await RealInput.turns()
        if now != turns { turns = now }
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
@Observable
final class PairingCoordinator: PairingGate {
    enum Decision { case allow, session, deny }

    struct Request: Identifiable {
        let id = UUID()
        let caller: CallerIdentity
        var waiters: [CheckedContinuation<Bool, Never>]
    }

    private(set) var pending: [Request] = []
    private(set) var paired: [PairingStore.Pairing] = []
    @ObservationIgnored var onNewRequest: (() -> Void)?

    @ObservationIgnored private let store: PairingStore
    /// "This session only" approvals, by instance key: valid while the agent process that asked
    /// is alive, and only for that process.
    @ObservationIgnored private var sessionApprovals: Set<String> = []
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

    /// The key of the made-up agent the debug commands show, which no real caller has.
    static let demoKey = "Demo Agent|DEMO123456|preview"

    /// Pairs the made-up Demo Agent, so the settings' list and its Revoke can be reviewed.
    func addDemoPairing() {
        store.approve(key: Self.demoKey, displayName: "Demo Agent")
        paired = store.all
    }
}

/// Live permission state, polled while some UI shows it.
@MainActor
@Observable
final class PermissionsModel {
    private(set) var accessibility = Permissions.accessibility
    private(set) var screenRecording = Permissions.screenRecording
    /// Set once the user asked for Screen Recording, so the UI can offer a restart.
    var screenRecordingRequested = false

    var allGranted: Bool { accessibility && screenRecording }
    var grantedCount: Int { (accessibility ? 1 : 0) + (screenRecording ? 1 : 0) }

    /// Debug: pretend some permissions are missing, to review the setup window.
    @ObservationIgnored var preview: (accessibility: Bool, screenRecording: Bool)?

    func refresh() {
        let ax = preview?.accessibility ?? Permissions.accessibility
        let sr = preview?.screenRecording ?? Permissions.screenRecording
        if ax != accessibility { accessibility = ax }
        if sr != screenRecording { screenRecording = sr }
    }
}

/// The user's settings as the panel shows and changes them, saved through the settings store.
@MainActor
@Observable
final class HelperSettings {
    @ObservationIgnored private let store: SettingsStore

    /// Clicks and scrolls may go to a window in the background; off, they always use the real mouse.
    var backgroundRoute: Bool {
        didSet { store.backgroundRoute = backgroundRoute }
    }

    /// The outline and tab on the window an agent acts in.
    var windowOutline: Bool {
        didSet { store.windowOutline = windowOutline }
    }

    /// The outline also on windows agents only read or capture.
    var outlineReads: Bool {
        didSet { store.outlineReads = outlineReads }
    }

    /// The "is driving" panel and the ripple where an agent clicks.
    var drivingPanel: Bool {
        didSet { store.drivingPanel = drivingPanel }
    }

    init(store: SettingsStore = .shared) {
        self.store = store
        backgroundRoute = store.backgroundRoute
        windowOutline = store.windowOutline
        outlineReads = store.outlineReads
        drivingPanel = store.drivingPanel
    }
}

/// Which page the menu bar panel shows: the dashboard, or the settings.
@MainActor
@Observable
final class PanelNavigation {
    var showingSettings = false
}

/// Refuses requests from stopped agents and feeds the activity log; the panel and on-screen
/// feedback update after the reply, so agents don't wait for them.
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
        if let window = response.result?["window"].flatMap({ try? $0.decode(as: WindowInfo.self) }) {
            await WindowClaims.shared.renew(WindowClaims.key(for: window), owner: context.caller.instanceKey)
        }
        let caller = context.caller
        Task { @MainActor [activity] in
            let instance = activity.instanceName(for: caller)
            guard let entry = ActivityDescriber.entry(
                for: request, response: response, agentKey: caller.instanceKey, agentName: caller.displayName, instance: instance
            ) else { return }
            activity.record(entry)
        }
    }
}
