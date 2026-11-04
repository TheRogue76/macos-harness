#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import Glibc
import HarnessCore
import HarnessHelperCore
import HarnessLinux
import HarnessProtocol

/// The Control Tower panel, a GTK app the helper starts when the tray icon is clicked. It
/// reads the helper's state and acts for the user; the helper answers it only when the call
/// comes from a panel process it started itself, carrying the token it gave that panel, so
/// agents can't stop, resume or pair through it.
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

    /// The app ID the helper's autostart entry is named by.
    var appID: String { "io.github.therogue76.MacosHarness\(helper.variant == .dev ? "Dev" : "")" }

    /// Whether the open panel has been put in place, so it can show itself.
    private(set) var placed = false
    /// The panel processes the helper started.
    private var panels: Set<Int32> = []
    /// Whether the panel app should open the setup window.
    private(set) var setupWanted = false
    /// The marker app the helper started, which draws window markers on KDE and Sway.
    private var marker: Int32?
    /// What's waiting for the marker app to ask for it.
    private var pending = TowerMarkMethod.Result()
    /// The marker app's call waiting for something to show.
    private var markWaiter: (id: Int, continuation: CheckedContinuation<TowerMarkMethod.Result, Never>)?
    private var waiters = 0

    /// Whether a panel app the helper started is still running.
    var isRunning: Bool {
        panels = panels.filter { kill($0, 0) == 0 }
        return !panels.isEmpty
    }

    /// Starts the panel app, which opens the panel, or only the setup window with `setup`.
    private func launch(setup: Bool) {
        let variant = helper.variant
        var environment = [
            "MACOS_HARNESS_TOWER_TOKEN": token,
            "MACOS_HARNESS_TOWER_SOCKET": HarnessPaths.socketPath(for: variant),
            "MACOS_HARNESS_VARIANT": variant.rawValue,
        ]
        if setup { environment["MACOS_HARNESS_TOWER_SETUP"] = "1" }
        if let started = try? Tools.launch(executable, environment: environment) { panels.insert(started) }
    }

    /// The marker app's app ID.
    var markerAppID: String { "\(appID).Marker" }

    /// The marker app, for the driving panel and the markers the compositor can't draw itself;
    /// nil when the panel app isn't installed.
    var overlay: WindowMarks.Overlay? {
        guard isInstalled else { return nil }
        return WindowMarks.Overlay(
            appID: markerAppID, send: { mark in await self.send(mark) }, drive: { driving in await self.send(driving) }
        )
    }

    /// Hands the marker app a marker, starting it first when it isn't running.
    func send(_ mark: TowerMarkMethod.Mark) {
        startMarker()
        pending.mark = mark
        deliver()
    }

    /// Hands the marker app the driving panel, starting it first when it isn't running.
    func send(_ driving: TowerMarkMethod.Driving) {
        startMarker()
        pending.driving = driving
        deliver()
    }

    /// Starts the marker app when it isn't running, so the first marker or driving panel needn't
    /// wait for it.
    func startMarker() {
        if marker.map({ kill($0, 0) != 0 }) ?? true {
            marker = try? Tools.launch(executable, environment: [
                "MACOS_HARNESS_TOWER_TOKEN": token,
                "MACOS_HARNESS_TOWER_SOCKET": HarnessPaths.socketPath(for: helper.variant),
                "MACOS_HARNESS_VARIANT": helper.variant.rawValue,
                "MACOS_HARNESS_TOWER_MARKER": "1",
                "GTK_A11Y": "none",
            ])
        }
    }

    private func deliver() {
        guard let waiter = markWaiter else { return }
        markWaiter = nil
        let ready = pending
        pending = TowerMarkMethod.Result()
        waiter.continuation.resume(returning: ready)
    }

    /// What the marker app should show next, or nothing after `timeout`.
    func next(_ params: TowerMarkMethod.Params, caller: CallerIdentity, timeout: Duration = .seconds(20)) async throws -> TowerMarkMethod.Result {
        try check(params.token, caller: caller, from: marker.map { [$0] } ?? [])
        if pending.mark != nil || pending.driving != nil {
            let ready = pending
            pending = TowerMarkMethod.Result()
            return ready
        }
        markWaiter?.continuation.resume(returning: TowerMarkMethod.Result())
        waiters += 1
        let id = waiters
        return await withCheckedContinuation { continuation in
            markWaiter = (id, continuation)
            Task {
                try? await Task.sleep(for: timeout)
                if let waiter = self.markWaiter, waiter.id == id {
                    self.markWaiter = nil
                    waiter.continuation.resume(returning: TowerMarkMethod.Result())
                }
            }
        }
    }

    /// Opens the setup window, as the Mac's helper does when a permission is missing: in the
    /// running panel app, or in a new one that shows only it.
    func openSetup() {
        guard isInstalled else { return }
        if isRunning {
            setupWanted = true
        } else {
            launch(setup: true)
        }
    }

    /// Opens the panel, or brings it forward when it's open, and puts it under the tray icon at
    /// `x`, `y` (0, 0 when the panel didn't say where it was clicked).
    func open(near x: Int32 = 0, _ y: Int32 = 0) {
        let variant = helper.variant
        placed = false
        launch(setup: false)
        let prefix = "io.github.therogue76.MacosHarness\(variant == .dev ? "Dev" : "").Tower"
        Task {
            _ = await Tools.place(appIDPrefix: prefix, near: CGPoint(x: Double(x), y: Double(y)))
            self.placed = true
        }
    }

    /// Refuses a call unless it comes from a panel the helper started (by the connection's peer
    /// pid and its executable) with the token it was given. The token alone isn't enough: a
    /// process's environment can be read by others of the same user.
    func check(_ given: String, caller: CallerIdentity, from started: Set<Int32>? = nil) throws {
        let peer = caller.chain.first
        let resolved = URL(fileURLWithPath: executable).resolvingSymlinksInPath().path
        guard given == token, let peer, (started ?? panels).contains(peer.pid),
              URL(fileURLWithPath: peer.path).resolvingSymlinksInPath().path == resolved else {
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
            requests: requests, paired: paired, missing: helper.trayPermissions.filter { $0.state == .missing }, stopShortcut: shortcut,
            placed: placed, startsAtLogin: StartAtLogin.isOn(appID: appID), permissions: helper.trayPermissions, showSetup: setupWanted
        )
    }

    func act(_ params: TowerActionMethod.Params, caller: CallerIdentity) async throws {
        if let marker, caller.chain.first?.pid == marker, [.stop, .stopAll].contains(params.action) {
            try check(params.token, caller: caller, from: [marker])
        } else {
            try check(params.token, caller: caller)
        }
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
        case .startAtLogin, .dontStartAtLogin:
            let helperPath = URL(fileURLWithPath: CommandLine.arguments.first ?? "").resolvingSymlinksInPath().path
            try StartAtLogin.set(params.action == .startAtLogin, appID: appID, appName: helper.variant.appName, executable: helperPath)
        case .grant:
            if let item = params.key { await helper.setUpPermissions(item: item) }
        case .setupShown:
            setupWanted = false
        case .showJournal:
            _ = try? Tools.launch("/usr/bin/xdg-open", arguments: [helper.journal.directory])
        case .quit:
            Task {
                try? await Task.sleep(for: .milliseconds(200))
                exit(0)
            }
        }
    }
}
