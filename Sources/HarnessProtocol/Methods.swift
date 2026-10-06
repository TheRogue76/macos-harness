import Foundation

/// One process in the chain from the calling CLI up to launchd.
public struct ProcessSummary: Codable, Sendable, Equatable {
    public var pid: Int32
    public var name: String
    public var path: String
    public var signingIdentifier: String?
    public var teamIdentifier: String?

    public init(pid: Int32, name: String, path: String, signingIdentifier: String?, teamIdentifier: String?) {
        self.pid = pid
        self.name = name
        self.path = path
        self.signingIdentifier = signingIdentifier
        self.teamIdentifier = teamIdentifier
    }
}

/// Who the helper thinks is calling, and whether the user has paired them.
public struct CallerInfo: Codable, Sendable, Equatable {
    public var displayName: String
    public var identityKey: String
    public var paired: Bool
    public var chain: [ProcessSummary]
    /// The user stopped this agent; gated requests fail until they resume it.
    public var stopped: Bool

    public init(displayName: String, identityKey: String, paired: Bool, chain: [ProcessSummary], stopped: Bool = false) {
        self.displayName = displayName
        self.identityKey = identityKey
        self.paired = paired
        self.chain = chain
        self.stopped = stopped
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        displayName = try container.decode(String.self, forKey: .displayName)
        identityKey = try container.decode(String.self, forKey: .identityKey)
        paired = try container.decode(Bool.self, forKey: .paired)
        chain = try container.decode([ProcessSummary].self, forKey: .chain)
        stopped = try container.decodeIfPresent(Bool.self, forKey: .stopped) ?? false
    }
}

public enum HelloMethod: RPCMethod {
    public static let name = "hello"
    public static let requiresPairing = false

    public struct Params: Codable, Sendable {
        public var clientVersion: String
        public var clientKind: String

        public init(clientVersion: String, clientKind: String) {
            self.clientVersion = clientVersion
            self.clientKind = clientKind
        }
    }

    public struct Result: Codable, Sendable {
        public var helperVersion: String
        public var protocolVersion: Int
        public var bundleIdentifier: String
        public var caller: CallerInfo

        public init(helperVersion: String, protocolVersion: Int, bundleIdentifier: String, caller: CallerInfo) {
            self.helperVersion = helperVersion
            self.protocolVersion = protocolVersion
            self.bundleIdentifier = bundleIdentifier
            self.caller = caller
        }
    }
}

public enum DoctorMethod: RPCMethod {
    public static let name = "doctor"
    public static let requiresPairing = false
    public typealias Params = EmptyParams

    public struct Permissions: Codable, Sendable, Equatable {
        public var accessibility: Bool
        public var screenRecording: Bool

        public init(accessibility: Bool, screenRecording: Bool) {
            self.accessibility = accessibility
            self.screenRecording = screenRecording
        }
    }

    public struct Result: Codable, Sendable {
        public var helperVersion: String
        public var protocolVersion: Int
        public var bundleIdentifier: String
        public var bundlePath: String
        public var helperPID: Int32
        public var macOSVersion: String
        public var permissions: Permissions
        public var secureInputEnabled: Bool
        public var caller: CallerInfo

        public init(
            helperVersion: String, protocolVersion: Int, bundleIdentifier: String, bundlePath: String,
            helperPID: Int32, macOSVersion: String, permissions: Permissions, secureInputEnabled: Bool,
            caller: CallerInfo
        ) {
            self.helperVersion = helperVersion
            self.protocolVersion = protocolVersion
            self.bundleIdentifier = bundleIdentifier
            self.bundlePath = bundlePath
            self.helperPID = helperPID
            self.macOSVersion = macOSVersion
            self.permissions = permissions
            self.secureInputEnabled = secureInputEnabled
            self.caller = caller
        }
    }
}

public enum AppsMethod: RPCMethod {
    public static let name = "apps"

    public struct Params: Codable, Sendable {
        /// Include menu bar agents and background-only processes, not just regular apps.
        public var includeBackground: Bool

        public init(includeBackground: Bool = false) {
            self.includeBackground = includeBackground
        }
    }

    public struct App: Codable, Sendable, Equatable {
        public var name: String
        public var bundleIdentifier: String?
        public var pid: Int32
        public var active: Bool
        public var hidden: Bool
        /// `regular`, `accessory` or `prohibited`, as NSApplication.ActivationPolicy.
        public var activationPolicy: String
        /// Normal-level windows the app owns, on any Space.
        public var windowCount: Int

        public init(
            name: String, bundleIdentifier: String?, pid: Int32, active: Bool, hidden: Bool,
            activationPolicy: String, windowCount: Int
        ) {
            self.name = name
            self.bundleIdentifier = bundleIdentifier
            self.pid = pid
            self.active = active
            self.hidden = hidden
            self.activationPolicy = activationPolicy
            self.windowCount = windowCount
        }
    }

    public struct Result: Codable, Sendable {
        public var apps: [App]

        public init(apps: [App]) {
            self.apps = apps
        }
    }
}

/// Diagnostic experiments that run inside the helper.
public enum SpikeMethod: RPCMethod {
    public static let name = "debug.spike"

    public struct Params: Codable, Sendable {
        public var name: String
        public var arguments: [String]

        public init(name: String, arguments: [String]) {
            self.name = name
            self.arguments = arguments
        }
    }

    public struct Result: Codable, Sendable {
        public var report: String

        public init(report: String) {
            self.report = report
        }
    }
}
