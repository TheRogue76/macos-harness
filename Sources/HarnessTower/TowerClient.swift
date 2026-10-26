import CGtk
import Foundation
import Glibc
import HarnessClient
import HarnessProtocol

/// Talks to the helper that started the panel, on a queue of its own so GTK's thread never
/// waits on the socket; answers come back on GTK's thread.
final class TowerClient: @unchecked Sendable {
    let token: String
    let socket: String
    let variant: HarnessVariant
    private let queue = DispatchQueue(label: "tower.client")
    private var connection: HarnessConnection?

    /// Reads what the helper passed, then makes the panel non-dumpable and drops the token from
    /// its environment, so other processes of the user can't read it from `/proc`.
    init?(environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard let token = environment["MACOS_HARNESS_TOWER_TOKEN"], let socket = environment["MACOS_HARNESS_TOWER_SOCKET"] else { return nil }
        _ = harness_forbid_dumps()
        unsafe unsetenv("MACOS_HARNESS_TOWER_TOKEN")
        self.token = token
        self.socket = socket
        variant = HarnessVariant(rawValue: environment["MACOS_HARNESS_VARIANT"] ?? "") ?? .release
    }

    private func call<M: RPCMethod>(_ method: M.Type, _ params: M.Params) throws -> M.Result {
        do {
            let open = try connection ?? HarnessConnection.connect(socketPath: socket, variant: variant)
            connection = open
            return try open.call(method, params, timeout: 10)
        } catch {
            connection = nil
            throw error
        }
    }

    /// Reads the helper's state, then hands it to `done` on GTK's thread (nil when the helper
    /// didn't answer).
    func state(_ done: @escaping (TowerState?) -> Void) {
        let callback = GtkThread(done)
        queue.async {
            let state = try? self.call(TowerStateMethod.self, .init(token: self.token))
            Gtk.onMain { callback.value(state) }
        }
    }

    /// Asks the helper to do something for the user, then calls `done` on GTK's thread.
    func act(_ action: TowerActionMethod.Action, key: String? = nil, _ done: @escaping () -> Void = {}) {
        let callback = GtkThread(done)
        queue.async {
            _ = try? self.call(TowerActionMethod.self, .init(token: self.token, action: action, key: key))
            Gtk.onMain { callback.value() }
        }
    }
}

/// Something made on GTK's thread and only used there, carried through the client's queue.
final class GtkThread<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}
