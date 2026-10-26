import Foundation
import HarnessProtocol
import Synchronization
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// A connection to a D-Bus bus or peer. Calls can be made from any task and are pipelined: each
/// is sent at once and its reply matched up as it arrives.
public final class DBusConnection: Sendable {
    private struct State {
        var nextSerial: UInt32 = 1
        var pending: [UInt32: CheckedContinuation<DBusMessage, any Error>] = [:]
        var signalHandlers: [UUID: @Sendable (DBusMessage) -> Void] = [:]
        var closed = false
    }

    private let fd: Int32
    private let state = Mutex(State())
    private let writing = Mutex(())
    private let name = Mutex<String?>(nil)

    private init(fd: Int32) {
        self.fd = fd
    }

    /// Whether the connection has closed, by `close()` or because the peer went away.
    public var isClosed: Bool { state.withLock { $0.closed } }

    /// The name the bus gave this connection.
    public var uniqueName: String? { name.withLock { $0 } }

    /// The address of the user's session bus.
    public static func sessionBusAddress(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let address = environment["DBUS_SESSION_BUS_ADDRESS"], !address.isEmpty { return address }
        guard let runtime = environment["XDG_RUNTIME_DIR"], !runtime.isEmpty else { return nil }
        return "unix:path=\(runtime)/bus"
    }

    /// Connects to the user's session bus.
    public static func session() async throws -> DBusConnection {
        guard let address = sessionBusAddress() else { throw DBusError.badAddress("(no session bus)") }
        return try await connect(to: address)
    }

