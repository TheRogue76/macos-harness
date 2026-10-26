import Foundation
import HarnessCore
import HarnessDBus
import HarnessProtocol
import Synchronization

/// What the desktop lets the harness do on Linux, and asking for it or taking it back. Sway lets
/// any client see windows, capture and send input; KDE shows windows to KWin scripts; GNOME needs
/// the harness's Shell extension for windows. GNOME and KDE ask once each for screenshots and
/// remote input through their portals.
public enum LinuxPermissions {
    public typealias Item = PermissionsMethod.Item

    static let extensionUUID = "macos-harness@therogue76.github.io"
    static let shellExtensions = (name: "org.gnome.Shell.Extensions", path: "/org/gnome/Shell/Extensions")
    static let permissionStore = (
        name: "org.freedesktop.impl.portal.PermissionStore", path: "/org/freedesktop/impl/portal/PermissionStore",
        interface: "org.freedesktop.impl.portal.PermissionStore"
    )

    /// The desktops the harness tells apart.
    enum Desktop: Equatable {
        case none, sway, gnome, kde
        case other(String)

        /// The desktop's name in messages.
        var label: String {
            switch self {
            case .kde: "KDE"
            case .sway: "Sway"
            case .other(let name): name
            default: "GNOME"
            }
        }

        static func current(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Desktop {
            if let socket = environment["SWAYSOCK"], FileManager.default.fileExists(atPath: socket) { return .sway }
            guard environment["WAYLAND_DISPLAY"].map({ !$0.isEmpty }) == true else { return .none }
            let names = (environment["XDG_CURRENT_DESKTOP"] ?? "").split(separator: ":").map { $0.uppercased() }
            if names.contains("GNOME") { return .gnome }
            if names.contains("KDE") { return .kde }
            if names.contains("SWAY") { return .sway }
            return .other(environment["XDG_CURRENT_DESKTOP"].flatMap { $0.isEmpty ? nil : $0 } ?? "this desktop")
        }
    }

    private static let missingHandler = Mutex<(@Sendable (Item) -> Void)?>(nil)
    private static let screenshotsWorked = Mutex(false)

    /// Called with an item an agent's request needed but didn't have, so the helper can offer
    /// to set it up.
    public static func onMissing(_ handler: @escaping @Sendable (Item) -> Void) {
        missingHandler.withLock { $0 = handler }
    }

    /// The error for a request that needed an item, telling the helper about it.
    static func missing(_ id: String, _ message: String) async -> RPCError {
        if let item = await status().first(where: { $0.id == id }) {
            let handler = missingHandler.withLock { $0 }
            handler?(item)
        }
        return RPCError(code: RPCErrorCode.permissionMissing, message: message)
    }

    public static func run(_ params: PermissionsMethod.Params) async throws -> PermissionsMethod.Result {
        let before = await status()
        if let wanted = params.item, !before.contains(where: { $0.id == wanted }) {
            throw RPCError(
                code: RPCErrorCode.invalidParams,
                message: "There's no permission called \(wanted); there are \(before.map(\.id).joined(separator: ", "))."
            )
        }
        let chosen = before.filter { params.item == nil || $0.id == params.item }
        var performed: [String] = []
        var notices: [String] = []
        switch params.action {
        case .status:
            break
        case .grant:
            for item in chosen where item.state == .missing {
                try await grant(item.id, performed: &performed, notices: &notices)
            }
        case .reset:
            guard [.gnome, .kde].contains(Desktop.current()) else { break }
            for item in chosen.reversed() {
                try await reset(item.id, performed: &performed, notices: &notices)
            }
        }
        return PermissionsMethod.Result(items: await status(), performed: performed, notices: notices)
    }

    /// Every item and its state.
    public static func status() async -> [Item] {
        await desktopItems() + [await recordingItem(), await stopShortcutItem()]
    }

