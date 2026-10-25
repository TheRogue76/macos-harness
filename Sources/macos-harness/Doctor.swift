import ArgumentParser
import Foundation
import HarnessClient
import HarnessProtocol

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check that the helper runs, has its permissions, and knows who is calling."
    )

    @Flag(help: "Write a bug report to a text file instead: versions, this check, recent errors and the latest journal session (no typed text or screenshots).")
    var report = false
    @Option(help: "Where --report writes (default: macos-harness-report-<time>.txt here).")
    var out: String?
    @Flag(help: "Keep window titles and element labels in the --report (left out by default).")
    var includeTitles = false

    @OptionGroup var output: OutputOptions

    func run() throws {
        if report { return try writeReport() }
        try reportingErrors(json: output.json) {
            let connection = try HarnessConnection.open()
            let report = try connection.call(DoctorMethod.self, .init(), timeout: 10)
            if output.json {
                try Output.json(report)
            } else {
                print(Render.doctor(report, socketPath: connection.location.socketPath))
            }
            if !Self.isHealthy(report) {
                throw ExitCode.failure
            }
        }
    }

    func writeReport() throws {
        var doctorText: String
        do {
            let connection = try HarnessConnection.open()
            let report = try connection.call(DoctorMethod.self, .init(), timeout: 10)
            doctorText = Render.doctor(report, socketPath: connection.location.socketPath)
        } catch {
            doctorText = "The helper didn't answer: \(error)"
        }
        let variant = HelperLocator.locate()?.variant ?? .release
        let directory = HarnessPaths.journalDirectory(for: variant)
        let sessions = JournalReader.sessions(in: directory).prefix(3).map { session in
            (session: session, entries: (try? JournalReader.entries(of: session.id, in: directory)) ?? [])
        }
        let text = BugReport.text(.init(
            generated: Date(), macOS: ProcessInfo.processInfo.operatingSystemVersionString, architecture: Self.architecture,
            cli: "\(HarnessVersion.string) (\(SetupPlan.cliPath()))", xcode: Self.xcodeVersion(), doctor: doctorText,
            sessions: Array(sessions), includeTitles: includeTitles
        ))
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let path = URL(fileURLWithPath: out ?? "macos-harness-report-\(formatter.string(from: Date())).txt").standardizedFileURL.path
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        print("Wrote \(path). Look it over before attaching it to an issue.")
    }

    static var architecture: String {
        #if arch(arm64) && os(Linux)
        "aarch64"
        #elseif arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }

    static func xcodeVersion() -> String? {
        guard let output = try? SetupPlan.run("/usr/bin/xcodebuild", ["-version"]) else { return nil }
        return output.split(separator: "\n").map(String.init).joined(separator: ", ")
    }

    static func isHealthy(_ report: DoctorMethod.Result) -> Bool {
        Render.isHealthy(report)
    }
}
