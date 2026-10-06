import ArgumentParser
import HarnessClient
import HarnessProtocol

struct Spike: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run an M0 experiment inside the helper.",
        shouldDisplay: false
    )

    @Argument(help: "Spike name; `list` shows them.")
    var name: String

    @Argument(parsing: .captureForPassthrough)
    var arguments: [String] = []

    func run() throws {
        try reportingErrors {
            let connection = try HarnessConnection.openAnnouncingPairing()
            print(try connection.call(SpikeMethod.self, .init(name: name, arguments: arguments)).report)
        }
    }
}
