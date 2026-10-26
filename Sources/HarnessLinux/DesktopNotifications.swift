import Foundation
import HarnessDBus
import HarnessProtocol
import Synchronization

/// Desktop notifications through `org.freedesktop.Notifications` on the session bus, with
/// buttons whose choice comes back.
public enum DesktopNotifications {
    static let name = "org.freedesktop.Notifications"
    static let path = "/org/freedesktop/Notifications"

    /// A notification's button: the name it reports and the text it shows.
    public struct Action: Sendable, Equatable {
        public var name: String
        public var label: String

        public init(_ name: String, _ label: String) {
            self.name = name
            self.label = label
        }
    }

    /// Shows a notification and waits for a button, returning its name, or nil when the
    /// notification is dismissed, clicked elsewhere, times out or can't be shown.
    public static func ask(
        appName: String, title: String, body: String, actions: [Action], critical: Bool = false, timeout: Duration
    ) async -> String? {
        guard let connection = try? await SessionBus.shared.connection() else { return nil }
        let rule = "type='signal',interface='\(name)',path='\(path)'"
        guard (try? await connection.addMatch(rule)) != nil else { return nil }
        let shown = Mutex<UInt32?>(nil)
        let early = Mutex<[(UInt32, String?)]>([])
        let answer = Mutex<CheckedContinuation<String?, Never>?>(nil)
        let handler = connection.onSignal { message in
            guard message.path == path, let id = message.body.first?.int.map(UInt32.init) else { return }
            let choice: String? = message.member == "ActionInvoked" ? message.body.dropFirst().first?.string : nil
            guard message.member == "ActionInvoked" || message.member == "NotificationClosed" else { return }
            guard let mine = shown.withLock({ $0 }) else {
                early.withLock { $0.append((id, choice)) }
                return
            }
            guard id == mine else { return }
            answer.withLock { $0.take() }?.resume(returning: choice == "default" ? nil : choice)
        }
        defer {
            connection.removeSignalHandler(handler)
            Task { try? await connection.removeMatch(rule) }
        }
        let milliseconds = Int32(clamping: timeout.components.seconds * 1000)
        let arguments: [DBusValue] = [
            .string(appName), .uint32(0), .string(""), .string(title), .string(body),
            .array(element: "s", actions.flatMap { [DBusValue.string($0.name), .string($0.label)] }),
            .properties(["urgency": .byte(critical ? 2 : 1)]), .int32(milliseconds),
        ]
        guard let id = try? await connection.call(name, path, name, "Notify", arguments).first?.int.map(UInt32.init) else { return nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            answer.withLock { $0 = continuation }
            shown.withLock { $0 = id }
            if let (_, choice) = early.withLock({ $0.first { $0.0 == id } }) {
                answer.withLock { $0.take() }?.resume(returning: choice == "default" ? nil : choice)
                return
            }
            Task {
                try? await Task.sleep(for: timeout + .seconds(5))
                guard let pending = answer.withLock({ $0.take() }) else { return }
                _ = try? await connection.call(name, path, name, "CloseNotification", [.uint32(id)])
                pending.resume(returning: nil)
            }
        }
    }

    /// Shows a notification without buttons.
    public static func tell(appName: String, title: String, body: String) async {
        guard let connection = try? await SessionBus.shared.connection() else { return }
        _ = try? await connection.call(
            name, path, name, "Notify",
            [.string(appName), .uint32(0), .string(""), .string(title), .string(body), .array(element: "s", []), .properties([:]), .int32(-1)]
        )
    }

    /// Whether a notification server is running on the session bus.
    public static func available() async -> Bool {
        guard let connection = try? await SessionBus.shared.connection() else { return false }
        let owner = try? await connection.call(
            "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "NameHasOwner", [.string(name)]
        ).first?.bool
        return owner == true
    }
}
