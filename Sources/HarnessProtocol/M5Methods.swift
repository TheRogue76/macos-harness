import Foundation

/// Apps to block or make read-only on top of the user's policy.
public struct PolicyRestrictions: Codable, Sendable, Equatable {
    public var blocked: [String]
    public var readOnly: [String]

    public init(blocked: [String] = [], readOnly: [String] = []) {
        self.blocked = blocked
        self.readOnly = readOnly
    }

    public var isEmpty: Bool { blocked.isEmpty && readOnly.isEmpty }

    /// Both sets of restrictions together; nothing is ever removed.
    public func adding(_ other: PolicyRestrictions) -> PolicyRestrictions {
        PolicyRestrictions(
            blocked: blocked + other.blocked.filter { !blocked.contains($0) },
            readOnly: readOnly + other.readOnly.filter { !readOnly.contains($0) }
        )
    }
}

/// Adds restrictions to the user's policy for the rest of this connection. They can only
/// tighten it: a connection can't lift anything the user's policy file says.
public enum RestrictMethod: RPCMethod {
    public static let name = "restrict"
    public typealias Params = PolicyRestrictions

    public struct Result: Codable, Sendable {
        /// Everything this connection has restricted so far.
        public var restrictions: PolicyRestrictions

        public init(restrictions: PolicyRestrictions) {
            self.restrictions = restrictions
        }
    }
}

/// Starts recording an app's windows to a movie file. Only that app's windows are captured,
/// on the display its window is on.
public enum RecordStartMethod: RPCMethod {
    public static let name = "record.start"

    public struct Params: Codable, Sendable {
        public var target: Target
        /// Absolute path of the .mov file to write.
        public var path: String
        /// Stop on its own after this many seconds.
        public var maxSeconds: Double

        public init(target: Target, path: String, maxSeconds: Double = 600) {
            self.target = target
            self.path = path
            self.maxSeconds = maxSeconds
        }
    }

    public struct Result: Codable, Sendable {
        public var id: String
        public var path: String
        public var app: AppRef

        public init(id: String, path: String, app: AppRef) {
            self.id = id
            self.path = path
            self.app = app
        }
    }
}

/// Stops a recording, or every recording the caller started, and finishes the files.
public enum RecordStopMethod: RPCMethod {
    public static let name = "record.stop"

    public struct Params: Codable, Sendable {
        public var id: String?

        public init(id: String? = nil) {
            self.id = id
        }
    }

    public struct Recording: Codable, Sendable, Equatable {
        public var id: String
        public var path: String
        public var seconds: Double
        public var bytes: Int

        public init(id: String, path: String, seconds: Double, bytes: Int) {
            self.id = id
            self.path = path
            self.seconds = seconds
            self.bytes = bytes
        }
    }

    public struct Result: Codable, Sendable {
        public var recordings: [Recording]

        public init(recordings: [Recording]) {
            self.recordings = recordings
        }
    }
}
