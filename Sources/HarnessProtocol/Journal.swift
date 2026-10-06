import Foundation

/// One request in the journal: what an agent asked for and what came of it. Text that agents type
/// or set is never recorded, only its length.
public struct JournalEntry: Codable, Equatable, Sendable {
    public var time: Date
    public var session: String
    public var agent: String
    public var agentKey: String
    public var method: String
    public var app: String?
    public var window: UInt32?
    /// The act, pointer or window action, e.g. `press` or `drag`.
    public var action: String?
    /// How the agent named the element.
    public var selector: ElementSelector?
    /// What the selector resolved to.
    public var element: Element?
    /// A key combination, menu path or search text; nil for typed and set text.
    public var value: String?
    /// Length of the typed or set text that wasn't recorded.
    public var redactedLength: Int?
    /// `AX`, `background keys` or `real input`.
    public var via: String?
    public var changes: Int?
    public var notices: [String]?
    public var error: RPCError?
    public var milliseconds: Int

    public struct Element: Codable, Equatable, Sendable {
        public var ref: String
        public var role: String
        public var label: String?
        public var identifier: String?

        public init(ref: String, role: String, label: String?, identifier: String?) {
            self.ref = ref
            self.role = role
            self.label = label
            self.identifier = identifier
        }
    }

    public init(
        time: Date, session: String, agent: String, agentKey: String, method: String, app: String? = nil,
        window: UInt32? = nil, action: String? = nil, selector: ElementSelector? = nil, element: Element? = nil,
        value: String? = nil, redactedLength: Int? = nil, via: String? = nil, changes: Int? = nil,
        notices: [String]? = nil, error: RPCError? = nil, milliseconds: Int
    ) {
        self.time = time
        self.session = session
        self.agent = agent
        self.agentKey = agentKey
        self.method = method
        self.app = app
        self.window = window
        self.action = action
        self.selector = selector
        self.element = element
        self.value = value
        self.redactedLength = redactedLength
        self.via = via
        self.changes = changes
        self.notices = notices
        self.error = error
        self.milliseconds = milliseconds
    }

    /// The encoder for journal lines: one compact JSON object per line.
    public static var lineEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static var lineDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// One agent session's journal file.
public struct JournalSession: Codable, Equatable, Sendable {
    public var id: String
    public var agent: String
    public var started: Date
    public var ended: Date
    public var entries: Int
    public var apps: [String]
    public var failures: Int

    public init(id: String, agent: String, started: Date, ended: Date, entries: Int, apps: [String], failures: Int) {
        self.id = id
        self.agent = agent
        self.started = started
        self.ended = ended
        self.entries = entries
        self.apps = apps
        self.failures = failures
    }
}

/// Reads journal files.
public enum JournalReader {
    /// The sessions in `directory`, newest first.
    public static func sessions(in directory: String) -> [JournalSession] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return files.filter { $0.hasSuffix(".jsonl") }.sorted(by: >).compactMap { file in
            let id = String(file.dropLast(".jsonl".count))
            let entries = (try? self.entries(of: id, in: directory)) ?? []
            guard let first = entries.first, let last = entries.last else { return nil }
            var apps: [String] = []
            for app in entries.compactMap(\.app) where !apps.contains(app) { apps.append(app) }
            return JournalSession(
                id: id, agent: first.agent, started: first.time, ended: last.time, entries: entries.count,
                apps: apps, failures: entries.filter { $0.error != nil }.count
            )
        }
    }

    /// The entries of session `id`, oldest first.
    public static func entries(of id: String, in directory: String) throws -> [JournalEntry] {
        let path = (directory as NSString).appendingPathComponent("\(id).jsonl")
        let text = try String(contentsOfFile: path, encoding: .utf8)
        let decoder = JournalEntry.lineDecoder
        return text.split(separator: "\n").compactMap { try? decoder.decode(JournalEntry.self, from: Data($0.utf8)) }
    }
}
