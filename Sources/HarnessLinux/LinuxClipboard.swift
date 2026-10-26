import Foundation
import HarnessCore
import HarnessProtocol
import HarnessWayland

/// The clipboard on Linux: read for agents, and borrowed to paste text, with what the user
/// copied put back. Sway and KWin offer it through data control, GNOME through the portal,
/// which can read it but only hold what it sets while a remote desktop session lasts.
public actor LinuxClipboard {
    public static let shared = LinuxClipboard()

    /// The types text is offered in, as apps look for it.
    static let textTypes = ["text/plain;charset=utf-8", "text/plain", "UTF8_STRING", "TEXT", "STRING"]
    /// What password managers (KeePassXC, KDE's) mark a secret with.
    static let secretHint = "x-kde-passwordManagerHint"
    /// The most of one type kept to put back after pasting.
    static let largestKept = 16 * 1024 * 1024

    private var current: WaylandClipboard?

    func clipboard() async throws -> any ClipboardAccess {
        if LinuxPermissions.Desktop.current() == .gnome {
            let clipboard = try await PortalInputSessions.shared.inputWithClipboard().clipboard!
            await clipboard.waitUntilKnown()
            return clipboard
        }
        if let current, !current.isClosed { return current }
        do {
            let made = try await WaylandClipboard.make(on: try WaylandConnection.connect())
            current = made
            return made
        } catch WaylandError.missingGlobal {
            let desktop = LinuxPermissions.Desktop.current()
            throw RPCError(
                code: RPCErrorCode.failed,
                message: "\(desktop.label) doesn't offer data control, which the harness reaches the clipboard through."
            )
        }
    }

    /// What's on the clipboard: its types, and its text unless a password manager marked it secret.
    public func read() async throws -> ClipboardMethod.Result {
        let clipboard = try await clipboard()
        let types = clipboard.types
        let concealed = try await Self.isSecret(clipboard)
        var text: String?
        if !concealed {
            for type in Self.textTypes where types.contains(type) {
                guard let data = try await clipboard.read(type) else { continue }
                text = String(decoding: data, as: UTF8.self)
                if !data.isEmpty { break }
            }
        }
        return ClipboardMethod.Result(types: types, text: text, concealed: concealed, items: types.isEmpty ? 0 : 1)
    }

    static func isSecret(_ clipboard: any ClipboardAccess) async throws -> Bool {
        guard clipboard.types.contains(secretHint) else { return false }
        let hint = try await clipboard.read(secretHint).map { String(decoding: $0, as: UTF8.self) }
        return hint?.trimmingCharacters(in: .whitespacesAndNewlines) == "secret"
    }

    /// Puts `text` on the clipboard while `body` runs, then puts back what was there, unless
    /// something else changed the clipboard meanwhile; says whether it was put back.
    @discardableResult
    public func borrow(for text: String, _ body: @Sendable () async throws -> Void) async throws -> Bool {
        let clipboard = try await clipboard()
        var saved: [String: Data] = [:]
        for type in clipboard.types {
            if let data = try? await clipboard.read(type), data.count <= Self.largestKept { saved[type] = data }
        }
        try await clipboard.set(Dictionary(uniqueKeysWithValues: Self.textTypes.map { ($0, Data(text.utf8)) }))
        let outcome = await Result { try await body() }
        try await Task.sleep(for: .milliseconds(300))
        let putBack = clipboard.ownsSelection
        if putBack {
            if saved.isEmpty { try? await clipboard.clear() } else { try? await clipboard.set(saved) }
        }
        try outcome.get()
        return putBack
    }
}

/// A clipboard the harness can read and set: data control, or the portal's.
protocol ClipboardAccess: Sendable {
    var types: [String] { get }
    var ownsSelection: Bool { get }
    func read(_ mime: String) async throws -> Data?
    func set(_ items: [String: Data]) async throws
    func clear() async throws
}

extension PortalClipboard: ClipboardAccess {
    func clear() async throws {
        try await set([:])
    }
}

extension WaylandClipboard: ClipboardAccess {
    func read(_ mime: String) async throws -> Data? {
        try await read(mime, timeout: .seconds(5))
    }
}
