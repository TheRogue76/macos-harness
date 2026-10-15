import Foundation
import HarnessProtocol

/// The text `doctor --report` writes for a bug report: versions, the doctor check, recent errors
/// and the latest journal session, with no typed text, no screenshots and, unless asked, no
/// window titles or labels.
public enum BugReport {
    /// What goes into a report, gathered by the caller.
    public struct Inputs {
        public var generated: Date
        public var macOS: String
        public var architecture: String
        public var cli: String
        public var xcode: String?
        public var doctor: String
        public var sessions: [(session: JournalSession, entries: [JournalEntry])]
        public var includeTitles: Bool

        public init(
            generated: Date, macOS: String, architecture: String, cli: String, xcode: String?, doctor: String,
            sessions: [(session: JournalSession, entries: [JournalEntry])], includeTitles: Bool
        ) {
            self.generated = generated
            self.macOS = macOS
            self.architecture = architecture
            self.cli = cli
            self.xcode = xcode
            self.doctor = doctor
            self.sessions = sessions
            self.includeTitles = includeTitles
        }
    }

    /// Most error lines and latest-session lines a report holds.
    static let maxErrors = 30
    static let maxEntries = 60

    /// The report's text.
    public static func text(_ inputs: Inputs) -> String {
        let keep = inputs.includeTitles
        let clean: (String) -> String = { keep ? $0 : withoutTitles($0) }
        let titles: String = inputs.includeTitles
            ? "Window titles and labels are included."
            : "Window titles and labels are left out (shown as “…”); typed text and screenshots never are in it."
        let xcode: String = inputs.xcode ?? "Xcode not found"
        var lines: [String] = [
            "macOS Harness bug report, \(ISO8601DateFormatter().string(from: inputs.generated))",
            titles,
            "",
            "## Versions",
            "macOS \(inputs.macOS) (\(inputs.architecture))",
            "CLI \(inputs.cli)",
            xcode,
            "",
            "## Doctor",
            clean(inputs.doctor),
            "",
            "## Recent errors",
        ]
        var errors: [(agent: String, entry: JournalEntry)] = []
        for session in inputs.sessions {
            for entry in session.entries where entry.error != nil { errors.append((session.session.agent, entry)) }
        }
        errors.sort { $0.entry.time > $1.entry.time }
        if errors.isEmpty {
            lines.append("None in the last \(inputs.sessions.count) sessions.")
        } else {
            for error in errors.prefix(maxErrors) { lines.append("[\(error.agent)] " + clean(Render.journalEntry(error.entry))) }
        }
        lines += ["", "## Latest session"]
        if let latest = inputs.sessions.first {
            let session = latest.session
            lines.append("\(session.id): \(session.agent), \(session.entries) requests, \(session.failures) failed, apps: \(session.apps.joined(separator: ", "))")
            let entries = latest.entries.suffix(maxEntries)
            if latest.entries.count > entries.count { lines.append("(the last \(entries.count) of \(latest.entries.count))") }
            lines += entries.map { clean(Render.journalEntry($0)) }
        } else {
            lines.append("No journal sessions.")
        }
        return withoutHome(lines.joined(separator: "\n") + "\n")
    }

    /// `text` with the user's home folder written as ~.
    static func withoutHome(_ text: String, home: String = HarnessPaths.homeDirectory) -> String {
        home.count > 1 ? text.replacingOccurrences(of: home, with: "~") : text
    }

    /// `text` with what's in typographic quotes (window titles, element labels) blanked.
    static func withoutTitles(_ text: String) -> String {
        text.replacingOccurrences(of: "“[^”]*”", with: "“…”", options: .regularExpression)
            .replacingOccurrences(of: "\"[^\"\\n]*\"", with: "\"…\"", options: .regularExpression)
    }
}
