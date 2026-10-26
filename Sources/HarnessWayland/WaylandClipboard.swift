import Foundation
import Synchronization
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// The clipboard through data control (`ext_data_control_v1`, or wlroots'
/// `zwlr_data_control_v1`, which has the same requests and events): reading what's on it and
/// putting something there, without a window.
public final class WaylandClipboard: Sendable {
    private struct State {
        var offers: [UInt32: [String]] = [:]
        var selection: UInt32?
        var source: UInt32?
        var cancelled = false
    }

    let connection: WaylandConnection
    let manager: UInt32
    let device: UInt32
    private let state = Mutex(State())

    private init(connection: WaylandConnection, manager: UInt32, device: UInt32) {
        self.connection = connection
        self.manager = manager
        self.device = device
    }

    /// The interfaces it can use, best first.
    public static let interfaces = ["ext_data_control_manager_v1", "zwlr_data_control_manager_v1"]

    /// Binds data control on the seat and waits for the current selection.
    public static func make(on connection: WaylandConnection) async throws -> WaylandClipboard {
        let (registry, globals) = try await connection.globals()
        guard let global = interfaces.lazy.compactMap({ name in globals.first { $0.interface == name } }).first else {
            throw WaylandError.missingGlobal(interfaces[0])
        }
        guard let seatGlobal = globals.first(where: { $0.interface == "wl_seat" }) else { throw WaylandError.missingGlobal("wl_seat") }
        let seat = try connection.bind(seatGlobal, registry: registry, version: 1)
        let manager = try connection.bind(global, registry: registry, version: 1)
        let device = connection.allocate()
        let clipboard = WaylandClipboard(connection: connection, manager: manager, device: device)
        connection.listen(device) { [weak clipboard] event in try clipboard?.handleDevice(&event) }
        try connection.send(manager, 1, [.newID(device), .object(seat)])
        try await connection.roundtrip()
        return clipboard
    }

    private func handleDevice(_ event: inout WaylandEvent) throws {
        switch event.opcode {
        case 0:
            let offer = try event.uint()
            state.withLock { $0.offers[offer] = [] }
            connection.listen(offer) { [weak self] event in
                guard event.opcode == 0, let mime = try event.string() else { return }
                self?.state.withLock { $0.offers[offer, default: []].append(mime) }
            }
        case 1:
            let offer = try event.uint()
            let previous = state.withLock { state -> UInt32? in
                defer { state.selection = offer == 0 ? nil : offer }
                return state.selection
            }
            if let previous, previous != offer { discard(previous) }
        default:
            break
        }
    }

    private func discard(_ offer: UInt32) {
        try? connection.send(offer, 1)
        connection.forget(offer)
        state.withLock { _ = $0.offers.removeValue(forKey: offer) }
    }

    /// The types of what's on the clipboard; empty when it's empty.
    public var types: [String] {
        state.withLock { state in state.selection.flatMap { state.offers[$0] } ?? [] }
    }

    /// What's on the clipboard in one type, or nil when it isn't offered.
    public func read(_ mime: String, timeout: Duration = .seconds(5)) async throws -> Data? {
        guard let offer = state.withLock({ state in state.selection.flatMap { state.offers[$0]?.contains(mime) == true ? $0 : nil } }) else {
            return nil
        }
        let (readEnd, writeEnd) = try Pipe.make()
        try connection.send(offer, 0, [.string(mime), .fd(writeEnd)])
        Pipe.close(writeEnd)
        try await connection.roundtrip()
        return try await Pipe.readAll(readEnd, timeout: timeout)
    }

    /// Puts data on the clipboard in the given types, served from this connection until
    /// something else takes the clipboard.
    public func set(_ items: [String: Data]) async throws {
        let source = connection.allocate()
        let payload = items
        connection.listen(source) { [weak self] event in
            switch event.opcode {
            case 0:
                let mime = try event.string() ?? ""
                let descriptor = try event.fd()
                Pipe.writeAll(payload[mime] ?? Data(), to: descriptor)
            case 1:
                self?.state.withLock { if $0.source == source { $0.cancelled = true } }
            default:
                break
            }
        }
        try connection.send(manager, 0, [.newID(source)])
        for mime in items.keys.sorted() { try connection.send(source, 0, [.string(mime)]) }
        try connection.send(device, 0, [.object(source)])
        let old = state.withLock { state -> UInt32? in
            defer {
                state.source = source
                state.cancelled = false
            }
            return state.source
        }
        if let old {
            try? connection.send(old, 1)
            connection.forget(old)
        }
        try await connection.roundtrip()
    }

    /// Whether what this connection last put on the clipboard is still there.
    public var ownsSelection: Bool {
        state.withLock { $0.source != nil && !$0.cancelled }
    }

    /// Empties the clipboard.
    public func clear() async throws {
        try connection.send(device, 0, [.object(0)])
        try await connection.roundtrip()
    }

    public func close() {
        connection.close()
    }

    /// Whether the connection to the compositor has ended.
    public var isClosed: Bool { connection.isClosed }
}

/// Pipes for handing clipboard data across.
enum Pipe {
    static func make() throws -> (read: Int32, write: Int32) {
        var ends: [Int32] = [0, 0]
        guard unsafe pipe(&ends) == 0 else { throw WaylandError.closed }
        for end in ends { _ = fcntl(end, F_SETFD, FD_CLOEXEC) }
        return (ends[0], ends[1])
    }

    static func close(_ fd: Int32) {
        #if canImport(Glibc)
        _ = Glibc.close(fd)
        #else
        _ = Musl.close(fd)
        #endif
    }

    /// Reads to the end on another thread, closing the descriptor; gives up after `timeout`.
    static func readAll(_ fd: Int32, timeout: Duration) async throws -> Data {
        try await withThrowingTaskGroup(of: Data?.self) { group in
            group.addTask {
                await withCheckedContinuation { continuation in
                    Thread.detachNewThread {
                        var data = Data()
                        var chunk = [UInt8](repeating: 0, count: 65_536)
                        while true {
                            let count = unsafe read(fd, &chunk, chunk.count)
                            if count < 0, errno == EINTR { continue }
                            guard count > 0 else { break }
                            data.append(contentsOf: chunk[0..<count])
                        }
                        close(fd)
                        continuation.resume(returning: data)
                    }
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                return nil
            }
            guard let first = try await group.next(), let data = first else {
                throw WaylandError.malformed("the clipboard's owner didn't send its data")
            }
            group.cancelAll()
            return data
        }
    }

    /// Writes everything on another thread, then closes the descriptor.
    static func writeAll(_ data: Data, to fd: Int32) {
        Thread.detachNewThread {
            let bytes = [UInt8](data)
            var offset = 0
            while offset < bytes.count {
                let written = bytes.withUnsafeBufferPointer { buffer in
                    unsafe write(fd, buffer.baseAddress! + offset, bytes.count - offset)
                }
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { break }
                offset += written
            }
            close(fd)
        }
    }
}
