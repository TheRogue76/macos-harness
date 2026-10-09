import ArgumentParser
import Foundation
import HarnessClient
import HarnessProtocol

struct BuildCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "build",
        abstract: "Build an iOS app for the simulator with xcodebuild, and optionally install and launch it.",
        discussion: "Finds the .xcworkspace or .xcodeproj in this folder unless you name one. The full log goes to ~/Library/Logs/macos-harness/builds."
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
    var sim: String?
    @Flag(name: .customLong("run"), help: "Install the app on --sim and launch it after a successful build.")
    var runAfter = false
    @Flag(help: "Print xcodebuild's output as it goes.")
    var verbose = false
    @OptionGroup var output: OutputOptions

    func validate() throws {
        if runAfter, sim == nil { throw ValidationError("--run needs --sim to say which simulator to run on.") }
    }

    func run() throws {
        try reportingErrors(json: output.json) {
            let verbose = verbose && !output.json
            if !output.json { Output.note("Building…") }
            let outcome = try AppBuilder.build(
                .init(project: project, workspace: workspace, scheme: scheme, configuration: configuration, device: sim)
            ) { line in
                if verbose { print(line) }
            }
            var launched: SimulatorMethod.Result?
            if runAfter, outcome.succeeded, let app = outcome.appPath, let bundle = outcome.bundleIdentifier, let device = outcome.device {
                let connection = try HarnessConnection.openAnnouncingPairing()
                _ = try connection.call(SimulatorMethod.self, .init(action: .install, device: device.udid, path: app), timeout: 360)
                launched = try connection.call(SimulatorMethod.self, .init(action: .launch, device: device.udid, bundleIdentifier: bundle), timeout: 180)
            }
            if output.json {
                try Output.json(BuildReport(build: outcome, launch: launched))
            } else {
                print(Self.describe(outcome))
                if let launched { print(Render.simulator(launched)) }
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
        return "Built \(outcome.scheme) in \(outcome.seconds) s\(warnings): \(outcome.appPath ?? "?")\(bundle)"
    }
}

/// A build and, with --run, the launch that followed.
struct BuildReport: Encodable {
    var build: AppBuilder.Outcome
    var launch: SimulatorMethod.Result?
}
