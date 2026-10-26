import Foundation
import HarnessCore
import HarnessHelperCore
import HarnessLinux
import HarnessProtocol

/// Wires RPC methods to what the Linux helper can do: Android targets, seeing desktop apps
/// through AT-SPI, pairing and diagnostics. What desktop apps don't support yet says so.
@MainActor
enum LinuxHandlers {
    static func register(on router: Router, helper: LinuxHelper) {
        let pairing = helper.pairing
        let activity = helper.activity
        let policy = helper.policy
        let journalDirectory = helper.journal.directory
        let bundleIdentifier = helper.variant.bundleIdentifier
        let executable = CommandLine.arguments.first ?? "macos-harness-helper"
        let status = helper.linuxStatus()

        @Sendable func callerInfo(_ context: RequestContext) async -> CallerInfo {
            let paired = await pairing.isApproved(context.caller)
            let stopped = await activity.isStopped(context.caller)
            let instance = await activity.instanceName(for: context.caller)
            return CallerInfo(context.caller, paired: paired, stopped: stopped, instance: instance)
        }

        @Sendable func actionContext(_ request: RequestContext) -> ActionContext {
            let caller = request.caller
            let name = caller.folder.map { "\(caller.displayName) · \($0)" } ?? caller.displayName
            let backgroundOnly = PolicyEnforcer.isBackgroundOnly(store: policy, restrictions: request.connection.restrictions)
            return ActionContext(owner: caller.instanceKey, ownerName: name, backgroundOnly: backgroundOnly) { await activity.isStopped(caller) }
        }

        router.register(HelloMethod.self) { _, context in
            HelloMethod.Result(
                helperVersion: HarnessVersion.string, protocolVersion: HarnessVersion.protocolVersion,
                bundleIdentifier: bundleIdentifier, caller: await callerInfo(context)
            )
        }

        router.register(DoctorMethod.self) { _, context in
            var report = DoctorMethod.Result(
                helperVersion: HarnessVersion.string, protocolVersion: HarnessVersion.protocolVersion,
                bundleIdentifier: bundleIdentifier, bundlePath: executable, helperPID: getpid(),
                macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                permissions: .init(accessibility: false, screenRecording: false), secureInputEnabled: false,
                caller: await callerInfo(context), policy: policy.status, journalDirectory: journalDirectory
            )
            report.linux = status
            report.linux?.permissions = await LinuxPermissions.status()
            if context.connection.restrictions.backgroundOnly == true { report.policy?.backgroundOnly = true }
            return report
        }

        router.register(PermissionsMethod.self) { params, context in
            try AgentClassifier.checkPermissionsChange(params.action, caller: context.caller)
            return try await LinuxPermissions.run(params)
        }

        router.register(RestrictMethod.self) { params, context in
            RestrictMethod.Result(restrictions: context.connection.restrict(params))
        }

        router.register(AndroidMethod.self) { params, context in try await AndroidControl.run(params, context: actionContext(context)) }
        router.register(AppsMethod.self) { params, _ in try await LinuxDesktop.apps(params) }
        router.register(WindowsMethod.self) { params, _ in
            if let query = params.app, Target.androidDevice(in: query) != nil {
                return WindowsMethod.Result(windows: [try await AndroidService.window(query)])
            }
            return try await LinuxDesktop.windows(params)
        }
        router.register(SnapshotMethod.self) { params, context in
            try SnapshotNarrowing.check(params)
            let full = if params.target.androidDevice != nil {
                try await AndroidService.snapshot(params)
            } else {
                try await LinuxDesktop.snapshot(params)
            }
            return await SnapshotNarrowing.narrowed(full, params: params, owner: actionContext(context).owner)
        }
        router.register(FindMethod.self) { params, _ in
            if params.target.androidDevice != nil { return try await AndroidService.find(params) }
            return try await LinuxDesktop.find(params)
        }
        router.register(ReadMethod.self) { params, _ in
            if params.target.androidDevice != nil { return try await AndroidService.read(params) }
            return try await LinuxDesktop.read(params)
        }
        router.register(ScreenshotMethod.self) { params, _ in
            if params.target.androidDevice != nil { return try await AndroidService.screenshot(params) }
            return try await LinuxDesktop.screenshot(params)
        }
        router.register(ActMethod.self) { params, context in
            if params.target.androidDevice != nil { return try await AndroidService.act(params, context: actionContext(context)) }
            return try await LinuxDesktop.act(params, context: actionContext(context))
        }
        router.register(CollectMethod.self) { params, context in
            try CollectService.check(params)
            try android(params.target, "collect")
            return try await AndroidService.collect(params, context: actionContext(context))
        }
        router.register(PointerMethod.self) { params, context in
            if params.target.androidDevice != nil { return try await AndroidService.pointer(params, context: actionContext(context)) }
            return try await LinuxDesktop.pointer(params, context: actionContext(context))
        }
        router.register(WaitMethod.self) { params, _ in
            if params.target.androidDevice != nil { return try await AndroidService.wait(params) }
            return try await LinuxDesktop.wait(params)
        }

        router.register(MenuMethod.self) { params, _ in try await LinuxDesktop.menu(params) }
        router.register(MenuSelectMethod.self) { params, context in try await LinuxDesktop.menuSelect(params, context: actionContext(context)) }
        router.register(WindowActionMethod.self) { _, _ in throw desktopUnsupported("window") }
        router.register(LaunchMethod.self) { params, _ in try await LinuxApps.launch(params) }
        router.register(QuitMethod.self) { params, _ in try await LinuxApps.quit(params) }
        router.register(ClipboardMethod.self) { _, _ in throw desktopUnsupported("clipboard") }
        router.register(RecordStartMethod.self) { _, _ in throw desktopUnsupported("record") }
        router.register(RecordStopMethod.self) { _, _ in throw desktopUnsupported("record") }
        router.register(SimulatorMethod.self) { _, _ in
            throw RPCError(code: RPCErrorCode.failed, message: "iOS Simulators need macOS.")
        }
    }

    /// Refuses a target that isn't an Android device.
    nonisolated static func android(_ target: Target, _ command: String) throws {
        guard target.androidDevice != nil else { throw desktopUnsupported(command) }
    }

    nonisolated static func desktopUnsupported(_ command: String) -> RPCError {
        RPCError(
            code: RPCErrorCode.failed,
            message: "`\(command)` on Linux desktop apps isn't supported yet; apps, windows, launch, quit, snapshot, find, read, wait, menus and element actions work on them, and everything works on Android targets (android:<device>)."
        )
    }
}
