import ArgumentParser
import Foundation
import HarnessClient
import HarnessProtocol

struct Stop: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Stop every agent at once, as the stop shortcut does; they stay stopped until you resume them.",
        discussion: "Bind it to a key in your desktop's keyboard settings where the harness can't add the shortcut itself."
    )

    @OptionGroup var output: OutputOptions

    func run() throws {
        try StopCommands.send(resume: false, json: output.json)
    }
}

struct Resume: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Let agents act again after a stop. Agents can't run this themselves."
    )

    @OptionGroup var output: OutputOptions

    func run() throws {
        try StopCommands.send(resume: true, json: output.json)
    }
}

enum StopCommands {
    static func send(resume: Bool, json: Bool) throws {
        try reportingErrors(json: json) {
            let result = try HarnessConnection.open().call(StopMethod.self, .init(resume: resume), timeout: 10)
            if json { try Output.json(result) } else { print(result.performed) }
        }
    }
}
