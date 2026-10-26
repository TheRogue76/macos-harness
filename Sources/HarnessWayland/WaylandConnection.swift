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
        var offset = 0
        var pending = fds
        while offset < bytes.count {
            let sent = try sendChunk(Array(bytes[offset...]), fds: pending)
            pending = []
            offset += sent
        }
    }

    /// Sends bytes, with descriptors attached as SCM_RIGHTS, returning how many bytes went.
    private func sendChunk(_ bytes: [UInt8], fds: [Int32]) throws -> Int {
        let control = Self.rightsMessage(fds)
        let body = UnsafeMutableRawPointer.allocate(byteCount: max(bytes.count, 1), alignment: 8)
        let controlBuffer = UnsafeMutableRawPointer.allocate(byteCount: max(control.count, 1), alignment: 8)
        let vector = UnsafeMutablePointer<iovec>.allocate(capacity: 1)
        let message = UnsafeMutablePointer<msghdr>.allocate(capacity: 1)
        defer {
            unsafe body.deallocate()
            unsafe controlBuffer.deallocate()
            unsafe vector.deallocate()
            unsafe message.deallocate()
        }
        unsafe body.copyMemory(from: bytes, byteCount: bytes.count)
        unsafe controlBuffer.copyMemory(from: control, byteCount: control.count)
        unsafe vector.initialize(to: iovec(iov_base: body, iov_len: bytes.count))
        unsafe message.initialize(to: msghdr())
        unsafe message.pointee.msg_iov = vector
        unsafe message.pointee.msg_iovlen = 1
        if !control.isEmpty {
            unsafe message.pointee.msg_control = controlBuffer
            unsafe message.pointee.msg_controllen = control.count
        }
        while true {
            let sent = unsafe sendmsg(fd, message, Int32(MSG_NOSIGNAL))
            if sent < 0, errno == EINTR { continue }
            guard sent >= 0 else { throw WaylandError.closed }
            return sent
        }
    }

    /// A control message carrying descriptors: a `cmsghdr` (its length as a `size_t`, then the
    /// level and type) followed by the descriptors, padded to a `size_t`. Empty for none.
    static func rightsMessage(_ fds: [Int32]) -> [UInt8] {
        guard !fds.isEmpty else { return [] }
        let word = MemoryLayout<Int>.size
        let header = word + 8
        let length = header + fds.count * 4
        var bytes: [UInt8] = []
        for shift in stride(from: 0, to: word * 8, by: 8) { bytes.append(UInt8(truncatingIfNeeded: length >> shift)) }
        WaylandWire.append(UInt32(bitPattern: SOL_SOCKET), to: &bytes)
        WaylandWire.append(UInt32(bitPattern: Int32(SCM_RIGHTS)), to: &bytes)
        for descriptor in fds { WaylandWire.append(UInt32(bitPattern: descriptor), to: &bytes) }
        while bytes.count % word != 0 { bytes.append(0) }
        return bytes
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
            guard let (chunk, received) = receiveChunk() else { break }
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

    /// Reads what the compositor sent, with any descriptors attached; nil once the connection ends.
    private func receiveChunk() -> ([UInt8], [Int32])? {
        let capacity = 65_536
        let controlCapacity = 1024
        let body = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 8)
        let controlBuffer = UnsafeMutableRawPointer.allocate(byteCount: controlCapacity, alignment: 8)
        let vector = UnsafeMutablePointer<iovec>.allocate(capacity: 1)
        let message = UnsafeMutablePointer<msghdr>.allocate(capacity: 1)
        defer {
            unsafe body.deallocate()
            unsafe controlBuffer.deallocate()
            unsafe vector.deallocate()
            unsafe message.deallocate()
        }
        while true {
            unsafe vector.initialize(to: iovec(iov_base: body, iov_len: capacity))
            unsafe message.initialize(to: msghdr())
            unsafe message.pointee.msg_iov = vector
            unsafe message.pointee.msg_iovlen = 1
            unsafe message.pointee.msg_control = controlBuffer
            unsafe message.pointee.msg_controllen = controlCapacity
            let count = unsafe recvmsg(fd, message, Int32(MSG_CMSG_CLOEXEC))
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return nil }
            let bytes = unsafe [UInt8](UnsafeRawBufferPointer(start: body, count: count))
            let controlLength = Int(unsafe message.pointee.msg_controllen)
            let control = unsafe [UInt8](UnsafeRawBufferPointer(start: controlBuffer, count: controlLength))
            return (bytes, Self.descriptors(inControl: control))
        }
    }

    /// The descriptors in SCM_RIGHTS control messages: each a `cmsghdr` (its length as a `size_t`,
    /// then the level and type) followed by the descriptors, padded to a `size_t`.
    static func descriptors(inControl control: [UInt8]) -> [Int32] {
        let word = MemoryLayout<Int>.size
        let header = word + 8
        var found: [Int32] = []
        var start = 0
        while start + header <= control.count {
            var length = 0
            for index in 0..<word { length |= Int(control[start + index]) << (index * 8) }
            guard length >= header, start + length <= control.count else { break }
            let level = Int32(bitPattern: WaylandWire.word(control[...], at: start + word))
            let type = Int32(bitPattern: WaylandWire.word(control[...], at: start + word + 4))
            if level == SOL_SOCKET, type == Int32(SCM_RIGHTS) {
                var offset = start + header
                while offset + 4 <= start + length {
                    found.append(Int32(bitPattern: WaylandWire.word(control[...], at: offset)))
                    offset += 4
                }
            }
            start += (length + word - 1) / word * word
        }
        return found
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
