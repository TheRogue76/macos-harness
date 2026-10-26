import Foundation
import HarnessCore
import HarnessDBus
import HarnessProtocol

/// The stop shortcut on GNOME and KDE, through the GlobalShortcuts portal: bound once with the
/// user's approval, then listened for whenever the helper runs.
public actor LinuxShortcuts {
    public static let shared = LinuxShortcuts()

    init() {}
    static let interface = "org.freedesktop.portal.GlobalShortcuts"
    static let stopID = "stop-agents"
    /// Ctrl+Alt+Super+., the stop hotkey's keys on macOS with Super for ⌘.
    static let preferredTrigger = "CTRL+ALT+LOGO+period"

    /// The app ID the shortcut is bound for; the portal needs one, and a connection can register
    /// only before its first portal call, so the shortcut has a connection of its own.
    private var appID = "io.github.therogue76.MacosHarness"
    private var appName = "macOS Harness"
    private var command = "macos-harness"

    /// Names the helper's variant and the CLI's path, before `start`.
    public func configure(appID: String, appName: String, command: String) {
        self.appID = appID
        self.appName = appName
        self.command = command
    }

    /// The desktop entry the portal looks the app ID up in: a hidden one, which packages ship
    /// and `grant` writes for the user when none is installed.
    var desktopEntry: String {
        """
        [Desktop Entry]
        Type=Application
        Name=\(appName)
        Comment=Lets coding agents see and operate your apps
        Exec=\(command) doctor
        Terminal=true
        NoDisplay=true

        """
    }

    /// Writes the desktop entry to the user's applications folder when no data folder has one.
    func installDesktopEntry(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Bool {
        let data = environment["XDG_DATA_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? "\(HarnessPaths.homeDirectory)/.local/share"
        let system = (environment["XDG_DATA_DIRS"].flatMap { $0.isEmpty ? nil : $0 } ?? "/usr/local/share:/usr/share").split(separator: ":").map(String.init)
        let name = "applications/\(appID).desktop"
        if ([data] + system).contains(where: { FileManager.default.fileExists(atPath: "\($0)/\(name)") }) { return false }
        try FileManager.default.createDirectory(atPath: "\(data)/applications", withIntermediateDirectories: true)
        try Data(desktopEntry.utf8).write(to: URL(fileURLWithPath: "\(data)/\(name)"))
        return true
    }

    private var connection: DBusConnection?
    private var session: String?
    private var trigger: String?
    private var onStop: (@Sendable () -> Void)?
    private var listening = false

    /// Whether the desktop offers the portal.
    static func available(on connection: DBusConnection) async -> Bool {
        (try? await connection.property(Portal.destination, Portal.path, interface, "version")) != nil
    }

    /// The connection the shortcut is bound on, registered under the harness's app ID.
    private func registeredConnection() async throws -> DBusConnection {
        if let connection, !connection.isClosed { return connection }
        let made = try await DBusConnection.session()
        do {
            _ = try await made.call(
                Portal.destination, Portal.path, "org.freedesktop.host.portal.Registry", "Register", [.string(appID), .properties([:])]
            )
        } catch {
            made.close()
            throw error
        }
        connection = made
        session = nil
        listening = false
        return made
    }

    /// Starts listening for the stop shortcut: binds it again when the user allowed it before,
    /// which the desktop remembers, so it doesn't ask; otherwise only looks, asking nothing.
    public func start(onStop: @escaping @Sendable () -> Void) async {
        self.onStop = onStop
        guard let shared = try? await SessionBus.shared.connection(), await Self.available(on: shared),
              let connection = try? await registeredConnection(),
              let session = try? await session(on: connection) else { return }
        if FileManager.default.fileExists(atPath: markerPath), let rebound = try? await request(binding: session, on: connection, timeout: .seconds(10)) {
            trigger = rebound
            return
        }
        let listed = try? await Portal.request(Self.interface, "ListShortcuts", [.objectPath(session)], options: [:], on: connection)
        trigger = Self.trigger(in: listed?["shortcuts"])
    }

    /// Marks that the user allowed the shortcut, so later starts bind it again; the portal keeps a
    /// binding only for the session that made it.
    var markerPath: String {
        let state = ProcessInfo.processInfo.environment["XDG_STATE_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? "\(HarnessPaths.homeDirectory)/.local/state"
        return "\(state)/macos-harness/\(appID)-stop-shortcut"
    }

    /// Forgets that the user allowed the shortcut.
    func forget() {
        try? FileManager.default.removeItem(atPath: markerPath)
        trigger = nil
    }

    private func request(binding session: String, on connection: DBusConnection, timeout: Duration) async throws -> String? {
        let shortcut = DBusValue.structure([
            .string(Self.stopID),
            .properties(["description": .string("Stop every agent"), "preferred_trigger": .string(Self.preferredTrigger)]),
        ])
        let results = try await Portal.request(
            Self.interface, "BindShortcuts", [.objectPath(session), .array(element: "(sa{sv})", [shortcut]), .string("")], options: [:],
            on: connection, timeout: timeout
        )
        return Self.trigger(in: results["shortcuts"])
    }

    /// What the bound shortcut is, as the desktop describes it, or nil when it isn't bound.
    func bound() async -> String? {
        if session == nil, let onStop { await start(onStop: onStop) }
        return trigger
    }

    /// Binds the stop shortcut, which the desktop asks the user about; says too whether it wrote
    /// the desktop entry first.
    func bind() async throws -> (trigger: String, installedEntry: Bool) {
        let installed = try installDesktopEntry()
        var attempts = installed ? 15 : 1
        var registered: DBusConnection?
        while registered == nil {
            if installed { connection?.close() }
            do {
                registered = try await registeredConnection()
            } catch {
                attempts -= 1
                guard attempts > 0 else { throw error }
                try await Task.sleep(for: .milliseconds(200))
            }
        }
        let connection = registered!
        let session = try await session(on: connection)
        guard let described = try await request(binding: session, on: connection, timeout: .seconds(300)) else {
            throw RPCError(code: RPCErrorCode.permissionMissing, message: "The desktop didn't bind the stop shortcut.")
        }
        trigger = described
        let folder = (markerPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        _ = FileManager.default.createFile(atPath: markerPath, contents: Data())
        return (described, installed)
    }

    private func session(on connection: DBusConnection) async throws -> String {
        if let session { return session }
        let created = try await Portal.request(
            Self.interface, "CreateSession", [], options: ["session_handle_token": .string("harness\(UInt32.random(in: 0...UInt32.max))")],
            on: connection
        )
        guard let handle = created["session_handle"]?.string else {
            throw RPCError(code: RPCErrorCode.failed, message: "The GlobalShortcuts portal made no session.")
        }
        session = handle
        if !listening {
            listening = true
            try await connection.addMatch("type='signal',interface='\(Self.interface)',member='Activated'")
            connection.onSignal { [weak self] message in
                guard message.interface == Self.interface, message.member == "Activated",
                      message.body.count >= 2, message.body[1].string == Self.stopID else { return }
                Task { await self?.activated(session: message.body[0].string) }
            }
        }
        return handle
    }

    private func activated(session handle: String?) {
        guard handle == session else { return }
        onStop?()
    }

    /// The trigger description of the stop shortcut in a portal's list of shortcuts.
    static func trigger(in shortcuts: DBusValue?) -> String? {
        for entry in shortcuts?.elements ?? [] {
            guard let fields = entry.fields, fields.count == 2, fields[0].string == stopID else { continue }
            let described = fields[1].dictionary?["trigger_description"]?.string
            return readable(described?.isEmpty == false ? described! : preferredTrigger)
        }
        return nil
    }

    /// A shortcut as people write it: GNOME's "Press <Control><Alt><Super>period" and the
    /// portal's "CTRL+ALT+LOGO+period" both become "Ctrl+Alt+Super+.".
    static func readable(_ trigger: String) -> String {
        var text = trigger.hasPrefix("Press ") ? String(trigger.dropFirst(6)) : trigger
        for (from, to) in [
            ("<Control>", "Ctrl+"), ("<Primary>", "Ctrl+"), ("<Alt>", "Alt+"), ("<Super>", "Super+"), ("<Shift>", "Shift+"),
            ("CTRL+", "Ctrl+"), ("ALT+", "Alt+"), ("LOGO+", "Super+"), ("SHIFT+", "Shift+"), ("Meta+", "Super+"),
        ] {
            text = text.replacingOccurrences(of: from, with: to)
        }
        for (from, to) in [("period", "."), ("comma", ","), ("slash", "/"), ("Escape", "Esc")] where text.hasSuffix(from) {
            text = String(text.dropLast(from.count)) + to
        }
        return text
    }
}
