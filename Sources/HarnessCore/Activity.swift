import Foundation
import HarnessProtocol

extension JSONValue {
    public subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let string) = self { return string }
        return nil
    }

    public var numberValue: Double? {
        if case .number(let number) = self { return number }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let bool) = self { return bool }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let array) = self { return array }
        return nil
    }
}

/// One request an agent made, as the menu bar shows it.
public struct ActivityEntry: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var date: Date
    public var agentKey: String
    public var agentName: String
    public var method: String
    /// What happened, e.g. "read Calculator · 31 elements".
    public var summary: String
    /// Short label for how it was done: "reading", "screenshot", …
    public var kind: String
    public var app: String?
    public var windowID: UInt32?
    /// Global frame of the window involved, for the on-screen highlight.
    public var windowFrame: Rect?
    public var failed: Bool

    public init(
        id: UUID = UUID(), date: Date, agentKey: String, agentName: String, method: String, summary: String,
        kind: String, app: String? = nil, windowID: UInt32? = nil, windowFrame: Rect? = nil, failed: Bool = false
    ) {
        self.id = id
        self.date = date
        self.agentKey = agentKey
        self.agentName = agentName
        self.method = method
        self.summary = summary
        self.kind = kind
        self.app = app
        self.windowID = windowID
        self.windowFrame = windowFrame
        self.failed = failed
    }
}

/// Turns a request and its response into an `ActivityEntry`. Returns nil for bookkeeping
/// calls (hello, doctor) that shouldn't show up as agent activity.
public enum ActivityDescriber {
    public static func entry(
        for request: RPCRequest, response: RPCResponse, agentKey: String, agentName: String, date: Date = Date()
    ) -> ActivityEntry? {
        let params = request.params
        let result = response.result
        let window = result?["window"]
        let windowApp = window?["app"]?["name"]?.stringValue
        let targetApp = params?["target"]?["app"]?.stringValue ?? params?["app"]?.stringValue
        let app = windowApp ?? targetApp

        let summary: String
        let kind: String
        switch request.method {
        case HelloMethod.name, DoctorMethod.name:
            return nil
        case AppsMethod.name:
            summary = "listed running apps"
            kind = "listing"
        case WindowsMethod.name:
            summary = targetApp.map { "listed windows of \($0)" } ?? "listed all windows"
            kind = "listing"
        case SnapshotMethod.name:
            if let root = params?["root"]?.stringValue {
                summary = "expanded \(root) in \(app ?? "an app")"
            } else {
                let shown = result?["shownCount"]?.numberValue.map { " · \(Int($0)) elements" } ?? ""
                summary = "read \(app ?? "an app")\(shown)"
            }
            kind = "reading"
        case FindMethod.name:
            let what = params?["text"]?.stringValue.map { "“\($0)”" }
                ?? params?["role"]?.stringValue ?? params?["identifier"]?.stringValue ?? "elements"
            let count = result?["matches"]?.arrayValue?.count
            summary = "found \(count.map { "\($0) × " } ?? "")\(what) in \(app ?? "an app")"
            kind = "reading"
        case ScreenshotMethod.name:
            var text = "screenshot of \(app ?? "an app")"
            if let element = params?["element"]?.stringValue { text += " · \(element)" }
            if params?["labels"]?.boolValue == true { text += " (labeled)" }
            summary = text
            kind = "screenshot"
        case MenuMethod.name:
            let path = params?["path"]?.arrayValue?.compactMap(\.stringValue) ?? []
            summary = "read \(app ?? "an app") menu" + (path.isEmpty ? "" : " › " + path.joined(separator: " › "))
            kind = "reading menus"
        case SpikeMethod.name:
            summary = "ran spike \(params?["name"]?.stringValue ?? "?")"
            kind = "spike"
        default:
            summary = request.method
            kind = request.method
        }

        let failed = response.error != nil
        return ActivityEntry(
            date: date, agentKey: agentKey, agentName: agentName, method: request.method,
            summary: failed ? "\(summary) (failed)" : summary, kind: failed ? "failed" : kind, app: app,
            windowID: window?["id"]?.numberValue.map { UInt32($0) },
            windowFrame: window?["frame"].flatMap { try? $0.decode(as: Rect.self) },
            failed: failed
        )
    }
}

/// An agent's run of activity, from its first request until it goes quiet.
public struct AgentSession: Sendable, Equatable, Identifiable {
    public var id: String { agentKey }
    public var agentKey: String
    public var agentName: String
    public var startedAt: Date
    public var lastActivity: Date
    public var steps: Int
    public var last: ActivityEntry
    /// The most recent window the agent touched, for the card's thumbnail.
    public var lastWindowID: UInt32?
    public var lastApp: String?
}

/// Groups activity into per-agent sessions; a session ends after `idleTimeout` of quiet.
public struct SessionTracker: Sendable {
    public var idleTimeout: TimeInterval
    public private(set) var sessions: [String: AgentSession] = [:]
    public private(set) var recent: [ActivityEntry] = []
    public var recentLimit = 50

    public init(idleTimeout: TimeInterval = 120) {
        self.idleTimeout = idleTimeout
    }

    public mutating func record(_ entry: ActivityEntry) {
        recent.insert(entry, at: 0)
        if recent.count > recentLimit { recent.removeLast(recent.count - recentLimit) }

        if var session = sessions[entry.agentKey], entry.date.timeIntervalSince(session.lastActivity) <= idleTimeout {
            session.steps += 1
            session.lastActivity = entry.date
            session.last = entry
            let sameApp = entry.app == nil || entry.app == session.lastApp
            session.lastWindowID = entry.windowID ?? (sameApp ? session.lastWindowID : nil)
            session.lastApp = entry.app ?? session.lastApp
            sessions[entry.agentKey] = session
        } else {
            sessions[entry.agentKey] = AgentSession(
                agentKey: entry.agentKey, agentName: entry.agentName, startedAt: entry.date,
                lastActivity: entry.date, steps: 1, last: entry, lastWindowID: entry.windowID, lastApp: entry.app
            )
        }
    }

    /// Sessions still active at `now`, most recent first.
    public func active(at now: Date) -> [AgentSession] {
        sessions.values
            .filter { now.timeIntervalSince($0.lastActivity) <= idleTimeout }
            .sorted { $0.lastActivity > $1.lastActivity }
    }

    /// Forgets sessions that have gone quiet.
    public mutating func expire(at now: Date) {
        sessions = sessions.filter { now.timeIntervalSince($0.value.lastActivity) <= idleTimeout }
    }
}
