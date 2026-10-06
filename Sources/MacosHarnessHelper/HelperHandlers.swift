import Foundation
import HarnessCore
import HarnessProtocol

/// Wires RPC methods to HarnessCore services.
enum HelperHandlers {
    static func register(on router: Router, pairings: PairingStore) {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "unbundled"

        router.register(HelloMethod.self) { _, context in
            HelloMethod.Result(
                helperVersion: HarnessVersion.string,
                protocolVersion: HarnessVersion.protocolVersion,
                bundleIdentifier: bundleIdentifier,
                caller: CallerInfo(context.caller, paired: pairings.isPaired(context.caller.key))
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
                caller: CallerInfo(context.caller, paired: pairings.isPaired(context.caller.key))
            )
        }

        router.register(AppsMethod.self) { params, _ in
            AppsMethod.Result(apps: await AppsService.runningApps(includeBackground: params.includeBackground))
        }

        router.register(WindowsMethod.self) { params, _ in
            let apps: [AppRef]
            if let query = params.app {
                apps = [try await MainActor.run { try AppResolver.resolve(query) }]
            } else {
                apps = await MainActor.run {
                    AppsService.runningApps(includeBackground: false).map {
                        AppRef(name: $0.name, bundleIdentifier: $0.bundleIdentifier, pid: $0.pid)
                    }
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

        router.register(SpikeMethod.self) { params, context in
            SpikeMethod.Result(
                report: try await Spikes.run(params.name, arguments: params.arguments, caller: context.caller)
            )
        }
    }
}
