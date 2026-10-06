import ArgumentParser
import Foundation
import HarnessClient
import HarnessProtocol

struct JournalCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "journal",
        abstract: "List agent sessions from the journal, or show one session's requests (typed text is never recorded)."
    )

    @Argument(help: "A session ID from the list, or `last` for the newest.")
    var session: String?

    @Option(help: "Most sessions to list.")
    var limit = 20

    @OptionGroup var output: OutputOptions

    func run() throws {
        let variant = HelperLocator.locate()?.variant ?? .release
        let directory = HarnessPaths.journalDirectory(for: variant)
        try reportingErrors(json: output.json) {
            guard let session else {
                let sessions = Array(JournalReader.sessions(in: directory).prefix(limit))
                output.json ? try Output.json(sessions) : print(Render.journalSessions(sessions))
                return
            }
            let id = session == "last" ? JournalReader.sessions(in: directory).first?.id : session
            guard let id, let entries = try? JournalReader.entries(of: id, in: directory) else {
                throw RPCError(code: RPCErrorCode.failed, message: "No journal session \(session) in \(directory).")
            }
            output.json ? try Output.json(entries) : print(entries.map(Render.journalEntry).joined(separator: "\n"))
        }
    }
}
