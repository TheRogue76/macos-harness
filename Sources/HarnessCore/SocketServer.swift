#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation
import HarnessProtocol
import Synchronization

/// Serves newline-delimited JSON-RPC on a user-only Unix socket, handling each connection's
/// requests in order.
public final class SocketServer: Sendable {
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
    private let listenFD = Mutex<Int32>(-1)
    private let log = HelperLog(category: "server")

    /// `identify` maps a connected socket to its caller, usually a platform's
    /// `ProcessIntrospection.identifyPeer`.
    public init(path: String, router: Router, identify: @escaping @Sendable (Int32) -> CallerIdentity) {
        self.path = path
        self.router = router
        self.identify = identify
    }

    public func start() throws {
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        if FileManager.default.fileExists(atPath: path) {
            if (try? LineSocket.connect(path: path)) != nil {
                throw StartError.alreadyRunning(path)
            }
            try? FileManager.default.removeItem(atPath: path)
        }

        let fd = socket(AF_UNIX, POSIX.streamSocket, 0)
        guard fd >= 0 else { throw SocketError.system("socket", errno) }
        guard POSIX.bind(fd, to: try LineSocket.makeAddress(path)) == 0 else {
            close(fd)
            throw SocketError.system("bind", errno)
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        guard listen(fd, 16) == 0 else {
            close(fd)
            throw SocketError.system("listen", errno)
        }
        listenFD.withLock { $0 = fd }

        let thread = Thread { [self] in acceptLoop() }
        thread.name = "harness.accept"
        thread.start()
        log.info("listening on \(path)")
    }

    public func stop() {
        listenFD.withLock { fd in
            if fd >= 0 {
                close(fd)
                fd = -1
            }
        }
        try? FileManager.default.removeItem(atPath: path)
    }

    private func acceptLoop() {
        while true {
            let fd = listenFD.withLock { $0 }
            guard fd >= 0 else { return }
            let client = accept(fd, nil, nil)
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
        log.info("connection from \(context.caller.displayName)")
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

    /// Blocks the calling thread until `work` finishes.
    private func waitFor(_ work: @escaping @Sendable () async -> RPCResponse) -> RPCResponse {
        let box = ResultBox()
        let done = DispatchSemaphore(value: 0)
        Task {
            box.set(await work())
            done.signal()
        }
        done.wait()
        return box.value!
    }
}

/// The response a request's task hands to the connection thread waiting for it.
private final class ResultBox: Sendable {
    private let storage = Mutex<RPCResponse?>(nil)

    var value: RPCResponse? { storage.withLock { $0 } }

    func set(_ response: RPCResponse) {
        storage.withLock { $0 = response }
    }
}
