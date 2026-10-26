#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import HarnessCore
import HarnessDBus
import HarnessProtocol
import HarnessWayland

/// Real input on GNOME and KDE through the RemoteDesktop portal: a session with pointer and
/// keyboard devices. The desktop asks the user once; the restore token it hands back is kept so
/// later sessions start without asking, and it closes after a while unused.
actor PortalInputSessions {
    static let shared = PortalInputSessions()
    static let idle = Duration.seconds(30)

    private var current: PortalInput?
    private var generation = 0

    func input() async throws -> PortalInput {
        generation += 1
        let mine = generation
        defer { scheduleClose(after: mine) }
        if let current { return current }
        let made = try await PortalInput.start()
        current = made
        return made
    }

    /// A session with the clipboard. A permission GNOME saved before the harness asked for the
    /// clipboard restores a session without it, so that permission is dropped and GNOME asks again.
    func inputWithClipboard() async throws -> PortalInput {
        let input = try await input()
        if input.clipboard != nil { return input }
        await close()
        try? FileManager.default.removeItem(atPath: PortalInput.tokenPath)
        let fresh = try await self.input()
        guard fresh.clipboard != nil else {
            throw RPCError(code: RPCErrorCode.failed, message: "GNOME didn't hand the clipboard to the remote desktop session.")
        }
        return fresh
    }

    /// Closes the session now, so the next input starts a new one.
    func close() async {
        generation += 1
        guard let current else { return }
        self.current = nil
        await current.close()
    }

    private func scheduleClose(after use: Int) {
        Task {
            try? await Task.sleep(for: Self.idle)
            await closeIfUnused(since: use)
        }
    }

    private func closeIfUnused(since use: Int) async {
        guard use == generation, let current else { return }
        self.current = nil
        await current.close()
    }
}

/// One RemoteDesktop portal session.
final class PortalInput: RealInput, @unchecked Sendable {
    static let remoteDesktop = "org.freedesktop.portal.RemoteDesktop"

    let connection: DBusConnection
    let session: String
    /// The clipboard, on desktops that hand it over with the session (GNOME).
    let clipboard: PortalClipboard?
    private var held: [UInt32] = []

    init(connection: DBusConnection, session: String, clipboard: PortalClipboard? = nil) {
        self.connection = connection
        self.session = session
        self.clipboard = clipboard
    }

