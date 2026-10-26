import Foundation
import Synchronization

/// Whether the seat has had no input for a while, through `ext_idle_notifier_v1`: the
/// compositor says when the seat goes idle and when input wakes it.
public final class WaylandIdle: Sendable {
    private struct State {
        var idle = false
        var resumed: ContinuousClock.Instant?
    }

    let connection: WaylandConnection
    private let state = Mutex(State())

    private init(connection: WaylandConnection) {
        self.connection = connection
    }

    /// Watches for `timeout` without input; fails when the compositor doesn't offer the notifier.
    public static func make(on connection: WaylandConnection, timeout: Duration) async throws -> WaylandIdle {
        let (registry, globals) = try await connection.globals()
        guard let notifierGlobal = globals.first(where: { $0.interface == "ext_idle_notifier_v1" }) else {
            throw WaylandError.missingGlobal("ext_idle_notifier_v1")
        }
        guard let seatGlobal = globals.first(where: { $0.interface == "wl_seat" }) else { throw WaylandError.missingGlobal("wl_seat") }
        let seat = try connection.bind(seatGlobal, registry: registry, version: 1)
        let notifier = try connection.bind(notifierGlobal, registry: registry, version: 1)
        let watcher = WaylandIdle(connection: connection)
        let notification = connection.allocate()
        connection.listen(notification) { [weak watcher] event in
            watcher?.state.withLock { state in
                switch event.opcode {
                case 0: state.idle = true
                case 1:
                    state.idle = false
                    state.resumed = .now
                default: break
                }
            }
        }
        let milliseconds = UInt32(clamping: timeout.components.seconds * 1000 + timeout.components.attoseconds / 1_000_000_000_000_000)
        try connection.send(notifier, 1, [.newID(notification), .uint(milliseconds), .object(seat)])
        try await connection.roundtrip()
        return watcher
    }

    /// Whether the seat has been idle for the timeout, and when input last woke it.
    public var status: (idle: Bool, resumed: ContinuousClock.Instant?) {
        state.withLock { ($0.idle, $0.resumed) }
    }

    /// Whether the connection to the compositor has ended.
    public var isClosed: Bool { connection.isClosed }
}
