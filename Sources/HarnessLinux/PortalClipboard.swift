import Foundation
import HarnessDBus
import HarnessProtocol
import Synchronization

/// The clipboard through the portal's Clipboard interface, inside a RemoteDesktop session: how
/// GNOME, which has no data control, lets the harness read and set it.
final class PortalClipboard: Sendable {
    static let interface = "org.freedesktop.portal.Clipboard"

    private struct State {
        var types: [String] = []
        var known = false
        var owner = false
        var serving: [String: Data] = [:]
        var handler: UUID?
    }

    let connection: DBusConnection
    let session: String
    private let state = Mutex(State())

    private init(connection: DBusConnection, session: String) {
        self.connection = connection
        self.session = session
    }

    static let rule = "type='signal',interface='\(interface)'"

    /// Asks for the clipboard in a session that hasn't started yet, and follows its changes.
    static func request(on connection: DBusConnection, session: String) async throws -> PortalClipboard {
        let clipboard = PortalClipboard(connection: connection, session: session)
        try await connection.addMatch(rule)
        let handler = connection.onSignal { [weak clipboard] message in clipboard?.handle(message) }
        clipboard.state.withLock { $0.handler = handler }
        _ = try await connection.call(Portal.destination, Portal.path, interface, "RequestClipboard", [.objectPath(session), .properties([:])])
        return clipboard
    }

    func handle(_ message: DBusMessage) {
        guard message.interface == Self.interface, message.body.first?.string == session else { return }
        switch message.member {
        case "SelectionOwnerChanged":
            let options = message.body.dropFirst().first?.dictionary ?? [:]
            state.withLock { state in
                state.types = options["mime_types"]?.elements?.compactMap(\.string) ?? []
                state.owner = options["session_is_owner"]?.bool ?? false
                state.known = true
            }
        case "SelectionTransfer":
            guard message.body.count >= 3, let mime = message.body[1].string, let serial = message.body[2].int.map(UInt32.init) else { return }
            let data = state.withLock { $0.serving[mime] }
            Task { await self.transfer(data, serial: serial) }
        default:
            break
        }
    }

    private func transfer(_ data: Data?, serial: UInt32) async {
        let path = Portal.path
        guard let data,
              let reply = try? await connection.callForReply(Portal.destination, path, Self.interface, "SelectionWrite", [.objectPath(session), .uint32(serial)]),
              let index = reply.body.first?.int, index < reply.fds.count else {
            _ = try? await connection.call(Portal.destination, path, Self.interface, "SelectionWriteDone", [.objectPath(session), .uint32(serial), .boolean(false)])
            return
        }
        UnixPipe.writeAll(data, to: reply.fds[index])
        _ = try? await connection.call(Portal.destination, path, Self.interface, "SelectionWriteDone", [.objectPath(session), .uint32(serial), .boolean(true)])
    }

    /// The types of what's on the clipboard.
    var types: [String] { state.withLock { $0.types } }

    /// Waits until the portal has said what's on the clipboard, which it does soon after the
    /// session starts.
    func waitUntilKnown(timeout: Duration = .seconds(2)) async {
        let deadline = ContinuousClock.now + timeout
        while !state.withLock({ $0.known }), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Whether what the harness last put on the clipboard is still there.
    var ownsSelection: Bool { state.withLock { $0.owner } }

    /// What's on the clipboard in one type, or nil when it isn't offered.
    func read(_ mime: String) async throws -> Data? {
        guard types.contains(mime) else { return nil }
        for attempt in 0..<2 {
            let reply = try await connection.callForReply(
                Portal.destination, Portal.path, Self.interface, "SelectionRead", [.objectPath(session), .string(mime)]
            )
            guard let index = reply.body.first?.int, index < reply.fds.count else { return nil }
            let data = try await UnixPipe.readAll(reply.fds[index], timeout: .seconds(5))
            if !data.isEmpty || attempt == 1 { return data }
            try await Task.sleep(for: .milliseconds(300))
        }
        return nil
    }

    /// Puts data on the clipboard in the given types, served while the session lasts.
    func set(_ items: [String: Data]) async throws {
        state.withLock { state in
            state.serving = items
            state.owner = true
            state.types = items.keys.sorted()
        }
        _ = try await connection.call(
            Portal.destination, Portal.path, Self.interface, "SetSelection",
            [.objectPath(session), .properties(["mime_types": .array(element: "s", items.keys.sorted().map { .string($0) })])]
        )
    }

    /// Stops following the clipboard, as the session ends.
    func close() {
        if let handler = state.withLock({ $0.handler }) { connection.removeSignalHandler(handler) }
        Task { [connection] in try? await connection.removeMatch(Self.rule) }
    }
}
