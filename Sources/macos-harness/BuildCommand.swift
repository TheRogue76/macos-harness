import ArgumentParser
import Foundation
import HarnessClient
import HarnessProtocol

struct BuildCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "build",
        abstract: "Build an app with xcodebuild for the iOS Simulator or this Mac, and optionally run it.",
        discussion: """
            Finds the .xcworkspace or .xcodeproj in this folder unless you name one. Builds for the iOS Simulator when the \
            scheme has one, and for this Mac otherwise or with --mac: natively when the scheme supports macOS, as Mac \
            Catalyst when that's how it runs on a Mac. The full log goes to ~/Library/Logs/macos-harness/builds.
            """
    )

    @Option(help: "The .xcodeproj to build.")
    var project: String?
    @Option(help: "The .xcworkspace to build.")
    var workspace: String?
    @Option(help: "The scheme (default: the only one).")
    var scheme: String?
    @Option(help: "Build configuration.")
    var configuration = "Debug"
    @Option(help: "Build for this simulator (UDID, name or booted); default: any simulator.")
    var device: String?
    @Option(name: .customLong("sim"), help: .hidden)
    var deprecatedSim: String?
    @Flag(help: "Build for this Mac (natively or as Mac Catalyst) even when the scheme has a simulator.")
    var mac = false
    @Flag(
        name: .customLong("run"),
        help: "After a successful build, run the app: install and launch it on --device, or on this Mac quit any running copy and launch the new build."
    )
    var runAfter = false
    @Flag(help: "Print xcodebuild's output as it goes.")
    var verbose = false
    @OptionGroup var output: OutputOptions

    func validate() throws {
        if mac, simulator != nil { throw ValidationError("--mac builds for this Mac and --device names a simulator; use one or the other.") }
    }

    private var simulator: String? { device ?? deprecatedSim }

    func run() throws {
        try reportingErrors(json: output.json) {
            let verbose = verbose && !output.json
            if deprecatedSim != nil { Output.note("--sim is now --device; the old name goes away in 2.0.") }
            let plan = try AppBuilder.plan(
                .init(project: project, workspace: workspace, scheme: scheme, configuration: configuration, device: simulator, mac: mac)
            )
            if runAfter, !plan.canRun {
                throw RPCError(
                    code: RPCErrorCode.invalidParams,
                    message: "\(plan.scheme) builds for the iOS Simulator, so --run needs --device to say which one (or --mac to build it for this Mac)."
                )
            }
            if !output.json { Output.note("Building \(plan.scheme) for \(plan.platform.displayName)…") }
            let outcome = try AppBuilder.build(plan) { line in
                if verbose { print(line) }
            }
            var launched: SimulatorMethod.Result?
            var macRun: AppBuilder.MacRun?
            if runAfter, outcome.succeeded {
                let connection = try HarnessConnection.openAnnouncingPairing()
                if outcome.platform.isMac {
                    macRun = try AppBuilder.runOnMac(outcome, caller: connection)
                } else if let app = outcome.appPath, let bundle = outcome.bundleIdentifier, let device = outcome.device {
                    _ = try connection.call(SimulatorMethod.self, .init(action: .install, device: device.udid, path: app), timeout: 360)
                    launched = try connection.call(SimulatorMethod.self, .init(action: .launch, device: device.udid, bundleIdentifier: bundle), timeout: 180)
                }
            }
            if output.json {
                try Output.json(BuildReport(build: outcome, launch: launched, macLaunch: macRun?.launch, replaced: macRun?.replaced))
            } else {
                print(Self.describe(outcome))
                if let launched { print(Render.simulator(launched)) }
                if let macRun { print(Render.macRun(macRun)) }
            }
            if !outcome.succeeded { throw ExitCode.failure }
        }
    }

    static func describe(_ outcome: AppBuilder.Outcome) -> String {
        guard outcome.succeeded else {
            return (["Build of \(outcome.scheme) failed after \(outcome.seconds) s:"] + outcome.errors.map { "  " + $0 } + ["Log: \(outcome.logPath)"])
                .joined(separator: "\n")
        }
        let warnings = outcome.warnings > 0 ? ", \(outcome.warnings) warnings" : ""
        let bundle = outcome.bundleIdentifier.map { " (\($0))" } ?? ""
        return "Built \(outcome.scheme) for \(outcome.platform.displayName) in \(outcome.seconds) s\(warnings): \(outcome.appPath ?? "?")\(bundle)"
    }
}

/// A build and, with --run, the launch that followed.
struct BuildReport: Encodable {
    var build: AppBuilder.Outcome
    /// The launch on a simulator.
    var launch: SimulatorMethod.Result?
    /// The launch on this Mac: the app's pid and windows.
    var macLaunch: LaunchMethod.Result?
    /// Running copies of the app quit before the launch on this Mac.
    var replaced: [AppRef]?
}
