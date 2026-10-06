import Darwin
import Foundation
import HarnessProtocol
import os

/// Listens on a user-only Unix socket and serves newline-delimited JSON-RPC.
/// Each connection gets its own thread and handles requests in order.
public final class SocketServer: @unchecked Sendable {
    public enum StartError: Error, CustomStringConvertible {
        case alreadyRunning(String)

        public var description: String {
            switch self {
            case .alreadyRunning(let path): "another helper is already listening on \(path)"
            }
        }
    }

    public let path: String
    private let router: Router
    private let identify: @Sendable (Int32) -> CallerIdentity
    private var listenFD: Int32 = -1
    private let log = Logger(subsystem: "io.github.therogue76.macos-harness", category: "server")

    /// `identify` maps a connected socket to its caller; the default inspects the peer's process chain.
    public init(
        path: String,
        router: Router,
        identify: @escaping @Sendable (Int32) -> CallerIdentity = SocketServer.identifyPeer
    ) {
        self.path = path
        self.router = router
        self.identify = identify
    }

    public static let identifyPeer: @Sendable (Int32) -> CallerIdentity = { fd in
        let chain = ProcessInspector.peerPID(ofSocket: fd).map { ProcessInspector.chain(from: $0) } ?? []
        return AgentClassifier.identify(chain: chain)
    }

    public func start() throws {
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        // A socket file left by a crashed helper is stale; one that still answers is not.
        if FileManager.default.fileExists(atPath: path) {
            if (try? LineSocket.connect(path: path)) != nil {
                throw StartError.alreadyRunning(path)
            }
            unlink(path)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.system("socket", errno) }
        var address = try LineSocket.makeAddress(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            close(fd)
            throw SocketError.system("bind", errno)
        }
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else {
            close(fd)
            throw SocketError.system("listen", errno)
        }
        listenFD = fd

        let thread = Thread { [self] in acceptLoop() }
        thread.name = "harness.accept"
        thread.start()
        log.info("listening on \(self.path, privacy: .public)")
    }

    public func stop() {
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        unlink(path)
    }

    private func acceptLoop() {
        while listenFD >= 0 {
            let client = accept(listenFD, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            let thread = Thread { [self] in serve(LineSocket(fd: client)) }
            thread.name = "harness.connection"
            thread.start()
        }
    }

    private func serve(_ connection: LineSocket) {
        let context = RequestContext(caller: identify(connection.fd))
        log.info("connection from \(context.caller.displayName, privacy: .public)")
        while let line = try? connection.readLine() {
            let response: RPCResponse
            do {
                let request = try HarnessJSON.decoder.decode(RPCRequest.self, from: line)
                response = waitFor { await self.router.handle(request, context: context) }
            } catch {
                response = RPCResponse(id: nil, error: RPCError(
                    code: RPCErrorCode.parseError, message: "could not parse request: \(error)"
                ))
            }
            guard let data = try? HarnessJSON.encoder.encode(response),
                  (try? connection.writeLine(data)) != nil else { return }
        }
    }

    /// Blocks this connection thread (never a Swift concurrency thread) until `work` finishes.
    private func waitFor(_ work: @escaping @Sendable () async -> RPCResponse) -> RPCResponse {
        let box = ResultBox()
        let done = DispatchSemaphore(value: 0)
        Task {
            box.value = await work()
            done.signal()
        }
        done.wait()
        return box.value!
    }
}

private final class ResultBox: @unchecked Sendable {
    var value: RPCResponse?
}
