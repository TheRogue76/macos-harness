#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import HarnessCore
import HarnessProtocol
import Observation

/// What agents have been doing, and which ones the user has stopped.
@MainActor
@Observable
package final class ActivityCenter {
    package private(set) var sessions: [AgentSession] = []
    package private(set) var recent: [ActivityEntry] = []
    /// Agent sessions the user stopped individually, by instance key (or an agent's key, from
    /// before sessions were told apart), with their display names.
    package private(set) var stoppedAgents: [String: String] = [:]
    package private(set) var allStopped = false
    /// Who has the mouse and keyboard and who waits for them.
    package private(set) var turns = InputTurns()

    /// Called for every recorded entry (the on-screen highlight listens).
    @ObservationIgnored package var onEntry: ((ActivityEntry) -> Void)?
    @ObservationIgnored private var tracker = SessionTracker()
    @ObservationIgnored private var instanceNames = InstanceNames()

    /// Where stops are saved, so they survive a helper restart.
    @ObservationIgnored private let defaults: UserDefaults

    package init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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

    package func record(_ entry: ActivityEntry) {
        tracker.record(entry)
        refresh()
        Task { await refreshTurns() }
        onEntry?(entry)
    }

    /// Empties the recent activity list; sessions and the journal are left alone.
    package func clearRecent() {
        tracker.clearRecent()
        recent = []
    }

    package func refresh() {
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
    package func isStopped(_ key: String) -> Bool {
        allStopped || stoppedAgents[key] != nil
    }

    /// Whether a caller is stopped: everyone is, its session is, or it descends from a stopped
    /// session's process.
    package func isStopped(_ caller: CallerIdentity) -> Bool {
        allStopped || StopRules.covers(caller, stopped: stoppedAgents.keys)
    }

    package func stop(key: String, name: String) {
        stoppedAgents[key] = name
        saveStops()
        Task { await WindowClaims.shared.release(owner: key) }
    }

    /// Stops every active session of the agent a session belongs to.
    package func stopSessions(of kindKey: String) {
        for session in sessions where session.kindKey == kindKey {
            stoppedAgents[session.agentKey] = fullName(of: session)
            Task { await WindowClaims.shared.release(owner: session.agentKey) }
        }
        saveStops()
    }

    /// The name telling a caller's process apart from other sessions of its agent: its folder,
    /// numbered when two share one.
    package func instanceName(for caller: CallerIdentity) -> String {
        instanceNames.name(for: caller.instanceKey, folder: caller.folder, isRunning: Self.isRunning)
    }

    /// "Claude Code", or "Claude Code · macos-harness" while another session of the same agent is
    /// active.
    package func label(agentKey: String, agentName: String, instance: String?) -> String {
        guard let instance, !instance.isEmpty else { return agentName }
        let kind = InstanceNames.kindKey(of: agentKey)
        let others = sessions.contains { $0.kindKey == kind && $0.agentKey != agentKey }
        return others ? "\(agentName) · \(instance)" : agentName
    }

    /// The agent's name with the session's folder, e.g. "Claude Code · macos-harness".
    package func fullName(of session: AgentSession) -> String {
        guard let instance = session.instance, !instance.isEmpty else { return session.agentName }
        return "\(session.agentName) · \(instance)"
    }

    /// How many active sessions the agent a session belongs to has.
    package func sessionCount(of kindKey: String) -> Int {
        sessions.filter { $0.kindKey == kindKey }.count
    }

    /// Whether the agent process in an instance key still runs; true for keys without one.
    package nonisolated static func isRunning(_ instanceKey: String) -> Bool {
        guard let pid = InstanceNames.pid(of: instanceKey) else { return true }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    package func resume(key: String) {
        stoppedAgents.removeValue(forKey: key)
        saveStops()
    }

    /// Stops every agent, including ones that haven't shown up yet, until the user resumes.
    package func stopAll() {
        allStopped = true
        for session in sessions { stoppedAgents[session.agentKey] = fullName(of: session) }
        saveStops()
        Task { await WindowClaims.shared.releaseAll() }
    }

    package func resumeAll() {
        allStopped = false
        stoppedAgents = [:]
        saveStops()
    }

    /// Reads who has the mouse and keyboard and who waits for them.
    package func refreshTurns() async {
        let status = await InputLease.shared.status()
        let now = InputTurns(holder: status.holder, waiting: status.waiting)
        if now != turns { turns = now }
    }
}
