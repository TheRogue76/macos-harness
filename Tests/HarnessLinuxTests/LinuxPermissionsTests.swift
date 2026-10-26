import Foundation
import HarnessDBus
@testable import HarnessLinux
import Testing

struct LinuxPermissionsTests {
    @Test func tellsDesktopsApartFromTheEnvironment() {
        #expect(LinuxPermissions.Desktop.current([:]) == .none)
        #expect(LinuxPermissions.Desktop.current(["XDG_CURRENT_DESKTOP": "GNOME"]) == .none)
        #expect(LinuxPermissions.Desktop.current(["WAYLAND_DISPLAY": "wayland-0", "XDG_CURRENT_DESKTOP": "ubuntu:GNOME"]) == .gnome)
        #expect(LinuxPermissions.Desktop.current(["WAYLAND_DISPLAY": "wayland-1", "XDG_CURRENT_DESKTOP": "sway"]) == .sway)
        #expect(LinuxPermissions.Desktop.current(["WAYLAND_DISPLAY": "wayland-0", "XDG_CURRENT_DESKTOP": "KDE"]) == .kde)
        #expect(LinuxPermissions.Desktop.current(["WAYLAND_DISPLAY": "wayland-0", "XDG_CURRENT_DESKTOP": "Hyprland"]) == .other("Hyprland"))
        #expect(LinuxPermissions.Desktop.current(["WAYLAND_DISPLAY": "wayland-0"]) == .other("this desktop"))
    }

    @Test func findsTheExtensionInstalledForTheUserOrEveryone() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("extension-\(UUID())").path
        defer { try? FileManager.default.removeItem(atPath: root) }
        let environment = ["XDG_DATA_HOME": "\(root)/user", "XDG_DATA_DIRS": "\(root)/local:\(root)/system"]
        #expect(LinuxPermissions.installedCopy(environment: environment) == nil)

        let system = "\(root)/system/gnome-shell/extensions/\(LinuxPermissions.extensionUUID)"
        try FileManager.default.createDirectory(atPath: system, withIntermediateDirectories: true)
        _ = FileManager.default.createFile(atPath: "\(system)/metadata.json", contents: Data("{}".utf8))
        #expect(LinuxPermissions.installedCopy(environment: environment) == "\(system)/metadata.json")

        let user = "\(root)/user/gnome-shell/extensions/\(LinuxPermissions.extensionUUID)"
        try FileManager.default.createDirectory(atPath: user, withIntermediateDirectories: true)
        _ = FileManager.default.createFile(atPath: "\(user)/metadata.json", contents: Data("{}".utf8))
        #expect(LinuxPermissions.installedCopy(environment: environment) == "\(user)/metadata.json")
    }
}

struct LinuxShortcutsTests {
    @Test func readsTheStopShortcutsTriggerFromThePortalsList() {
        let list = DBusValue.array(element: "(sa{sv})", [
            .structure([.string("other"), .properties(["trigger_description": .string("Ctrl+O")])]),
            .structure([.string("stop-agents"), .properties(["trigger_description": .string("Meta+Ctrl+Alt+.")])]),
        ])
        #expect(LinuxShortcuts.trigger(in: list) == "Super+Ctrl+Alt+.")
        let undescribed = DBusValue.array(element: "(sa{sv})", [.structure([.string("stop-agents"), .properties([:])])])
        #expect(LinuxShortcuts.trigger(in: undescribed) == "Ctrl+Alt+Super+.")
        #expect(LinuxShortcuts.trigger(in: .array(element: "(sa{sv})", [])) == nil)
        #expect(LinuxShortcuts.trigger(in: nil) == nil)
    }

    @Test func writesShortcutsAsPeopleDo() {
        #expect(LinuxShortcuts.readable("Press <Control><Alt><Super>period") == "Ctrl+Alt+Super+.")
        #expect(LinuxShortcuts.readable("CTRL+ALT+LOGO+period") == "Ctrl+Alt+Super+.")
        #expect(LinuxShortcuts.readable("Meta+Ctrl+Alt+.") == "Super+Ctrl+Alt+.")
    }

    @Test func writesAHiddenDesktopEntryOnlyWhereNoneIsInstalled() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("entry-\(UUID())").path
        defer { try? FileManager.default.removeItem(atPath: root) }
        let shortcuts = LinuxShortcuts()
        await shortcuts.configure(appID: "io.example.Harness", appName: "Example Harness", command: "/opt/example/macos-harness")
        let environment = ["XDG_DATA_HOME": "\(root)/user", "XDG_DATA_DIRS": "\(root)/system"]
        #expect(try await shortcuts.installDesktopEntry(environment: environment))
        let written = try String(contentsOfFile: "\(root)/user/applications/io.example.Harness.desktop", encoding: .utf8)
        #expect(written.contains("Name=Example Harness"))
        #expect(written.contains("Exec=/opt/example/macos-harness doctor"))
        #expect(written.contains("NoDisplay=true"))
        #expect(try await !shortcuts.installDesktopEntry(environment: environment))
    }
}
