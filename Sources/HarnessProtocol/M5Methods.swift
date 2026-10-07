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
