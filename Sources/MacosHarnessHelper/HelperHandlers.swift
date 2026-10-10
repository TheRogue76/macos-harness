import AppKit
import Foundation
import HarnessCore
import HarnessProtocol

/// Lets debug commands open the helper's own UI; set once the UI exists.
@MainActor
final class UIHooks {
    var showPanel: () -> Void = {}
    var showSetup: () -> Void = {}
    var previewMissing: (Bool) -> Void = { _ in }

    func openPanel() { showPanel() }
    func openSetup(previewMissing missing: Bool = false) {
        previewMissing(missing)
        showSetup()
    }
}

/// Wires RPC methods to HarnessCore services.
enum HelperHandlers {
    static func register(
        on router: Router, pairing: PairingCoordinator, activity: ActivityCenter, overlay: OverlayController, ui: UIHooks,
        policy: PolicyStore, journalDirectory: String
    ) {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "unbundled"

        @Sendable func callerInfo(_ context: RequestContext) async -> CallerInfo {
            let paired = await pairing.isApproved(context.caller)
            let stopped = await activity.isStopped(context.caller.key)
            return CallerInfo(context.caller, paired: paired, stopped: stopped)
        }

        router.register(HelloMethod.self) { _, context in
            HelloMethod.Result(
                helperVersion: HarnessVersion.string,
                protocolVersion: HarnessVersion.protocolVersion,
                bundleIdentifier: bundleIdentifier,
                caller: await callerInfo(context)
            )
        }

        router.register(DoctorMethod.self) { _, context in
            DoctorMethod.Result(
                helperVersion: HarnessVersion.string,
                protocolVersion: HarnessVersion.protocolVersion,
                bundleIdentifier: bundleIdentifier,
                bundlePath: Bundle.main.bundlePath,
                helperPID: getpid(),
                macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                permissions: .init(
                    accessibility: Permissions.accessibility,
                    screenRecording: Permissions.screenRecording
                ),
                secureInputEnabled: Permissions.secureInputEnabled,
                caller: await callerInfo(context),
                policy: policy.status,
                journalDirectory: journalDirectory,
                deviceHub: await MainActor.run { SimulatorScreens.deviceHubVersion() }
            )
        }

        router.register(RestrictMethod.self) { params, context in
            RestrictMethod.Result(restrictions: context.connection.restrict(params))
        }

        router.register(AppsMethod.self) { params, context in
            AppsMethod.Result(apps: PolicyEnforcer.visible(
                await AppsService.runningApps(includeBackground: params.includeBackground), store: policy,
                restrictions: context.connection.restrictions
            ))
        }

        router.register(WindowsMethod.self) { params, context in
            let apps: [AppRef]
            if let query = params.app, Target.androidDevice(in: query) != nil {
                return WindowsMethod.Result(windows: [try await AndroidService.window(query)])
            }
            if let query = params.app, Target.simulatorDevice(in: query) != nil {
                return WindowsMethod.Result(windows: [try await TargetResolver.resolve(Target(app: query)).window.info])
            }
            if let query = params.app {
                apps = [try await MainActor.run { try AppResolver.resolve(query) }]
            } else {
                apps = PolicyEnforcer.visible(
                    await AppsService.runningApps(includeBackground: false), store: policy, restrictions: context.connection.restrictions
                ).map {
                    AppRef(name: $0.name, bundleIdentifier: $0.bundleIdentifier, pid: $0.pid)
                }
            }
            var windows: [WindowInfo] = []
            for app in apps {
                windows += ((try? WindowService.windows(of: app)) ?? []).map(\.info)
            }
            return WindowsMethod.Result(windows: windows)
        }

        router.register(SnapshotMethod.self) { params, _ in try await Snapshotter.snapshot(params) }
        router.register(FindMethod.self) { params, _ in try await Snapshotter.find(params) }
        router.register(ScreenshotMethod.self) { params, _ in try await ScreenshotService.capture(params) }
        router.register(MenuMethod.self) { params, _ in try await MenuService.menu(params) }
        @Sendable func actionContext(_ request: RequestContext) -> ActionContext {
            let key = request.caller.key
            return ActionContext(owner: key, ownerName: request.caller.displayName) { await activity.isStopped(key) }
        }
        router.register(ActMethod.self) { params, context in try await ActionService.act(params, context: actionContext(context)) }
        router.register(PointerMethod.self) { params, context in
            try await PointerService.pointer(params, context: actionContext(context))
        }
        router.register(MenuSelectMethod.self) { params, _ in try await AppControl.menuSelect(params) }
        router.register(RecordStartMethod.self) { params, context in
            try await RecordingService.shared.start(params, owner: context.caller.key)
        }
        router.register(RecordStopMethod.self) { params, context in
            RecordStopMethod.Result(recordings: try await RecordingService.shared.stop(id: params.id, owner: context.caller.key))
        }
        router.register(WindowActionMethod.self) { params, _ in try await AppControl.window(params) }
        router.register(LaunchMethod.self) { params, _ in try await AppControl.launch(params) }
        router.register(QuitMethod.self) { params, _ in try await AppControl.quit(params) }
        router.register(WaitMethod.self) { params, _ in try await AppControl.wait(params) }
        router.register(SimulatorMethod.self) { params, _ in try await SimulatorService.run(params) }
        router.register(AndroidMethod.self) { params, _ in try await AndroidControl.run(params) }

        router.register(SpikeMethod.self) { params, context in
            switch params.name {
            case "overlay-demo":
                return SpikeMethod.Result(report: try await overlayDemo(params.arguments, overlay: overlay, activity: activity))
            case "appearance":
                return SpikeMethod.Result(report: await setAppearance(params.arguments.first))
            case "pairing-demo":
                await pairingDemo(pairing: pairing)
                return SpikeMethod.Result(report: "showing a pairing request from a made-up agent; nothing you choose is kept")
            case "press-stop-hotkey":
                RealInput.postCombo(keyCode: 47, flags: [.maskControl, .maskAlternate, .maskCommand], source: CGEventSource(stateID: .hidSystemState))
                return SpikeMethod.Result(report: "posted ⌃⌥⌘.")
            case "stop-all":
                await activity.stopAll()
                return SpikeMethod.Result(report: "stopped all agents; resume from the menu bar panel")
            case "panel":
                await ui.openPanel()
                return SpikeMethod.Result(report: "opened the menu bar panel")
            case "setup":
                await ui.openSetup(previewMissing: params.arguments.first == "missing")
                return SpikeMethod.Result(report: "opened the setup window")
            default:
                return SpikeMethod.Result(
                    report: try await Spikes.run(params.name, arguments: params.arguments, caller: context.caller)
                )
            }
        }
    }

