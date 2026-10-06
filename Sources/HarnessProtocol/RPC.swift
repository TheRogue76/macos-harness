import Foundation

/// A JSON-RPC 2.0 request. Messages are framed as one JSON object per line.
public struct RPCRequest: Codable, Sendable, Equatable {
    public var jsonrpc = "2.0"
    public var id: Int
    public var method: String
    public var params: JSONValue?

    public init(id: Int, method: String, params: JSONValue?) {
        self.id = id
        self.method = method
        self.params = params
    }
}

public struct RPCResponse: Codable, Sendable, Equatable {
    public var jsonrpc = "2.0"
    public var id: Int?
    public var result: JSONValue?
    public var error: RPCError?

    public init(id: Int?, result: JSONValue) {
        self.id = id
        self.result = result
    }

    public init(id: Int?, error: RPCError) {
        self.id = id
        self.error = error
    }
}

public struct RPCError: Codable, Sendable, Equatable, Error, CustomStringConvertible {
    public var code: Int
    public var message: String
    public var data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    public var description: String { message }
}

/// Error codes: the JSON-RPC reserved range plus harness-specific ones from 1000 up.
public enum RPCErrorCode {
    public static let parseError = -32700
    public static let invalidRequest = -32600
    public static let methodNotFound = -32601
    public static let invalidParams = -32602
    public static let internalError = -32603

    /// The user declined (or hasn't answered) the pairing prompt for this agent.
    public static let pairingDenied = 1001
    /// The helper lacks a macOS permission the request needs.
    public static let permissionMissing = 1002
    /// The request is valid but can't be carried out (no such app, element, …).
    public static let failed = 1003
    /// The user stopped this agent (or all agents) from the menu bar or the stop hotkey.
    public static let stoppedByUser = 1004
}

#if compiler(>=6.2)
public protocol RPCMethodBase: SendableMetatype {}
#else
public protocol RPCMethodBase {}
#endif

/// A typed RPC method. The helper registers handlers by type; the client calls by type.
public protocol RPCMethod: RPCMethodBase {
    associatedtype Params: Codable & Sendable
    associatedtype Result: Codable & Sendable
    static var name: String { get }
    /// Whether the caller must be paired before the helper runs this method.
    static var requiresPairing: Bool { get }
}

extension RPCMethod {
    public static var requiresPairing: Bool { true }
}

public struct EmptyParams: Codable, Sendable, Equatable {
    public init() {}
}