    /// Recording a window to a movie: the ScreenCast portal on GNOME and KDE, screen copy on Sway.
    static func recordingItem() async -> Item {
        let name = "Screen recording"
        let desktop = Desktop.current()
        switch desktop {
        case .none, .other:
            return Item(id: "recording", name: name, state: .unsupported, detail: "Recording needs GNOME, KDE or Sway.")
        case .sway:
            return Item(id: "recording", name: name, state: .notNeeded, detail: "Sway allows it without asking.")
        case .gnome, .kde:
            let prompt = "\(desktop.label) will ask which screen to share. Pick your screen and allow it to be remembered; recordings then keep only the app's window."
            guard let token = try? String(contentsOfFile: ScreenCastSession.tokenPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
                  !token.isEmpty, let connection = try? await SessionBus.shared.connection() else {
                return Item(id: "recording", name: name, state: .missing, detail: "\(desktop.label) will ask before the harness first records.", prompt: prompt)
            }
            let stored = (try? await connection.call(
                permissionStore.name, permissionStore.path, permissionStore.interface, "Lookup", [.string("screencast"), .string(token)]
            )) != nil
            return Item(
                id: "recording", name: name, state: stored ? .granted : .missing,
                detail: stored ? "\(desktop.label) lets the harness record the screen." : "\(desktop.label) forgot its answer, so it will ask again.",
                prompt: prompt
            )
        }
    }

    static func desktopItems() async -> [Item] {
        let desktop = Desktop.current()
        let accessibility = await accessibilityItem(desktop)
        switch desktop {
        case .none:
            let detail = "There's no Wayland session, so there are no desktop apps to reach."
            return [accessibility] + gnomeNames.map { Item(id: $0.id, name: $0.name, state: .unsupported, detail: detail) }
        case .sway:
            return [accessibility] + gnomeNames.map { Item(id: $0.id, name: $0.name, state: .notNeeded, detail: "Sway allows it without asking.") }
        case .other(let name):
            let detail = "\(name) isn't supported yet; GNOME, KDE and Sway are."
            return [accessibility] + gnomeNames.map { Item(id: $0.id, name: $0.name, state: .unsupported, detail: detail) }
        case .gnome, .kde:
            guard let connection = try? await SessionBus.shared.connection() else {
                return [accessibility] + gnomeNames.map { Item(id: $0.id, name: $0.name, state: .missing, detail: "The session bus isn't reachable.") }
            }
            let windows = desktop == .kde
                ? Item(id: "windows", name: "Windows", state: .notNeeded, detail: "KWin's scripting tells the harness where windows are without asking.")
                : await windowsItem(connection)
            return [accessibility, windows, await screenshotsItem(connection, desktop), await inputItem(connection, desktop)]
        }
    }

    /// The shortcut that stops every agent: bound through the GlobalShortcuts portal where the
    /// desktop has it, or by hand where it doesn't.
    static func stopShortcutItem() async -> Item {
        let name = "Stop shortcut"
        let desktop = Desktop.current()
        switch desktop {
        case .none:
            return Item(id: "stop-shortcut", name: name, state: .unsupported, detail: "There's no Wayland session to bind a shortcut in.")
        case .sway:
            return Item(
                id: "stop-shortcut", name: name, state: .unsupported,
                detail: "Sway has no shortcuts portal; add `bindsym Ctrl+Alt+Mod4+period exec macos-harness stop` to its config."
            )
        default:
            guard let connection = try? await SessionBus.shared.connection(), await LinuxShortcuts.available(on: connection) else {
                return Item(
                    id: "stop-shortcut", name: name, state: .unsupported,
                    detail: "\(desktop.label) has no shortcuts portal; bind `macos-harness stop` to a key in its keyboard settings."
                )
            }
            let bound = await LinuxShortcuts.shared.bound()
            return Item(
                id: "stop-shortcut", name: name, state: bound == nil ? .missing : .granted,
                detail: bound.map { "\($0) stops every agent." } ?? "No shortcut stops agents yet.",
                prompt: "\(desktop.label) will ask to allow a global shortcut. Allow it; Ctrl+Alt+Super+. then stops every agent, and `macos-harness resume` lets them act again."
            )
        }
    }

    static let gnomeNames = [
        (id: "windows", name: "Windows"), (id: "screenshots", name: "Screenshots"), (id: "input", name: "Mouse and keyboard"),
    ]

    static func accessibilityItem(_ desktop: Desktop) async -> Item {
        let name = "Accessibility"
        guard desktop != .none else {
            return Item(id: "accessibility", name: name, state: .unsupported, detail: "There's no Wayland session, so there are no desktop apps to reach.")
        }
        let address = try? await SessionBus.shared.connection().call("org.a11y.Bus", "/org/a11y/bus", "org.a11y.Bus", "GetAddress").first?.string
        guard let address, !address.isEmpty else {
            return Item(id: "accessibility", name: name, state: .missing, detail: "The accessibility bus isn't running; install at-spi2-core and log in again.")
        }
        return Item(id: "accessibility", name: name, state: .notNeeded, detail: "Apps publish their elements on the accessibility bus without asking.")
    }

    static func windowsItem(_ connection: DBusConnection) async -> Item {
        let item = { (state: PermissionsMethod.State, detail: String, prompt: String) in
            Item(id: "windows", name: "Windows", state: state, detail: detail, prompt: prompt)
        }
        let turnOn = "The harness turns its GNOME extension on; GNOME doesn't ask."
        if await GnomeCompositor.available(on: connection) {
            return item(.granted, "The macOS Harness extension is running.", turnOn)
        }
        let info = await extensionInfo(connection)
        if info.isEmpty {
            if installedCopy() != nil {
                return item(
                    .missing, "The macOS Harness extension is installed, but GNOME only loads it after you log out and back in.",
                    "The harness turns its GNOME extension on for your next log-in."
                )
            }
            return item(
                .missing, "The macOS Harness extension, which lists windows and brings them forward, isn't installed.",
                "GNOME will ask to install the macOS Harness extension from extensions.gnome.org. It tells the harness where windows are and brings them forward; it can't read or type anything. Choose Install."
            )
        }
        if await userExtensionsEnabled(connection) == false {
            return item(.missing, "Extensions are turned off for this user, so the macOS Harness extension doesn't run.", "The harness turns extensions back on, and its own.")
        }
        if let state = info["state"]?.double, state == 3 || state == 4 {
            return item(.missing, "The macOS Harness extension failed to load (\(state == 4 ? "it doesn't support this GNOME version" : "an error")).", turnOn)
        }
        return item(.missing, "The macOS Harness extension is installed but turned off.", turnOn)
    }

    static func screenshotsItem(_ connection: DBusConnection, _ desktop: Desktop) async -> Item {
        let name = desktop.label
        let granted = await storedScreenshotPermission(connection) == true || screenshotsWorked.withLock { $0 }
        return Item(
            id: "screenshots", name: "Screenshots", state: granted ? .granted : .missing,
            detail: granted ? "\(name) lets the harness take screenshots." : "\(name) will ask before the harness's first screenshot.",
            prompt: "\(name) will ask whether to allow screenshots. Choose Allow; it remembers the answer."
        )
    }

    static func inputItem(_ connection: DBusConnection, _ desktop: Desktop) async -> Item {
        let name = desktop.label
        let prompt = desktop == .kde
            ? "KDE will ask to allow remote control. Allow it, and let it remember the answer."
            : "GNOME will ask to allow remote interaction. Turn on Allow Remote Interaction, then choose Share; it remembers the answer."
        guard let token = savedToken() else {
            return Item(id: "input", name: "Mouse and keyboard", state: .missing, detail: "\(name) will ask before the harness first clicks or types.", prompt: prompt)
        }
        let stored = (try? await connection.call(
            permissionStore.name, permissionStore.path, permissionStore.interface, "Lookup", [.string("remote-desktop"), .string(token)]
        )) != nil
        return Item(
            id: "input", name: "Mouse and keyboard", state: stored ? .granted : .missing,
            detail: stored ? "\(name) lets the harness use the mouse and keyboard." : "\(name) forgot its answer, so it will ask again.",
            prompt: prompt
        )
    }

    static func grant(_ id: String, performed: inout [String], notices: inout [String]) async throws {
        let connection = try await SessionBus.shared.connection()
        switch id {
        case "accessibility":
            throw RPCError(code: RPCErrorCode.failed, message: "The accessibility bus comes with at-spi2-core: install it with your package manager, then log out and back in.")
        case "windows":
            try await grantExtension(connection, performed: &performed, notices: &notices)
        case "screenshots":
            _ = try await GnomeCompositor.screenshot(on: connection, timeout: .seconds(180))
            screenshotsWorked.withLock { $0 = true }
            performed.append("\(Desktop.current().label) allowed screenshots.")
        case "recording":
            let session = try await ScreenCastSession.start()
            await session.close()
            performed.append("\(Desktop.current().label) allowed screen recording.")
        case "stop-shortcut":
            let (trigger, installedEntry) = try await LinuxShortcuts.shared.bind()
            if installedEntry { performed.append("Added the harness's desktop entry, which the shortcuts portal names it by.") }
            performed.append("\(trigger) now stops every agent.")
        case "input":
            await PortalInputSessions.shared.close()
            let input = try await PortalInput.start()
            await input.close()
            performed.append("\(Desktop.current().label) allowed the mouse and keyboard.")
        default:
            break
        }
    }

    static func grantExtension(_ connection: DBusConnection, performed: inout [String], notices: inout [String]) async throws {
        if await userExtensionsEnabled(connection) == false {
            _ = try await connection.call(
                shellExtensions.name, shellExtensions.path, "org.freedesktop.DBus.Properties", "Set",
                [.string(shellExtensions.name), .string("UserExtensionsEnabled"), .variant(.boolean(true))]
            )
            performed.append("Turned extensions on for this user.")
        }
        var info = await extensionInfo(connection)
        if info.isEmpty, installedCopy() == nil {
            let answer: String?
            do {
                answer = try await connection.call(
                    shellExtensions.name, shellExtensions.path, shellExtensions.name, "InstallRemoteExtension", [.string(extensionUUID)],
                    timeout: .seconds(300)
                ).first?.string
            } catch DBusError.failed(let name, let message) where name.hasPrefix("org.gnome.Shell.Extensions.Error") {
                throw RPCError(
                    code: RPCErrorCode.failed,
                    message: "GNOME couldn't get the extension from extensions.gnome.org (\(message)). Install the macos-harness package, which includes it, then log out and back in."
                )
            }
            switch answer {
            case "successful":
                performed.append("Installed the macOS Harness extension from extensions.gnome.org.")
            case "cancelled":
                throw RPCError(code: RPCErrorCode.permissionMissing, message: "The extension wasn't installed; choose Install when GNOME asks.")
            default:
                throw RPCError(
                    code: RPCErrorCode.failed,
                    message: "extensions.gnome.org didn't install the extension (\(answer ?? "no answer")). Install the macos-harness package, which includes it, then run this again."
                )
            }
            info = await extensionInfo(connection)
        }
        if info.isEmpty {
            try await enableAtNextLogin()
            notices.append("GNOME loads a newly installed extension only at log-in: log out and back in, then run `macos-harness permissions grant` again.")
            return
        }
        if info["enabled"]?.bool != true {
            _ = try await connection.call(shellExtensions.name, shellExtensions.path, shellExtensions.name, "EnableExtension", [.string(extensionUUID)])
            performed.append("Turned on the macOS Harness extension.")
        }
        for _ in 0..<25 {
            if await GnomeCompositor.available(on: connection) { return }
            try await Task.sleep(for: .milliseconds(200))
        }
        let errors = (try? await connection.call(
            shellExtensions.name, shellExtensions.path, shellExtensions.name, "GetExtensionErrors", [.string(extensionUUID)]
        ).first?.elements?.compactMap(\.string)) ?? []
        throw RPCError(
            code: RPCErrorCode.failed,
            message: "The macOS Harness extension is on but didn't start\(errors.isEmpty ? "" : ": \(errors.joined(separator: "; "))")."
        )
    }

    /// Adds the extension to GNOME's enabled list, for an extension Shell hasn't loaded yet.
    static func enableAtNextLogin() async throws {
        let gsettings = ["/usr/bin/gsettings", "/bin/gsettings"].first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/gsettings"
        let current = try await ToolRunner.run(gsettings, ["get", "org.gnome.shell", "enabled-extensions"], timeout: 10).text
        guard !current.contains("'\(extensionUUID)'") else { return }
        let list = current.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "@as ", with: "")
        let updated = list == "[]" ? "['\(extensionUUID)']" : list.dropLast() + ", '\(extensionUUID)']"
        _ = try await ToolRunner.run(gsettings, ["set", "org.gnome.shell", "enabled-extensions", String(updated)], timeout: 10)
    }

    static func reset(_ id: String, performed: inout [String], notices: inout [String]) async throws {
        let connection = try await SessionBus.shared.connection()
        let store = permissionStore
        switch id {
        case "input":
            await PortalInputSessions.shared.close()
            if let token = savedToken() {
                _ = try? await connection.call(store.name, store.path, store.interface, "Delete", [.string("remote-desktop"), .string(token)])
                try? FileManager.default.removeItem(atPath: PortalInput.tokenPath)
                performed.append("Removed \(Desktop.current().label)'s permission for the mouse and keyboard; it will ask again.")
            }
        case "recording":
            if let token = try? String(contentsOfFile: ScreenCastSession.tokenPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) {
                _ = try? await connection.call(store.name, store.path, store.interface, "Delete", [.string("screencast"), .string(token)])
                try? FileManager.default.removeItem(atPath: ScreenCastSession.tokenPath)
                performed.append("Removed \(Desktop.current().label)'s permission for screen recording; it will ask again.")
            }
        case "stop-shortcut":
            await LinuxShortcuts.shared.forget()
            performed.append("The harness no longer binds the stop shortcut when it starts; remove it from the desktop's keyboard settings to free the keys.")
        case "screenshots":
            screenshotsWorked.withLock { $0 = false }
            if await storedScreenshotPermission(connection) != nil {
                _ = try? await connection.call(
                    store.name, store.path, store.interface, "DeletePermission", [.string("screenshot"), .string("screenshot"), .string("")]
                )
                performed.append("Removed \(Desktop.current().label)'s permission for screenshots; it will ask again.")
                notices.append("Screenshot permission is shared by every app that isn't a Flatpak or Snap, so they'll be asked again too.")
            }
        case "windows":
            let info = await extensionInfo(connection)
            guard !info.isEmpty else { break }
            if info["type"]?.double == 2 {
                _ = try await connection.call(shellExtensions.name, shellExtensions.path, shellExtensions.name, "UninstallExtension", [.string(extensionUUID)])
                var waited = 0
                while waited < 20, await !extensionInfo(connection).isEmpty {
                    try await Task.sleep(for: .milliseconds(100))
                    waited += 1
                }
                performed.append("Uninstalled the macOS Harness extension.")
            } else if info["enabled"]?.bool == true {
                _ = try await connection.call(shellExtensions.name, shellExtensions.path, shellExtensions.name, "DisableExtension", [.string(extensionUUID)])
                performed.append("Turned off the macOS Harness extension; the package installed it for all users, so it stays installed.")
            }
        default:
            break
        }
    }

    static func extensionInfo(_ connection: DBusConnection) async -> [String: DBusValue] {
        (try? await connection.call(
            shellExtensions.name, shellExtensions.path, shellExtensions.name, "GetExtensionInfo", [.string(extensionUUID)]
        ).first?.dictionary) ?? [:]
    }

    static func userExtensionsEnabled(_ connection: DBusConnection) async -> Bool? {
        try? await connection.property(shellExtensions.name, shellExtensions.path, shellExtensions.name, "UserExtensionsEnabled").bool
    }

    /// Where the extension's files are, when they're installed for this user or all users.
    static func installedCopy(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let data = environment["XDG_DATA_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? "\(HarnessPaths.homeDirectory)/.local/share"
        let system = (environment["XDG_DATA_DIRS"].flatMap { $0.isEmpty ? nil : $0 } ?? "/usr/local/share:/usr/share").split(separator: ":").map(String.init)
        return ([data] + system).map { "\($0)/gnome-shell/extensions/\(extensionUUID)/metadata.json" }
            .first { FileManager.default.fileExists(atPath: $0) }
    }

    /// Whether GNOME's permission store allows apps outside a sandbox to take screenshots: nil
    /// when it holds no answer.
    static func storedScreenshotPermission(_ connection: DBusConnection) async -> Bool? {
        let store = permissionStore
        guard let reply = try? await connection.call(store.name, store.path, store.interface, "Lookup", [.string("screenshot"), .string("screenshot")]),
              let apps = reply.first?.dictionary, let answer = apps[""]?.elements?.compactMap(\.string) else { return nil }
        return answer.contains("yes")
    }

    static func savedToken() -> String? {
        guard let text = try? String(contentsOfFile: PortalInput.tokenPath, encoding: .utf8) else { return nil }
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }
}
