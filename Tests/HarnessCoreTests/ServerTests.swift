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

private func startServer(gate: FakeGate) throws -> SocketServer {
    let router = Router(gate: gate)
    router.register(EchoMethod.self) { params, context in
        EchoMethod.Result(text: params.text, caller: context.caller.displayName)
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

struct ServerTests {
    @Test func servesPairedRequests() throws {
        let gate = FakeGate(approve: true)
        let server = try startServer(gate: gate)
        defer { server.stop() }

        let connection = try HarnessConnection.connect(socketPath: server.path)
        let first = try connection.call(EchoMethod.self, .init(text: "hi"), timeout: 5)
        let second = try connection.call(EchoMethod.self, .init(text: "again"), timeout: 5)
        #expect(first.text == "hi")
        #expect(first.caller == "Test Agent")
        #expect(second.text == "again")
    }

    @Test func ungatedMethodsSkipPairing() throws {
        let gate = FakeGate(approve: false)
        let server = try startServer(gate: gate)
        defer { server.stop() }

        let connection = try HarnessConnection.connect(socketPath: server.path)
        let hello = try connection.call(HelloMethod.self, .init(clientVersion: "x", clientKind: "test"), timeout: 5)
        #expect(hello.caller.displayName == "Test Agent")
        #expect(gate.promptCount == 0)
    }

    @Test func deniedPairingReturnsError() throws {
        let gate = FakeGate(approve: false)
        let server = try startServer(gate: gate)
        defer { server.stop() }

        let connection = try HarnessConnection.connect(socketPath: server.path)
        #expect(throws: RPCError.self) {
            try connection.call(EchoMethod.self, .init(text: "hi"), timeout: 5)
        }
        #expect(gate.promptCount == 1)
    }

    @Test func unknownMethodIsReported() throws {
        let server = try startServer(gate: FakeGate(approve: true))
        defer { server.stop() }

        let socket = try LineSocket.connect(path: server.path)
        socket.setReadTimeout(5)
        try socket.writeLine(Data(#"{"jsonrpc":"2.0","id":1,"method":"nope"}"#.utf8))
        let line = try #require(try socket.readLine())
        let response = try HarnessJSON.decoder.decode(RPCResponse.self, from: line)
        #expect(response.error?.code == RPCErrorCode.methodNotFound)
    }

    @Test func refusesToStartTwice() throws {
        let server = try startServer(gate: FakeGate(approve: true))
        defer { server.stop() }

        let second = SocketServer(path: server.path, router: Router(gate: FakeGate(approve: true)))
        #expect(throws: SocketServer.StartError.self) { try second.start() }
    }
}
