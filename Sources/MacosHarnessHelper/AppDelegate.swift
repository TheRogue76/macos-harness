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
        hotkey = StopHotkey { [weak self] in
            self?.activity.stopAll()
            statusItem.show()
        }

        if !permissions.allGranted {
            onboarding.show()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
    }

    /// Outlines the window an agent just read or captured, if the user wants that.
    private func showOnScreen(_ entry: ActivityEntry) {
        guard settings.showActivityOnScreen, !entry.failed, let frame = entry.windowFrame,
              ["reading", "screenshot"].contains(entry.kind),
              entry.app != variant.appName else { return }  // never outline our own panels
        overlay.highlight(windowFrame: frame, title: entry.agentName, detail: entry.summary)
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
