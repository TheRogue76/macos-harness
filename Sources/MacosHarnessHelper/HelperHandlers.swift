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

        router.register(SpikeMethod.self) { params, context in
            SpikeMethod.Result(
                report: try await Spikes.run(params.name, arguments: params.arguments, caller: context.caller)
            )
        }
    }
}
