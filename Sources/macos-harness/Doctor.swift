import ArgumentParser
import Foundation
import HarnessClient
import HarnessProtocol

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check that the helper runs, has its permissions, and knows who is calling."
    )

    @OptionGroup var output: OutputOptions

    func run() throws {
        try reportingErrors {
            let connection = try HarnessConnection.open()
            let report = try connection.call(DoctorMethod.self, .init(), timeout: 10)
            if output.json {
                try Output.json(report)
            } else {
                print(render(report, socketPath: connection.location.socketPath))
            }
            if !Self.isHealthy(report) {
                throw ExitCode.failure
            }
        }
    }

    static func isHealthy(_ report: DoctorMethod.Result) -> Bool {
        report.helperVersion == HarnessVersion.string
            && report.protocolVersion == HarnessVersion.protocolVersion
            && report.permissions.accessibility
            && report.permissions.screenRecording
    }

    func render(_ report: DoctorMethod.Result, socketPath: String) -> String {
        func line(_ ok: Bool, _ text: String) -> String { "\(ok ? "✓" : "✗") \(text)" }
        let appName = (report.bundlePath as NSString).lastPathComponent
        let versionsMatch = report.helperVersion == HarnessVersion.string
            && report.protocolVersion == HarnessVersion.protocolVersion
        let menuHint = "click the macOS Harness icon in the menu bar"
        let chain = report.caller.chain.map(\.name).joined(separator: " ← ")
        return [
            "\(appName) (pid \(report.helperPID)) on macOS \(report.macOSVersion)",
            "  socket: \(socketPath)",
            line(versionsMatch, versionsMatch
                ? "Helper and CLI versions match (\(report.helperVersion))"
                : "Helper is \(report.helperVersion), CLI is \(HarnessVersion.string): restart the helper"),
            line(report.permissions.accessibility, report.permissions.accessibility
                ? "Accessibility granted"
                : "Accessibility missing: \(menuHint) > Grant Accessibility…"),
            line(report.permissions.screenRecording, report.permissions.screenRecording
                ? "Screen Recording granted"
                : "Screen Recording missing: \(menuHint) > Grant Screen Recording…, then Restart Helper"),
            report.secureInputEnabled
                ? "! Secure Input is on (a password field has focus); typing will be blocked until it's off"
                : "✓ Secure Input off",
            report.caller.paired
                ? "✓ Caller: \(report.caller.displayName) (paired)"
                : "- Caller: \(report.caller.displayName) (not paired yet; you'll be asked on first use)",
            "  chain: \(chain)",
        ].joined(separator: "\n")
    }
}
