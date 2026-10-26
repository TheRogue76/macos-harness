import Foundation
import HarnessCore
import HarnessHelperCore
import HarnessLinux
import HarnessProtocol

/// The Control Tower panel, a GTK app the helper starts when the tray icon is clicked. It
/// reads the helper's state and acts for the user with a token only it is given, so agents
/// can't stop, resume or pair through it.
@MainActor
final class Tower {
    unowned let helper: LinuxHelper
    let token = UUID().uuidString + UUID().uuidString

    init(helper: LinuxHelper) {
        self.helper = helper
    }

    /// The panel app, next to the helper.
    var executable: String {
        let folder = URL(fileURLWithPath: CommandLine.arguments.first ?? "").resolvingSymlinksInPath().deletingLastPathComponent().path
        return "\(folder)/macos-harness-tower"
    }

    var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: executable) }

    /// Opens the panel, or brings it forward when it's open.
    func open() {
        let variant = helper.variant
        try? Tools.launch(executable, environment: [
            "MACOS_HARNESS_TOWER_TOKEN": token,
            "MACOS_HARNESS_TOWER_SOCKET": HarnessPaths.socketPath(for: variant),
            "MACOS_HARNESS_VARIANT": variant.rawValue,
        ])
    }

    func check(_ given: String) throws {
        guard given == token else {
            throw RPCError(code: RPCErrorCode.failed, message: "Only the Control Tower panel the helper started may do that.")
        }
    }

    func state(shortcut: String?) -> TowerState {
        let activity = helper.activity
        let now = Date()
        let sessions = activity.sessions.sorted { $0.lastActivity > $1.lastActivity }.map { session in
            TowerState.Session(
                key: session.agentKey, name: activity.fullName(of: session), app: session.lastApp, steps: session.steps,
                lastStep: session.last.shortSummary, quietFor: now.timeIntervalSince(session.lastActivity),
                runningFor: now.timeIntervalSince(session.startedAt), stopped: activity.isStopped(session.agentKey) || activity.allStopped
            )
        }
        let stopped = activity.stoppedAgents.filter { key, _ in !activity.sessions.contains { $0.agentKey == key } }
            .map { TowerState.Stopped(key: $0.key, name: $0.value) }.sorted { $0.name < $1.name }
        let recent = activity.recent.prefix(5).map {
            TowerState.Activity(agent: $0.agentName, summary: $0.shortSummary, secondsAgo: now.timeIntervalSince($0.date))
        }
        let requests = helper.pairing.pending.map { request in
            TowerState.Request(
                id: request.id.uuidString, name: request.caller.displayName, folder: request.caller.folder,
                chain: request.caller.chain.map(\.name), command: request.caller.command
            )
        }
        let paired = helper.pairing.paired.map { TowerState.Paired(key: $0.key, name: $0.displayName, allowedAt: $0.approvedAt) }
        return TowerState(
            appName: helper.variant.appName, allStopped: activity.allStopped, sessions: sessions, stopped: stopped, recent: Array(recent),
            requests: requests, paired: paired, missing: helper.trayPermissions.filter { $0.state == .missing }, stopShortcut: shortcut
        )
    }

    func act(_ params: TowerActionMethod.Params) async throws {
        try check(params.token)
        let activity = helper.activity
        let pairing = helper.pairing
        switch params.action {
        case .stopAll: activity.stopAll()
        case .resumeAll: activity.resumeAll()
        case .stop:
            guard let key = params.key, let session = activity.sessions.first(where: { $0.agentKey == key }) else { return }
            activity.stop(key: key, name: activity.fullName(of: session))
        case .resume:
            if let key = params.key { activity.resume(key: key) }
        case .allow, .allowSession, .deny:
            guard let id = params.key.flatMap(UUID.init(uuidString:)) else { return }
            pairing.resolve(id, params.action == .allow ? .allow : params.action == .allowSession ? .session : .deny)
        case .revoke:
            if let key = params.key { pairing.revoke(key: key) }
        case .clearRecent:
            activity.clearRecent()
        case .setUp:
            await helper.setUpPermissions()
        }
    }
}