    /// Shows every overlay piece around an app's window, for checking the design.
    @MainActor
    private static func overlayDemo(_ arguments: [String], overlay: OverlayController, activity: ActivityCenter) throws -> String {
        guard let query = arguments.first else {
            throw RPCError(code: RPCErrorCode.invalidParams, message: "usage: overlay-demo <app or window ID>")
        }
        if let id = UInt32(query) {
            overlay.mark(window: id, caption: "Demo · press “Save” · step 14", duration: 6)
            let shown = OnScreenWindow.current(of: id, ignoring: getpid()) != nil
            return "marking window \(id) for 6 seconds; it's \(shown ? "on the screen" : "not on the screen, so nothing shows")"
        }
        let app = try AppResolver.resolve(query)
        let window = try WindowService.resolve(Target(app: query), app: app)
        let frame = window.info.frame
        overlay.mark(window: window.info.id, caption: "Demo · press “Save” · step 14", duration: 6)
        overlay.ripple(at: CGPoint(x: frame.x + frame.width * 0.75, y: frame.y + frame.height * 0.8), in: window.info.id)
        overlay.showHUD(
            agent: "Demo", detail: "\(app.name) · 14 steps · real input off", started: Date().addingTimeInterval(-134),
            pause: {}, stop: { [weak overlay] in overlay?.hideHUD() }
        )
        Task { @MainActor [weak overlay] in
            try? await Task.sleep(for: .seconds(6))
            overlay?.hideHUD()
        }
        return "showing the overlay around \(app.name) window \(window.info.id) for 6 seconds"
    }

    /// Queues a pairing request from a fictional agent so the card can be reviewed.
    /// Whatever the user picks is undone right away.
    @MainActor
    private static func pairingDemo(pairing: PairingCoordinator) {
        let chain = [
            ProcessSnapshot(pid: 1, parentPID: 2, path: "/usr/local/bin/macos-harness", arguments: ["macos-harness", "apps"]),
            ProcessSnapshot(pid: 2, parentPID: 3, path: "/bin/zsh", arguments: ["zsh"], signingIdentifier: "com.apple.zsh", signer: "Apple"),
            ProcessSnapshot(pid: 3, parentPID: 4, path: "/opt/demo/bin/demo-agent", arguments: ["demo-agent"],
                            signingIdentifier: "com.example.demo-agent", teamIdentifier: "DEMO123456", signer: "Example Agents Inc."),
            ProcessSnapshot(pid: 4, parentPID: 1, path: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal",
                            arguments: ["Terminal"], signingIdentifier: "com.apple.Terminal", signer: "Apple"),
        ]
        let caller = CallerIdentity(displayName: "Demo Agent", key: "Demo Agent|DEMO123456|preview", chain: chain, agentPID: 3)
        Task { @MainActor in
            _ = await pairing.requestApproval(for: caller)
            pairing.revoke(key: caller.key)
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(15))
            if let request = pairing.pending.first(where: { $0.caller.key == caller.key }) {
                pairing.resolve(request.id, .deny)
            }
        }
    }

    /// Forces light or dark for the helper's own UI (not the system), for checking both themes.
    @MainActor
    private static func setAppearance(_ name: String?) -> String {
        switch name {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
        return "helper appearance: \(name ?? "system")"
    }
}
