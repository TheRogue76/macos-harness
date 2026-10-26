import Foundation
@testable import HarnessLinux
import Testing

struct LinuxPermissionsTests {
    @Test func tellsDesktopsApartFromTheEnvironment() {
        #expect(LinuxPermissions.Desktop.current([:]) == .none)
        #expect(LinuxPermissions.Desktop.current(["XDG_CURRENT_DESKTOP": "GNOME"]) == .none)
        #expect(LinuxPermissions.Desktop.current(["WAYLAND_DISPLAY": "wayland-0", "XDG_CURRENT_DESKTOP": "ubuntu:GNOME"]) == .gnome)
        #expect(LinuxPermissions.Desktop.current(["WAYLAND_DISPLAY": "wayland-1", "XDG_CURRENT_DESKTOP": "sway"]) == .sway)
        #expect(LinuxPermissions.Desktop.current(["WAYLAND_DISPLAY": "wayland-0", "XDG_CURRENT_DESKTOP": "KDE"]) == .other("KDE"))
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
