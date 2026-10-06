import Foundation
import HarnessProtocol

/// Per-connection facts every handler can see.
public struct RequestContext: Sendable {
    public var caller: CallerIdentity

    public init(caller: CallerIdentity) {
        self.caller = caller
    }
}

/// Decides whether a caller may use pairing-gated methods, asking the user if needed.
public protocol PairingGate: Sendable {
    func isPaired(_ caller: CallerIdentity) async -> Bool
    func requestApproval(for caller: CallerIdentity) async -> Bool
}

/// Sees every request: may refuse gated ones (a stopped agent) and records what happened.
public protocol RequestObserver: Sendable {
    /// Called for pairing-gated methods after pairing passes; an error refuses the request.
    func refusal(for request: RPCRequest, context: RequestContext) async -> RPCError?
    func didHandle(_ request: RPCRequest, context: RequestContext, response: RPCResponse) async
}

/// Maps method names to handlers. Register everything before the server starts.
public final class Router: @unchecked Sendable {
    public typealias RawHandler = @Sendable (JSONValue?, RequestContext) async throws -> JSONValue

    private var handlers: [String: (requiresPairing: Bool, handler: RawHandler)] = [:]
    private let gate: PairingGate
    private let observer: RequestObserver?

    public init(gate: PairingGate, observer: RequestObserver? = nil) {
        self.gate = gate
        self.observer = observer
    }

    public func register<M: RPCMethod>(
        _ method: M.Type,
        _ body: @escaping @Sendable (M.Params, RequestContext) async throws -> M.Result
    ) {
        handlers[M.name] = (M.requiresPairing, { raw, context in
            let params: M.Params
            do {
                params = try (raw ?? .object([:])).decode(as: M.Params.self)
            } catch {
                throw RPCError(code: RPCErrorCode.invalidParams, message: "invalid params for \(M.name): \(error)")
            }
            return try JSONValue(encoding: try await body(params, context))
        })
    }

    public func handle(_ request: RPCRequest, context: RequestContext) async -> RPCResponse {
        let response = await respond(to: request, context: context)
        await observer?.didHandle(request, context: context, response: response)
        return response
    }

    private func respond(to request: RPCRequest, context: RequestContext) async -> RPCResponse {
        guard let entry = handlers[request.method] else {
            return RPCResponse(id: request.id, error: RPCError(
                code: RPCErrorCode.methodNotFound, message: "unknown method \(request.method)"
            ))
        }
        if entry.requiresPairing, !(await gate.isPaired(context.caller)) {
            guard await gate.requestApproval(for: context.caller) else {
                return RPCResponse(id: request.id, error: RPCError(
                    code: RPCErrorCode.pairingDenied,
                    message: "\(context.caller.displayName) isn't allowed to use macOS Harness. Approve it from the pairing prompt or the menu bar icon."
                ))
            }
        }
        if entry.requiresPairing, let refusal = await observer?.refusal(for: request, context: context) {
            return RPCResponse(id: request.id, error: refusal)
        }
        do {
            return RPCResponse(id: request.id, result: try await entry.handler(request.params, context))
        } catch let error as RPCError {
            return RPCResponse(id: request.id, error: error)
        } catch {
            return RPCResponse(id: request.id, error: RPCError(
                code: RPCErrorCode.internalError, message: String(describing: error)
            ))
        }
    }
}
