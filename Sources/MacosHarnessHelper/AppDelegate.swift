import AppKit
import HarnessCore
import HarnessProtocol
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let log = Logger(subsystem: "io.github.therogue76.macos-harness", category: "helper")
    private let variant = HarnessVariant(bundleIdentifier: Bundle.main.bundleIdentifier ?? "") ?? .dev
    private let activity = ActivityCenter()
    private let pairing = PairingCoordinator(store: PairingStore())
    private let permissions = PermissionsModel()
    private let settings = HelperSettings()
    private let overlay = OverlayController()
    private var server: SocketServer?
    private var statusItem: StatusItemController?
    private var onboarding: OnboardingWindowController?
    private var hotkey: StopHotkey?
    private let hooks = UIHooks()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let router = Router(gate: pairing, observer: HelperObserver(activity: activity))
        HelperHandlers.register(on: router, pairing: pairing, activity: activity, overlay: overlay, ui: hooks)

        let server = SocketServer(path: HarnessPaths.socketPath(for: variant), router: router)
        do {
            try server.start()
        } catch {
            log.error("could not start: \(String(describing: error), privacy: .public)")
            let alert = NSAlert()
            alert.messageText = "\(variant.appName) couldn't start"
            alert.informativeText = String(describing: error)
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        self.server = server

        let onboarding = OnboardingWindowController(permissions: permissions, appName: variant.appName, restart: Self.restart)
        self.onboarding = onboarding
        let view = ControlTowerView(
            activity: activity, pairing: pairing, permissions: permissions, settings: settings,
            title: variant.appName,
            actions: TowerActions(
                openSetup: { onboarding.show() },
                restart: Self.restart,
                quit: { NSApp.terminate(nil) }
            )
        )
        let statusItem = StatusItemController(view: view, activity: activity, pairing: pairing, permissions: permissions)
        self.statusItem = statusItem
        hooks.showPanel = { statusItem.show() }
        hooks.showSetup = { onboarding.show() }
        hooks.previewMissing = { [permissions] missing in
            permissions.preview = missing ? (accessibility: false, screenRecording: true) : nil
            permissions.refresh()
        }

        activity.onEntry = { [weak self] entry in self?.showOnScreen(entry) }
        // Mark where real input is about to land, before the cursor moves.
        let overlay = self.overlay
        let activity = self.activity
        RealInputHooks.shared.willAct = { point, description, owner, ownerName in
            await MainActor.run {
                overlay.ripple(at: point)
                // Pause/Stop here abort the gesture in progress: the session checks between steps.
                overlay.showHUD(
                    agent: ownerName, detail: description + " · real input", started: Date(),
                    pause: { activity.stop(key: owner, name: ownerName) },
                    stop: { activity.stopAll() }
                )
            }
            try? await Task.sleep(for: .milliseconds(180))
        }
        hotkey = StopHotkey { [weak self] in
            self?.activity.stopAll()
            self?.overlay.hideHUD()
            statusItem.show(activate: false)
        }

        if !permissions.allGranted {
            onboarding.show()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
    }

    private var hudTask: Task<Void, Never>?

    /// Outlines the window an agent just touched; for actions, also a ripple and the driving panel.
    private func showOnScreen(_ entry: ActivityEntry) {
        guard !entry.failed, entry.app != variant.appName else { return }  // never outline our own panels
        let session = activity.sessions.first { $0.agentKey == entry.agentKey }
        if entry.isAction {
            if let point = entry.screenPoint {
                overlay.ripple(at: CGPoint(x: point.x, y: point.y))
            }
            if let frame = entry.windowFrame {
                overlay.highlight(windowFrame: frame, title: "\(entry.agentName) · step \(session?.steps ?? 1)", detail: entry.summary)
            }
            showDrivingPanel(for: entry, session: session)
        } else if settings.showActivityOnScreen, let frame = entry.windowFrame, ["reading", "screenshot"].contains(entry.kind) {
            overlay.highlight(windowFrame: frame, title: entry.agentName, detail: entry.summary)
        }
    }

    /// "<agent> is driving" with Pause (stop this agent) and Stop (stop everyone),
    /// shown while an agent acts and for a few seconds after.
    private func showDrivingPanel(for entry: ActivityEntry, session: AgentSession?) {
        let key = entry.agentKey
        let name = entry.agentName
        let steps = session?.steps ?? 1
        overlay.showHUD(
            agent: name,
            detail: "\(entry.app ?? "an app") · \(steps) step\(steps == 1 ? "" : "s") · \(entry.kind)",
            started: session?.startedAt ?? entry.date,
            pause: { [weak self] in
                self?.activity.stop(key: key, name: name)
                self?.overlay.hideHUD()
            },
            stop: { [weak self] in
                self?.activity.stopAll()
                self?.overlay.hideHUD()
            }
        )
        hudTask?.cancel()
        hudTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            if !Task.isCancelled { self?.overlay.hideHUD() }
        }
    }

    /// Relaunches through LaunchServices so the helper stays responsible for its own permissions.
    static func restart() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }
}
