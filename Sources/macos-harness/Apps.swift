import ArgumentParser
import Foundation
import HarnessClient
import HarnessProtocol

struct Apps: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List running apps.")

    @Flag(name: .long, help: "Include menu bar agents and background processes.")
    var all = false

    @OptionGroup var output: OutputOptions

    func run() throws {
        try reportingErrors {
            let connection = try HarnessConnection.openAnnouncingPairing()
            let result = try connection.call(AppsMethod.self, .init(includeBackground: all))
            if output.json {
                try Output.json(result)
                return
            }
            for app in result.apps {
                var details = ["pid \(app.pid)", "\(app.windowCount) window\(app.windowCount == 1 ? "" : "s")"]
                if app.active { details.append("frontmost") }
                if app.hidden { details.append("hidden") }
                if app.activationPolicy != "regular" { details.append(app.activationPolicy) }
                let identifier = app.bundleIdentifier.map { " [\($0)]" } ?? ""
                print("\(app.name)\(identifier): \(details.joined(separator: ", "))")
            }
        }
    }
}
