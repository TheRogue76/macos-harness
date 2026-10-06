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

    static func isHealthy(_ report: DoctorMethod.Result) -> Bool {
        Render.isHealthy(report)
    }
}
