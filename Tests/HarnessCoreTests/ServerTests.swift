import Foundation
import HarnessClient
import HarnessCore
import HarnessProtocol
import Testing

/// A gate whose answer the test decides, counting how often the user would be asked.
private final class FakeGate: PairingGate, @unchecked Sendable {
    let approve: Bool
    private let lock = NSLock()
    private var prompts = 0

    init(approve: Bool) {
        self.approve = approve
    }

    var promptCount: Int { lock.withLock { prompts } }

    func isPaired(_ caller: CallerIdentity) async -> Bool { false }

    func requestApproval(for caller: CallerIdentity) async -> Bool {
        lock.withLock { prompts += 1 }
        return approve
    }
}

private enum EchoMethod: RPCMethod {
    static let name = "test.echo"
    struct Params: Codable, Sendable { var text: String }
    struct Result: Codable, Sendable { var text: String; var caller: String }
}

private enum SlowEchoMethod: RPCMethod {
    static let name = "test.slowEcho"
    struct Params: Codable, Sendable { var text: String; var seconds: Double }
    typealias Result = EchoMethod.Result
}

private func startServer(gate: FakeGate) throws -> SocketServer {
    let router = Router(gate: gate)
    router.register(EchoMethod.self) { params, context in
        EchoMethod.Result(text: params.text, caller: context.caller.displayName)
    }
    router.register(SlowEchoMethod.self) { params, context in
        try await Task.sleep(for: .seconds(params.seconds))
        return EchoMethod.Result(text: params.text, caller: context.caller.displayName)
    }
    router.register(HelloMethod.self) { _, context in
        HelloMethod.Result(
            helperVersion: HarnessVersion.string, protocolVersion: HarnessVersion.protocolVersion,
            bundleIdentifier: "test", caller: CallerInfo(context.caller, paired: false)
        )
    }
    let path = "/tmp/mh-test-\(UUID().uuidString.prefix(8)).sock"
    let server = SocketServer(path: path, router: router) { _ in
        CallerIdentity(displayName: "Test Agent", key: "test|unsigned|test", chain: [])
    }
    try server.start()
    return server
}

/// Runs blocking socket work on its own thread, so waiting never ties up the concurrency threads
/// the server's handlers run on.
private func offPool<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        Thread { continuation.resume(with: Result { try work() }) }.start()
    }
}

struct ServerTests {
    @Test func servesPairedRequests() async throws {
        let server = try startServer(gate: FakeGate(approve: true))
        defer { server.stop() }

        let path = server.path
        let (first, second) = try await offPool {
            let connection = try HarnessConnection.connect(socketPath: path)
            let first = try connection.call(EchoMethod.self, .init(text: "hi"), timeout: 5)
            return (first, try connection.call(EchoMethod.self, .init(text: "again"), timeout: 5))
        }
        #expect(first.text == "hi")
        #expect(first.caller == "Test Agent")
        #expect(second.text == "again")
    }

    @Test func skipsTheLateReplyToARequestThatTimedOut() async throws {
        let server = try startServer(gate: FakeGate(approve: true))
        defer { server.stop() }

        let path = server.path
        let (timedOut, next) = try await offPool { () -> (Bool, String) in
            let connection = try HarnessConnection.connect(socketPath: path)
            var timedOut = false
            do {
                _ = try connection.call(SlowEchoMethod.self, .init(text: "slow", seconds: 1), timeout: 0.3)
            } catch SocketError.timedOut {
                timedOut = true
            }
            return (timedOut, try connection.call(EchoMethod.self, .init(text: "next"), timeout: 5).text)
        }
        #expect(timedOut)
        #expect(next == "next")
    }

    @Test func ungatedMethodsSkipPairing() async throws {
        let gate = FakeGate(approve: false)
        let server = try startServer(gate: gate)
        defer { server.stop() }

        let path = server.path
        let hello = try await offPool {
            try HarnessConnection.connect(socketPath: path)
                .call(HelloMethod.self, .init(clientVersion: "x", clientKind: "test"), timeout: 5)
        }
        #expect(hello.caller.displayName == "Test Agent")
        #expect(gate.promptCount == 0)
    }

    @Test func deniedPairingReturnsError() async throws {
        let gate = FakeGate(approve: false)
        let server = try startServer(gate: gate)
        defer { server.stop() }

        let path = server.path
        let refusal = try await offPool { () -> RPCError? in
            let connection = try HarnessConnection.connect(socketPath: path)
            do {
                _ = try connection.call(EchoMethod.self, .init(text: "hi"), timeout: 5)
                return nil
            } catch let error as RPCError {
                return error
            }
        }
        #expect(refusal?.code == RPCErrorCode.pairingDenied)
        #expect(gate.promptCount == 1)
    }

    @Test func unknownMethodIsReported() async throws {
        let server = try startServer(gate: FakeGate(approve: true))
        defer { server.stop() }

        let path = server.path
        let response = try await offPool { () -> RPCResponse? in
            let socket = try LineSocket.connect(path: path)
            socket.setReadTimeout(5)
            try socket.writeLine(Data(#"{"jsonrpc":"2.0","id":1,"method":"nope"}"#.utf8))
            return try socket.readLine().map { try HarnessJSON.decoder.decode(RPCResponse.self, from: $0) }
        }
        #expect(response?.error?.code == RPCErrorCode.methodNotFound)
    }

    @Test func refusesToStartTwice() throws {
        let server = try startServer(gate: FakeGate(approve: true))
        defer { server.stop() }

        let second = SocketServer(path: server.path, router: Router(gate: FakeGate(approve: true)))
        #expect(throws: SocketServer.StartError.self) { try second.start() }
    }
}
