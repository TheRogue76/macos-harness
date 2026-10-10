import Foundation
import HarnessProtocol

/// One request an agent made, as the menu bar shows it.
public struct ActivityEntry: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var date: Date
    public var agentKey: String
    public var agentName: String
    public var method: String
    /// What happened, e.g. "read Calculator · 31 elements".
    public var summary: String
    /// The summary without element refs, e.g. "pressed button “Save”" for "pressed button “Save” (d4)".
    public var shortSummary: String {
        summary.replacingOccurrences(of: #" \([a-z]{1,3}[0-9]+\)"#, with: "", options: .regularExpression)
    }
    /// Short label for how it was done: "reading", "screenshot", …
    public var kind: String
    public var app: String?
    public var windowID: UInt32?
    /// Global frame of the window involved, for the on-screen highlight.
    public var windowFrame: Rect?
    public var failed: Bool
    /// The agent changed something (pressed, typed, launched…), as opposed to reading.
    public var isAction: Bool
    /// Where it acted on screen, for the ripple.
    public var screenPoint: Point?

    public init(
        id: UUID = UUID(), date: Date, agentKey: String, agentName: String, method: String, summary: String,
        kind: String, app: String? = nil, windowID: UInt32? = nil, windowFrame: Rect? = nil, failed: Bool = false,
        isAction: Bool = false, screenPoint: Point? = nil
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
        self.isAction = isAction
        self.screenPoint = screenPoint
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
        let simulator = window?["simulator"]?["name"]?.stringValue.map { "\($0) (simulator)" }
            ?? window?["android"]?["name"]?.stringValue.map { "\($0) (Android)" }
        let windowApp = window?["app"]?["name"]?.stringValue
        let targetApp = params?["target"]?["app"]?.stringValue ?? params?["app"]?.stringValue
        let app = simulator ?? windowApp ?? targetApp

        let summary: String
        let kind: String
        var isAction = false
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
            let what = params?["extras"]?.boolValue == true ? "menu bar extras" : "menu"
            summary = "read \(app ?? "an app") \(what)" + (path.isEmpty ? "" : " › " + path.joined(separator: " › "))
            kind = "reading menus"
        case ActMethod.name, MenuSelectMethod.name, WindowActionMethod.name, PointerMethod.name:
            summary = result?["performed"]?.stringValue
                ?? "\(params?["action"]?.stringValue ?? request.method) in \(app ?? "an app")"
            kind = result?["via"]?.stringValue ?? "AX"
            isAction = true
        case LaunchMethod.name:
            let name = result?["app"]?["name"]?.stringValue ?? params?["app"]?.stringValue ?? "an app"
            summary = result?["alreadyRunning"]?.boolValue == true ? "found \(name) already running" : "launched \(name)"
            kind = "launch"
            isAction = true
        case QuitMethod.name:
            summary = result?["message"]?.stringValue ?? "quit \(params?["app"]?.stringValue ?? "an app")"
            kind = "quit"
            isAction = true
        case WaitMethod.name:
            let element = params?["element"]
            let quotedText: String? = element?["text"]?.stringValue.map { "“\($0)”" }
            let names: [String?] = [quotedText, element?["ref"]?.stringValue, element?["role"]?.stringValue, element?["identifier"]?.stringValue]
            let what = names.compactMap { $0 }.first ?? "an element"
            let gone = params?["gone"]?.boolValue == true ? " to go away" : ""
            let satisfied = result?["satisfied"]?.boolValue == false ? " (timed out)" : ""
            summary = "waited for \(what)\(gone) in \(app ?? "an app")\(satisfied)"
            kind = "waiting"
        case RecordStartMethod.name:
            summary = "started recording \(app ?? "an app")"
            kind = "recording"
        case RecordStopMethod.name:
            let count = result?["recordings"]?.arrayValue?.count ?? 0
            summary = "stopped \(count) recording\(count == 1 ? "" : "s")"
            kind = "recording"
        case SimulatorMethod.name:
            let action = params?["action"]?.stringValue ?? "?"
            summary = result?["performed"]?.stringValue ?? "simulator \(action)"
            kind = "simulator"
            isAction = action != SimulatorAction.list.rawValue
        case AndroidMethod.name:
            let action = params?["action"]?.stringValue ?? "?"
            summary = result?["performed"]?.stringValue ?? "android \(action)"
            kind = "android"
            isAction = action != AndroidAction.list.rawValue
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
            failed: failed,
            isAction: isAction,
            screenPoint: result?["screenPoint"].flatMap { try? $0.decode(as: Point.self) }
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
