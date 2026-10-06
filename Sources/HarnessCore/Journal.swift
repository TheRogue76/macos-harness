import Foundation
import HarnessProtocol

/// Writes every agent request to a JSON Lines file per agent session, and deletes old sessions.
public actor Journal {
    public let directory: String
    /// Quiet time after which an agent's next request starts a new session.
    public static let idleTimeout: TimeInterval = 120
    private var sessions: [String: (id: String, last: Date)] = [:]

    public init(directory: String) {
        self.directory = directory
    }

    /// Records one handled request; bookkeeping calls (hello, doctor, spikes) are skipped.
    public func record(
        _ request: RPCRequest, response: RPCResponse, caller: CallerIdentity, milliseconds: Int, at time: Date = Date()
    ) {
        guard !Self.skipped.contains(request.method) else { return }
        let session = sessionID(for: caller, at: time)
        let entry = Self.entry(
            for: request, response: response, caller: caller, session: session, milliseconds: milliseconds, at: time
        )
        append(entry)
    }

    /// Deletes session files last written more than `days` days ago.
    public func prune(olderThan days: Int = 30, now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        for file in files where file.hasSuffix(".jsonl") {
            let path = (directory as NSString).appendingPathComponent(file)
            guard let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
                  modified < cutoff else { continue }
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    static let skipped: Set<String> = [HelloMethod.name, DoctorMethod.name, SpikeMethod.name]

    func sessionID(for caller: CallerIdentity, at time: Date) -> String {
        if let current = sessions[caller.key], time.timeIntervalSince(current.last) < Self.idleTimeout {
            sessions[caller.key] = (current.id, time)
            return current.id
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let id = "\(formatter.string(from: time))-\(Self.slug(caller.displayName))"
        sessions[caller.key] = (id, time)
        return id
    }

    static func slug(_ name: String) -> String {
        let words = name.lowercased().split { !$0.isLetter && !$0.isNumber }
        return words.isEmpty ? "agent" : words.joined(separator: "-")
    }

    private func append(_ entry: JournalEntry) {
        guard var line = try? JournalEntry.lineEncoder.encode(entry) else { return }
        line.append(0x0A)
        let manager = FileManager.default
        try? manager.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let path = (directory as NSString).appendingPathComponent("\(entry.session).jsonl")
        if !manager.fileExists(atPath: path) {
            manager.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
    }

    /// The journal entry for a request and its response, with typed and set text left out.
    public static func entry(
        for request: RPCRequest, response: RPCResponse, caller: CallerIdentity, session: String, milliseconds: Int,
        at time: Date
    ) -> JournalEntry {
        let params = request.params
        let result = response.result
        var entry = JournalEntry(
            time: time, session: session, agent: caller.displayName, agentKey: caller.key, method: request.method,
            app: result?["app"]?["name"]?.stringValue ?? PolicyEnforcer.targetApp(of: request),
            window: (result?["window"]?["id"]?.numberValue ?? params?["target"]?["window"]?.numberValue).map { UInt32($0) },
            via: result?["via"]?.stringValue, error: response.error, milliseconds: milliseconds
        )
        entry.selector = (params?["element"]).flatMap { try? $0.decode(as: ElementSelector.self) }
        if let node = result?["element"], let ref = node["ref"]?.stringValue, let role = node["role"]?.stringValue {
            entry.element = .init(ref: ref, role: role, label: node["label"]?.stringValue, identifier: node["identifier"]?.stringValue)
        }
        if params?["diff"]?.boolValue != false, let changes = result?["changes"]?.arrayValue {
            entry.changes = changes.count + Int(result?["moreChanges"]?.numberValue ?? 0)
        }
        if let notices = result?["notices"]?.arrayValue, !notices.isEmpty {
            entry.notices = notices.compactMap { $0["kind"]?.stringValue }
        }

        switch request.method {
        case ActMethod.name:
            let action = params?["action"]?.stringValue
            entry.action = action
            if action == ElementAction.type.rawValue || action == ElementAction.setValue.rawValue {
                entry.redactedLength = params?["value"]?.stringValue?.count
            } else {
                entry.value = params?["value"]?.stringValue
            }
        case PointerMethod.name, WindowActionMethod.name:
            entry.action = params?["action"]?.stringValue
        case MenuSelectMethod.name, MenuMethod.name:
            entry.value = params?["path"]?.arrayValue?.compactMap(\.stringValue).joined(separator: " › ")
        case FindMethod.name:
            entry.selector = ElementSelector(
                text: params?["text"]?.stringValue, role: params?["role"]?.stringValue,
                identifier: params?["identifier"]?.stringValue, exact: params?["exact"]?.boolValue ?? false
            )
        default:
            break
        }
        return entry
    }
}