    /// Connects to the bus at `address`, authenticates and, when it's a bus rather than a peer,
    /// says hello to get a unique name.
    public static func connect(to address: String, isBus: Bool = true) async throws -> DBusConnection {
        let paths = socketPaths(in: address)
        guard !paths.isEmpty else { throw DBusError.badAddress(address) }
        var lastError: any Error = DBusError.badAddress(address)
        for path in paths {
            do {
                let fd = try open(path)
                do {
                    try authenticate(fd)
                } catch {
                    closeSocket(fd)
                    throw error
                }
                let connection = DBusConnection(fd: fd)
                Thread.detachNewThread { connection.readMessages() }
                if isBus {
                    do {
                        let reply = try await connection.call(
                            "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "Hello"
                        )
                        connection.name.withLock { $0 = reply.first?.string }
                    } catch {
                        connection.close()
                        throw error
                    }
                }
                return connection
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// The socket paths a D-Bus address lists, in order. Only `unix:path=` transports are used.
    static func socketPaths(in address: String) -> [String] {
        address.split(separator: ";").compactMap { entry in
            guard entry.hasPrefix("unix:") else { return nil }
            for pair in entry.dropFirst(5).split(separator: ",") where pair.hasPrefix("path=") {
                return unescape(String(pair.dropFirst(5)))
            }
            return nil
        }
    }

    /// An address value with its `%xx` escapes decoded.
    static func unescape(_ value: String) -> String {
        var bytes: [UInt8] = []
        var utf8 = Array(value.utf8)[...]
        while let byte = utf8.popFirst() {
            if byte == UInt8(ascii: "%"), utf8.count >= 2,
               let decoded = UInt8(String(decoding: utf8.prefix(2), as: UTF8.self), radix: 16) {
                bytes.append(decoded)
                utf8 = utf8.dropFirst(2)
            } else {
                bytes.append(byte)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func closeSocket(_ fd: Int32) {
        #if canImport(Glibc)
        _ = Glibc.close(fd)
        #else
        _ = Musl.close(fd)
        #endif
    }

    private static func open(_ path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, POSIX.streamSocket, 0)
        guard fd >= 0 else { throw SocketError.system("socket", errno) }
        do {
            guard POSIX.connect(fd, to: try LineSocket.makeAddress(path)) == 0 else { throw SocketError.system("connect", errno) }
        } catch {
            closeSocket(fd)
            throw DBusError.badAddress("unix:path=\(path) (\(error))")
        }
        return fd
    }

    private static func authenticate(_ fd: Int32) throws {
        let uid = Array(String(getuid()).utf8).map { String($0, radix: 16) }.joined()
        try writeAll(fd, [0] + Array("AUTH EXTERNAL \(uid)\r\n".utf8))
        let reply = try readLine(fd)
        guard reply.hasPrefix("OK ") else { throw DBusError.authenticationFailed(reply) }
        try writeAll(fd, Array("BEGIN\r\n".utf8))
    }

    private static func readLine(_ fd: Int32) throws -> String {
        var line: [UInt8] = []
        var byte: UInt8 = 0
        while line.count < 512 {
            let count = unsafe read(fd, &byte, 1)
            if count < 0, errno == EINTR { continue }
            guard count == 1 else { throw DBusError.closed }
            if byte == UInt8(ascii: "\n") { break }
            if byte != UInt8(ascii: "\r") { line.append(byte) }
        }
        return String(decoding: line, as: UTF8.self)
    }

    private static func writeAll(_ fd: Int32, _ bytes: [UInt8]) throws {
        try bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = unsafe POSIX.send(fd, raw.baseAddress! + offset, raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw DBusError.closed
                }
                offset += written
            }
        }
    }

    /// Calls a method and returns its reply's values, throwing the peer's error if it sent one.
    public func call(
        _ destination: String?, _ path: String, _ interface: String?, _ member: String,
        _ arguments: [DBusValue] = [], timeout: Duration = .seconds(5)
    ) async throws -> [DBusValue] {
        let message = DBusMessage(
            kind: .methodCall, path: path, interface: interface, member: member, destination: destination, body: arguments
        )
        let reply = try await send(message, timeout: timeout)
        if reply.kind == .error {
            throw DBusError.failed(name: reply.errorName ?? "org.freedesktop.DBus.Error.Failed", message: reply.body.first?.string ?? "")
        }
        return reply.body
    }

    /// Reads a property with `org.freedesktop.DBus.Properties.Get`.
    public func property(
        _ destination: String?, _ path: String, _ interface: String, _ name: String, timeout: Duration = .seconds(5)
    ) async throws -> DBusValue {
        let reply = try await call(
            destination, path, "org.freedesktop.DBus.Properties", "Get", [.string(interface), .string(name)], timeout: timeout
        )
        guard let value = reply.first else { throw DBusError.protocolViolation("Properties.Get returned nothing") }
        return value.unwrapped
    }

    /// Sends a method call and waits for its reply or error.
    public func send(_ message: DBusMessage, timeout: Duration = .seconds(5)) async throws -> DBusMessage {
        try await withCheckedThrowingContinuation { continuation in
            let serial: UInt32? = state.withLock { state in
                guard !state.closed else { return nil }
                let serial = state.nextSerial
                state.nextSerial = state.nextSerial == .max ? 1 : state.nextSerial + 1
                state.pending[serial] = continuation
                return serial
            }
            guard let serial else {
                continuation.resume(throwing: DBusError.closed)
                return
            }
            var outgoing = message
            outgoing.serial = serial
            do {
                try write(outgoing)
            } catch {
                finish(serial, with: .failure(error))
                return
            }
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.finish(serial, with: .failure(DBusError.timedOut))
            }
        }
    }

    /// Sends a signal or a message that expects no reply.
    public func emit(_ message: DBusMessage) throws {
        var outgoing = message
        let serial: UInt32? = state.withLock { state in
            guard !state.closed else { return nil }
            let serial = state.nextSerial
            state.nextSerial = state.nextSerial == .max ? 1 : state.nextSerial + 1
            return serial
        }
        guard let serial else { throw DBusError.closed }
        outgoing.serial = serial
        try write(outgoing)
    }

    /// Calls `handler` with every signal that arrives, on the connection's reading thread.
    /// Signals reach a bus connection only once a match rule asks for them.
    @discardableResult
    public func onSignal(_ handler: @escaping @Sendable (DBusMessage) -> Void) -> UUID {
        let id = UUID()
        state.withLock { $0.signalHandlers[id] = handler }
        return id
    }

    /// Stops calling a handler `onSignal` added.
    public func removeSignalHandler(_ id: UUID) {
        _ = state.withLock { $0.signalHandlers.removeValue(forKey: id) }
    }

    /// Asks the bus to stop routing the signals `rule` matches.
    public func removeMatch(_ rule: String) async throws {
        _ = try await call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RemoveMatch", [.string(rule)])
    }

    /// Asks the bus to route the signals `rule` matches to this connection.
    public func addMatch(_ rule: String) async throws {
        _ = try await call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "AddMatch", [.string(rule)])
    }

    /// Closes the connection; pending calls fail with `closed`.
    public func close() {
        let wasOpen = state.withLock { state in
            defer { state.closed = true }
            return !state.closed
        }
        if wasOpen { shutdown(fd, Int32(SHUT_RDWR)) }
    }

    private func write(_ message: DBusMessage) throws {
        let bytes = try message.encoded()
        try writing.withLock { _ in try Self.writeAll(fd, bytes) }
    }

    private func finish(_ serial: UInt32, with result: Result<DBusMessage, any Error>) {
        let continuation = state.withLock { $0.pending.removeValue(forKey: serial) }
        continuation?.resume(with: result)
    }

    private func readMessages() {
        var buffer: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 256 * 1024)
        reading: while true {
            let count = unsafe read(fd, &chunk, chunk.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            buffer += chunk[0..<count]
            var start = 0
            while true {
                let length: Int?
                do {
                    length = try DBusMessage.length(of: buffer[start...])
                } catch {
                    break reading
                }
                guard let length, buffer.count - start >= length else { break }
                if let message = try? DBusMessage.decode(Array(buffer[start..<(start + length)])) {
                    dispatch(message)
                }
                start += length
            }
            if start > 0 { buffer.removeFirst(start) }
        }
        let pending = state.withLock { state in
            state.closed = true
            defer { state.pending = [:] }
            return Array(state.pending.values)
        }
        for continuation in pending { continuation.resume(throwing: DBusError.closed) }
        Self.closeSocket(fd)
    }

    private func dispatch(_ message: DBusMessage) {
        switch message.kind {
        case .methodReturn, .error:
            if let serial = message.replySerial { finish(serial, with: .success(message)) }
        case .signal:
            let handlers = state.withLock { Array($0.signalHandlers.values) }
            for handler in handlers { handler(message) }
        case .methodCall:
            guard message.flags & DBusMessage.noReplyExpected == 0 else { return }
            var reply = DBusMessage(kind: .error, destination: message.sender, body: [.string("macOS Harness doesn't serve \(message.member ?? "methods")")])
            reply.errorName = "org.freedesktop.DBus.Error.UnknownMethod"
            reply.replySerial = message.serial
            try? emit(reply)
        }
    }
}
