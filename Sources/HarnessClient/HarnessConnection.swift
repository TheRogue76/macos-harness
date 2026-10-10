import Foundation
import HarnessProtocol

public enum HarnessClientError: Error, CustomStringConvertible {
    case helperNotFound
    case launchFailed(String)
    case helperUnreachable(path: String, underlying: String)
    case protocolError(String)

    public var description: String {
        switch self {
        case .helperNotFound:
            "Couldn't find the macOS Harness app. Install it, or set MACOS_HARNESS_APP to its path."
        case .launchFailed(let detail):
            "Couldn't start the macOS Harness helper: \(detail)"
        case .helperUnreachable(let path, let underlying):
            "Couldn't reach the helper at \(path) (\(underlying)). If your agent runs commands in a sandbox, allow this socket path or run outside the sandbox."
        case .protocolError(let detail):
            "Unexpected reply from the helper: \(detail)"
        }
    }
}

/// A blocking connection to the helper. One request at a time.
public final class HarnessConnection {
    public let location: HelperLocation
    private let socket: LineSocket
    private var nextID = 1
    /// Requests that timed out here; the helper still answers them, late, before the next reply.
    private var abandoned: Set<Int> = []

    init(location: HelperLocation, socket: LineSocket) {
        self.location = location
        self.socket = socket
    }

    /// Connects to the helper, starting it if it isn't running.
    public static func open(
        location: HelperLocation? = HelperLocator.locate(),
        launchIfNeeded: Bool = true,
        timeout: TimeInterval = 10
    ) throws -> HarnessConnection {
        guard let location else { throw HarnessClientError.helperNotFound }
        do {
            return HarnessConnection(location: location, socket: try LineSocket.connect(path: location.socketPath))
        } catch let error as SocketError {
            guard launchIfNeeded, [ENOENT, ECONNREFUSED].contains(error.errnoCode ?? 0) else {
                throw HarnessClientError.helperUnreachable(path: location.socketPath, underlying: error.description)
            }
        }
        try launch(location)
        let deadline = Date().addingTimeInterval(timeout)
        var lastError = "not started"
        while Date() < deadline {
            do {
                return HarnessConnection(location: location, socket: try LineSocket.connect(path: location.socketPath))
            } catch {
                lastError = String(describing: error)
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        throw HarnessClientError.helperUnreachable(path: location.socketPath, underlying: lastError)
    }

    /// Connects to an already listening socket. For tests and diagnostics.
    public static func connect(socketPath: String, variant: HarnessVariant = .dev) throws -> HarnessConnection {
        let location = HelperLocation(variant: variant, appURL: nil, socketPath: socketPath)
        return HarnessConnection(location: location, socket: try LineSocket.connect(path: socketPath))
    }

    static func launch(_ location: HelperLocation) throws {
        if ProcessInfo.processInfo.environment["MACOS_HARNESS_LAUNCH"] == "child", let app = location.appURL {
            let helper = Process()
            helper.executableURL = app.appendingPathComponent("Contents/MacOS/macos-harness-helper")
            helper.standardOutput = FileHandle.nullDevice
            helper.standardError = FileHandle.nullDevice
            do {
                try helper.run()
            } catch {
                throw HarnessClientError.launchFailed(String(describing: error))
            }
            return
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        if let app = location.appURL {
            task.arguments = ["-g", app.path]
        } else {
            task.arguments = ["-g", "-b", location.variant.bundleIdentifier]
        }
        let errors = Pipe()
        task.standardError = errors
        do {
            try task.run()
        } catch {
            throw HarnessClientError.launchFailed(String(describing: error))
        }
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw HarnessClientError.launchFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Sends one request and waits for its response; a nil `timeout` waits forever. Late replies
    /// to requests that timed out earlier are skipped.
    public func call<M: RPCMethod>(_ method: M.Type, _ params: M.Params, timeout: TimeInterval? = nil) throws -> M.Result {
        let id = nextID
        nextID += 1
        let request = RPCRequest(id: id, method: M.name, params: try JSONValue(encoding: params))
        try socket.writeLine(try HarnessJSON.encoder.encode(request))
        let deadline = timeout.map { Date().addingTimeInterval($0) }
        var response = try readResponse(to: id, until: deadline)
        while let late = response.id, late != id, abandoned.remove(late) != nil {
            response = try readResponse(to: id, until: deadline)
        }
        guard response.id == id else {
            throw HarnessClientError.protocolError("response id \(String(describing: response.id)) for request \(id)")
        }
        if let error = response.error { throw error }
        guard let result = response.result else {
            throw HarnessClientError.protocolError("response has neither result nor error")
        }
        return try result.decode(as: M.Result.self)
    }

    /// The next response on the connection, waiting until `deadline` (nil waits forever); when
    /// that passes, request `id` counts as abandoned.
    private func readResponse(to id: Int, until deadline: Date?) throws -> RPCResponse {
        do {
            if let deadline {
                let left = deadline.timeIntervalSinceNow
                guard left > 0 else { throw SocketError.timedOut }
                socket.setReadTimeout(max(left, 0.001))
            } else {
                socket.setReadTimeout(nil)
            }
            guard let line = try socket.readLine() else {
                throw HarnessClientError.protocolError("the helper closed the connection")
            }
            return try HarnessJSON.decoder.decode(RPCResponse.self, from: line)
        } catch SocketError.timedOut {
            abandoned.insert(id)
            throw SocketError.timedOut
        }
    }
}