    /// Where the restore token is kept: in the harness's state folder, readable only by the user,
    /// one per desktop.
    static var tokenPath: String {
        let state = ProcessInfo.processInfo.environment["XDG_STATE_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? "\(HarnessPaths.homeDirectory)/.local/state"
        let desktop = LinuxPermissions.Desktop.current() == .kde ? "kde" : "gnome"
        return "\(state)/macos-harness/\(desktop)-remote-desktop-token"
    }

    /// Starts a session, asking the user the first time.
    static func start() async throws -> PortalInput {
        let connection = try await SessionBus.shared.connection()
        let created = try await Portal.request(
            remoteDesktop, "CreateSession", [], options: ["session_handle_token": .string("harness\(UInt32.random(in: 0...UInt32.max))")],
            on: connection
        )
        guard let session = created["session_handle"]?.string else {
            throw RPCError(code: RPCErrorCode.failed, message: "The RemoteDesktop portal made no session.")
        }
        var devices: [String: DBusValue] = ["types": .uint32(3), "persist_mode": .uint32(2)]
        if let token = try? String(contentsOfFile: tokenPath, encoding: .utf8), !token.isEmpty {
            devices["restore_token"] = .string(token.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        _ = try await Portal.request(remoteDesktop, "SelectDevices", [.objectPath(session)], options: devices, on: connection)
        var clipboard = LinuxPermissions.Desktop.current() == .gnome
            ? try? await PortalClipboard.request(on: connection, session: session)
            : nil
        let started = try await Portal.request(
            remoteDesktop, "Start", [.objectPath(session), .string("")], options: [:], on: connection, timeout: .seconds(120)
        )
        if started["clipboard_enabled"]?.bool != true {
            clipboard?.close()
            clipboard = nil
        }
        if let token = started["restore_token"]?.string {
            try? FileManager.default.createDirectory(atPath: (tokenPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            _ = FileManager.default.createFile(atPath: tokenPath, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600])
        }
        return PortalInput(connection: connection, session: session, clipboard: clipboard)
    }

    func notify(_ method: String, _ arguments: [DBusValue], options: [String: DBusValue] = [:]) async throws {
        _ = try await connection.call(
            Portal.destination, Portal.path, Self.remoteDesktop, method, [.objectPath(session), .properties(options)] + arguments
        )
    }

    /// Moves the pointer to a point in layout points.
    func move(to point: CGPoint) async throws {
        try await notify("NotifyPointerMotion", [.double(-100_000), .double(-100_000)])
        try await notify("NotifyPointerMotion", [.double(point.x), .double(point.y)])
    }

    func button(_ button: UInt32, pressed: Bool) async throws {
        try await notify("NotifyPointerButton", [.int32(Int32(button)), .uint32(pressed ? 1 : 0)])
    }

    func scroll(dx: Double, dy: Double) async throws {
        guard LinuxPermissions.Desktop.current() == .kde else {
            return try await notify("NotifyPointerAxis", [.double(-dx), .double(-dy)], options: ["finish": .boolean(true)])
        }
        for (axis, distance) in [(UInt32(0), dy), (1, dx)] where distance != 0 {
            let steps = Int32((-distance / Self.pointsPerWheelStep).rounded())
            try await notify("NotifyPointerAxisDiscrete", [.uint32(axis), .int32(steps == 0 ? (distance < 0 ? 1 : -1) : steps)])
        }
    }

    /// How far one wheel step scrolls, in points, for desktops that take scrolling only as steps.
    static let pointsPerWheelStep = 2.4

    func hold(_ modifiers: UInt32) async throws {
        let wanted = Self.modifierKeysyms(modifiers)
        for keysym in held where !wanted.contains(keysym) { try await key(keysym, pressed: false) }
        for keysym in wanted where !held.contains(keysym) { try await key(keysym, pressed: true) }
        held = wanted
    }

    func type(_ text: String) async throws {
        for character in text {
            let keysym = Self.keysym(XKBKeymap.keysym(for: character))
            try await key(keysym, pressed: true)
            try await key(keysym, pressed: false)
        }
    }

    func tap(_ key: String, modifiers: UInt32) async throws {
        try await hold(modifiers)
        let keysym = Self.keysym(key)
        try await self.key(keysym, pressed: true)
        try await self.key(keysym, pressed: false)
        try await hold(0)
    }

    func key(_ keysym: UInt32, pressed: Bool) async throws {
        try await notify("NotifyKeyboardKeysym", [.int32(Int32(bitPattern: keysym)), .uint32(pressed ? 1 : 0)])
    }

    /// Waits until the portal has handled the notifications sent so far.
    func flush() async throws {
        _ = try await connection.property(Portal.destination, Portal.path, Self.remoteDesktop, "version")
    }

    func release() async {
        try? await hold(0)
    }

    func close() async {
        clipboard?.close()
        try? await hold(0)
        _ = try? await connection.call(Portal.destination, session, "org.freedesktop.portal.Session", "Close")
    }

    /// The keysyms of XKB's real modifier masks.
    static func modifierKeysyms(_ modifiers: UInt32) -> [UInt32] {
        [(XKBKeymap.shift, UInt32(0xFFE1)), (XKBKeymap.control, 0xFFE3), (XKBKeymap.alt, 0xFFE9), (XKBKeymap.superKey, 0xFFEB)]
            .filter { modifiers & $0.0 != 0 }.map(\.1)
    }

    /// A keysym from its XKB name: `Uxxxx` for a character (Latin-1 characters keep their own
    /// code, others are 0x01000000 plus the code point), or a named key.
    static func keysym(_ name: String) -> UInt32 {
        if name.hasPrefix("U"), let point = UInt32(name.dropFirst(), radix: 16) {
            return point < 0x100 ? point : 0x0100_0000 + point
        }
        let named: [String: UInt32] = [
            "Return": 0xFF0D, "Tab": 0xFF09, "Escape": 0xFF1B, "BackSpace": 0xFF08, "Delete": 0xFFFF, "Home": 0xFF50, "End": 0xFF57,
            "Prior": 0xFF55, "Next": 0xFF56, "Left": 0xFF51, "Up": 0xFF52, "Right": 0xFF53, "Down": 0xFF54, "space": 0x20,
            "Shift_L": 0xFFE1, "Control_L": 0xFFE3, "Alt_L": 0xFFE9, "Super_L": 0xFFEB,
        ]
        if let code = named[name] { return code }
        if name.hasPrefix("F"), let number = UInt32(name.dropFirst()), (1...12).contains(number) { return 0xFFBD + number }
        return 0
    }
}
