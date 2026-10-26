import Foundation

/// What the Control Tower panel shows, read by the Linux panel app. Only the panel the helper
/// started may call it: it holds the token the helper gave it.
public enum TowerStateMethod: RPCMethod {
    public static let name = "tower.state"
    public static let requiresPairing = false

    public struct Params: Codable, Sendable {
        public var token: String

        public init(token: String) {
            self.token = token
        }
    }

    public typealias Result = TowerState
}

/// Something the user did in the panel: stop or resume agents, answer a pairing request,
/// revoke a pairing, clear the recent list or set up permissions. Only the panel the helper
/// started may call it, so agents can't do these things.
public enum TowerActionMethod: RPCMethod {
    public static let name = "tower.act"
    public static let requiresPairing = false

    public enum Action: String, Codable, Sendable {
        case stopAll, resumeAll, stop, resume, allow, allowSession, deny, revoke, clearRecent, setUp
        case startAtLogin, dontStartAtLogin, showJournal, quit
        /// Asks for one permission (the key is its id), showing the desktop's own dialog.
        case grant
        /// Says the setup window the helper asked for is open.
        case setupShown
    }

    public struct Params: Codable, Sendable {
        public var token: String
        public var action: Action
        /// The session, pairing request or pairing it's for.
        public var key: String?

        public init(token: String, action: Action, key: String? = nil) {
            self.token = token
            self.action = action
            self.key = key
        }
    }

    public struct Result: Codable, Sendable {
        public init() {}
    }
}

/// Everything the Control Tower panel shows at one moment.
public struct TowerState: Codable, Sendable, Equatable {
    public struct Session: Codable, Sendable, Equatable {
        public var key: String
        public var name: String
        public var app: String?
        public var steps: Int
        public var lastStep: String
        /// Seconds since its last step.
        public var quietFor: Double
        /// Seconds since it started.
        public var runningFor: Double
        public var stopped: Bool

        public init(key: String, name: String, app: String?, steps: Int, lastStep: String, quietFor: Double, runningFor: Double, stopped: Bool) {
            self.key = key
            self.name = name
            self.app = app
            self.steps = steps
            self.lastStep = lastStep
            self.quietFor = quietFor
            self.runningFor = runningFor
            self.stopped = stopped
        }
    }

    /// A stopped agent with nothing running.
    public struct Stopped: Codable, Sendable, Equatable {
        public var key: String
        public var name: String

        public init(key: String, name: String) {
            self.key = key
            self.name = name
        }
    }

    public struct Activity: Codable, Sendable, Equatable {
        public var agent: String
        public var summary: String
        public var secondsAgo: Double

        public init(agent: String, summary: String, secondsAgo: Double) {
            self.agent = agent
            self.summary = summary
            self.secondsAgo = secondsAgo
        }
    }

    /// An agent waiting for the user to allow it.
    public struct Request: Codable, Sendable, Equatable {
        public var id: String
        public var name: String
        public var folder: String?
        /// The processes it was started from, the agent's own first.
        public var chain: [String]
        public var command: String

        public init(id: String, name: String, folder: String?, chain: [String], command: String) {
            self.id = id
            self.name = name
            self.folder = folder
            self.chain = chain
            self.command = command
        }
    }

    public struct Paired: Codable, Sendable, Equatable {
        public var key: String
        public var name: String
        public var allowedAt: Date

        public init(key: String, name: String, allowedAt: Date) {
            self.key = key
            self.name = name
            self.allowedAt = allowedAt
        }
    }

    public var appName: String
    public var allStopped: Bool
    public var sessions: [Session]
    public var stopped: [Stopped]
    public var recent: [Activity]
    public var requests: [Request]
    public var paired: [Paired]
    /// Permissions still to set up.
    public var missing: [PermissionsMethod.Item]
    /// The stop shortcut, as the desktop writes it, when it's bound.
    public var stopShortcut: String?
    /// Whether the helper has put the panel under the tray icon, so it can show itself.
    public var placed: Bool
    /// Whether the helper starts when the user logs in.
    public var startsAtLogin: Bool
    /// Every permission, for the setup window.
    public var permissions: [PermissionsMethod.Item]
    /// Whether the helper asks the panel app to open the setup window.
    public var showSetup: Bool

    public init(
        appName: String, allStopped: Bool, sessions: [Session], stopped: [Stopped], recent: [Activity], requests: [Request],
        paired: [Paired], missing: [PermissionsMethod.Item], stopShortcut: String?, placed: Bool = true, startsAtLogin: Bool = false,
        permissions: [PermissionsMethod.Item] = [], showSetup: Bool = false
    ) {
        self.appName = appName
        self.allStopped = allStopped
        self.sessions = sessions
        self.stopped = stopped
        self.recent = recent
        self.requests = requests
        self.paired = paired
        self.missing = missing
        self.stopShortcut = stopShortcut
        self.placed = placed
        self.startsAtLogin = startsAtLogin
        self.permissions = permissions
        self.showSetup = showSetup
    }
}
