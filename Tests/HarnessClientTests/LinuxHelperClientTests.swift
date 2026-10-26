import Foundation
@testable import HarnessClient
import HarnessProtocol
import Testing

struct LinuxHelperLocatorTests {
    @Test func findsTheHelperNextToTheCLIOrFromTheEnvironment() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("locator-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let bin = folder.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let cli = bin.appendingPathComponent("macos-harness")
        #expect(HelperLocator.locateLinux(environment: [:], executable: cli) == nil)

        let helper = bin.appendingPathComponent("macos-harness-helper")
        _ = FileManager.default.createFile(atPath: helper.path, contents: Data(), attributes: [.posixPermissions: 0o755])
        let environment = ["XDG_RUNTIME_DIR": "/run/user/1000"]
        let found = try #require(HelperLocator.locateLinux(environment: environment, executable: cli))
        #expect(found.appURL == helper)
        #expect(found.variant == .release)
        #expect(found.socketPath == HarnessPaths.socketPath(for: .release, environment: environment))

        let dev = try #require(HelperLocator.locateLinux(environment: environment, executable: bin.appendingPathComponent("macos-harness-dev")))
        #expect(dev.variant == .dev)
        #expect(HelperLocator.locateLinux(environment: ["MACOS_HARNESS_VARIANT": "dev"], executable: cli)?.variant == .dev)

        let other = folder.appendingPathComponent("other-helper")
        _ = FileManager.default.createFile(atPath: other.path, contents: Data(), attributes: [.posixPermissions: 0o755])
        #expect(HelperLocator.locateLinux(environment: ["MACOS_HARNESS_APP": other.path], executable: cli)?.appURL == other)
    }
}

struct LinuxDoctorRenderTests {
    private func report(prompt: String?) -> DoctorMethod.Result {
        var report = DoctorMethod.Result(
            helperVersion: HarnessVersion.string, protocolVersion: HarnessVersion.protocolVersion,
            bundleIdentifier: "io.github.therogue76.macos-harness", bundlePath: "/usr/libexec/macos-harness/macos-harness-helper",
            helperPID: 42, macOSVersion: "Linux 7.0", permissions: .init(accessibility: false, screenRecording: false),
            secureInputEnabled: false,
            caller: CallerInfo(displayName: "Claude Code", identityKey: "Claude Code|unsigned|claude", paired: true, chain: [])
        )
        report.linux = DoctorMethod.LinuxStatus(session: "wayland", desktop: "GNOME", distribution: "Fedora Linux 44", pairingPrompt: prompt)
        return report
    }

    @Test func showsTheSessionAndPairingInsteadOfMacPermissions() {
        let text = Render.doctor(report(prompt: "desktop notifications"), socketPath: "/run/user/1000/macos-harness/release.sock")
        #expect(text.contains("macos-harness-helper (pid 42) on Fedora Linux 44"))
        #expect(text.contains("session: GNOME on wayland"))
        #expect(text.contains("✓ Pairing asks through desktop notifications"))
        #expect(!text.contains("Accessibility"))
        #expect(!text.contains("Screen Recording"))
        #expect(Render.isHealthy(report(prompt: "desktop notifications")))
    }

    @Test func listsPermissionsAndIsUnhealthyOnlyWhenOneIsMissing() {
        var report = report(prompt: "desktop notifications")
        report.linux?.permissions = [
            .init(id: "accessibility", name: "Accessibility", state: .notNeeded, detail: "Apps publish their elements."),
            .init(id: "windows", name: "Windows", state: .granted, detail: "The extension is running."),
            .init(id: "input", name: "Mouse and keyboard", state: .unsupported, detail: "Not yet."),
        ]
        var text = Render.doctor(report, socketPath: "/tmp/x.sock")
        #expect(text.contains("✓ Accessibility: Apps publish their elements."))
        #expect(text.contains("✓ Windows: The extension is running."))
        #expect(text.contains("- Mouse and keyboard: Not yet."))
        #expect(!text.contains("permissions grant"))
        #expect(Render.isHealthy(report))

        report.linux?.permissions?[1].state = .missing
        text = Render.doctor(report, socketPath: "/tmp/x.sock")
        #expect(text.contains("✗ Windows: The extension is running."))
        #expect(text.contains("permissions grant"))
        #expect(!Render.isHealthy(report))
    }

    @Test func saysWhenTheScreenIsLocked() {
        var locked = report(prompt: "desktop notifications")
        locked.screenLocked = true
        #expect(Render.doctor(locked, socketPath: "/tmp/x.sock").contains("! The screen is locked"))
        #expect(!Render.doctor(report(prompt: "desktop notifications"), socketPath: "/tmp/x.sock").contains("locked"))
    }

    @Test func saysWhenPairingCantAsk() {
        let text = Render.doctor(report(prompt: nil), socketPath: "/tmp/x.sock")
        #expect(text.contains("✗ Pairing can't ask"))
    }
}
