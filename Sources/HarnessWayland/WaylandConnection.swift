import Foundation
import HarnessProtocol
import Synchronization
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// A global the compositor offers: an interface the client can bind.
public struct WaylandGlobal: Sendable, Equatable {
    public var name: UInt32
    public var interface: String
    public var version: UInt32
}

/// A connection to a Wayland compositor. Requests can be sent from any task; events go to the
/// listener of the object they're for, on the connection's reading thread.
public final class WaylandConnection: Sendable {
    public typealias Listener = @Sendable (inout WaylandEvent) throws -> Void

    private struct State {
        var nextID: UInt32 = 2
        var listeners: [UInt32: Listener] = [:]
        var error: WaylandError?
        var closed = false
    }

    static let display: UInt32 = 1
    private let fd: Int32
    private let state = Mutex(State())
    private let writing = Mutex(())

    private init(fd: Int32) {
        self.fd = fd
    }

    /// The compositor's socket: `WAYLAND_DISPLAY` as a path, or that name (`wayland-0` when unset)
    /// in `XDG_RUNTIME_DIR`.
    public static func socketPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let name = environment["WAYLAND_DISPLAY"].flatMap { $0.isEmpty ? nil : $0 } ?? "wayland-0"
        if name.hasPrefix("/") { return name }
        guard let runtime = environment["XDG_RUNTIME_DIR"], !runtime.isEmpty else { return nil }
        return "\(runtime)/\(name)"
    }

    /// Connects to the compositor and starts reading its events.
    public static func connect(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> WaylandConnection {
        guard let path = socketPath(environment: environment), FileManager.default.fileExists(atPath: path) else {
            throw WaylandError.noDisplay
        }
        let fd = socket(AF_UNIX, POSIX.streamSocket, 0)
        guard fd >= 0 else { throw SocketError.system("socket", errno) }
        guard POSIX.connect(fd, to: try LineSocket.makeAddress(path)) == 0 else {
            let code = errno
            closeSocket(fd)
            throw SocketError.system("connect", code)
        }
        let connection = WaylandConnection(fd: fd)
        Thread.detachNewThread { connection.readEvents() }
        return connection
    }

    /// Whether the connection has ended, through an error or `close()`.
    public var isClosed: Bool { state.withLock { $0.closed } }

    /// A new object ID for a request that creates an object.
    public func allocate() -> UInt32 {
        state.withLock { state in
            defer { state.nextID += 1 }
            return state.nextID
        }
    }

    /// Sends events for `object` to `listener` until it's forgotten or deleted.
    public func listen(_ object: UInt32, _ listener: @escaping Listener) {
        state.withLock { $0.listeners[object] = listener }
    }

    public func forget(_ object: UInt32) {
        _ = state.withLock { $0.listeners.removeValue(forKey: object) }
    }

    /// Sends a request.
    public func send(_ object: UInt32, _ opcode: UInt16, _ arguments: [WaylandArgument] = []) throws {
        if let error = state.withLock({ $0.closed ? ($0.error ?? WaylandError.closed) : nil }) { throw error }
        let (bytes, fds) = WaylandWire.encode(object: object, opcode: opcode, arguments)
        try writing.withLock { _ in try transmit(bytes, fds: fds) }
    }

    /// Waits until the compositor has handled every request sent so far.
    public func roundtrip(timeout: Duration = .seconds(5)) async throws {
        let callback = allocate()
        let done = Mutex<CheckedContinuation<Void, any Error>?>(nil)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            done.withLock { $0 = continuation }
            listen(callback) { [weak self] _ in
                self?.forget(callback)
                done.withLock { $0.take() }?.resume()
            }
            watch { error in done.withLock { $0.take() }?.resume(throwing: error) }
            do {
                try send(Self.display, 0, [.newID(callback)])
            } catch {
                done.withLock { $0.take() }?.resume(throwing: error)
                return
            }
            Task {
                try? await Task.sleep(for: timeout)
                done.withLock { $0.take() }?.resume(throwing: WaylandError.timedOut)
            }
        }
    }

    private let failures = Mutex<[@Sendable (WaylandError) -> Void]>([])

    /// Calls `handler` if the connection fails while it's waiting.
    func watch(_ handler: @escaping @Sendable (WaylandError) -> Void) {
        if let error = state.withLock({ $0.closed ? ($0.error ?? WaylandError.closed) : nil }) {
            handler(error)
            return
        }
        failures.withLock { $0.append(handler) }
    }

    /// The globals the compositor offers, with the registry kept for binding them.
    public func globals() async throws -> (registry: UInt32, globals: [WaylandGlobal]) {
        let registry = allocate()
        let found = Mutex<[WaylandGlobal]>([])
        listen(registry) { event in
            guard event.opcode == 0 else { return }
            let name = try event.uint()
            let interface = try event.string() ?? ""
            let version = try event.uint()
            found.withLock { $0.append(WaylandGlobal(name: name, interface: interface, version: version)) }
        }
        try send(Self.display, 1, [.newID(registry)])
        try await roundtrip()
        return (registry, found.withLock { $0 })
    }

    /// Binds a global at the highest version both sides know, returning the new object's ID.
    public func bind(_ global: WaylandGlobal, registry: UInt32, version: UInt32) throws -> UInt32 {
        let object = allocate()
        try send(registry, 0, [.uint(global.name), .string(global.interface), .uint(min(version, global.version)), .newID(object)])
        return object
    }

    /// Ends the connection.
    public func close() {
        let wasOpen = state.withLock { state in
            defer { state.closed = true }
            return !state.closed
        }
        if wasOpen { shutdown(fd, Int32(SHUT_RDWR)) }
    }

    private func transmit(_ bytes: [UInt8], fds: [Int32]) throws {
        guard UnixRights.send(fd, bytes, fds: fds) else { throw WaylandError.closed }
    }

    private static func closeSocket(_ fd: Int32) {
        #if canImport(Glibc)
        _ = Glibc.close(fd)
        #else
        _ = Musl.close(fd)
        #endif
    }

    private func readEvents() {
        var buffer: [UInt8] = []
        let descriptors = WaylandDescriptors()
        reading: while true {
            guard let (chunk, received) = UnixRights.receive(fd) else { break }
            descriptors.add(received)
            buffer += chunk
            var start = 0
            while true {
                let size: Int?
                do {
                    size = try WaylandWire.size(of: buffer[start...])
                } catch {
                    break reading
                }
                guard let size, buffer.count - start >= size else { break }
                var event = WaylandEvent(message: buffer[start..<(start + size)], descriptors: descriptors)
                dispatch(&event)
                start += size
            }
            if start > 0 { buffer.removeFirst(start) }
        }
        let handlers = state.withLock { state in
            state.closed = true
            return state.error ?? WaylandError.closed
        }
        for handler in failures.withLock({ $0 }) { handler(handlers) }
        Self.closeSocket(fd)
    }

    private func dispatch(_ event: inout WaylandEvent) {
        if event.object == Self.display {
            if event.opcode == 0, let object = try? event.uint(), let code = try? event.uint() {
                let message = (try? event.string()) ?? ""
                state.withLock { $0.error = .protocolError(object: object, code: code, message: message) }
            } else if event.opcode == 1, let id = try? event.uint() {
                forget(id)
            }
            return
        }
        guard let listener = state.withLock({ $0.listeners[event.object] }) else { return }
        try? listener(&event)
    }
}
