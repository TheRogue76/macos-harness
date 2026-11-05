import Foundation
@testable import HarnessLinux
import Testing

struct StartAtLoginTests {
    @Test func movesTheEntryFromTheAppIDBefore2() throws {
        let config = FileManager.default.temporaryDirectory.appendingPathComponent("start-at-login-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: config) }
        let environment = ["XDG_CONFIG_HOME": config]
        let legacy = "io.github.therogue76.MacosHarness", current = "io.github.therogue76.Otto"
        try StartAtLogin.move(from: legacy, to: current, appName: "Otto", executable: "/usr/bin/otto-helper", environment: environment)
        #expect(!StartAtLogin.isOn(appID: current, environment: environment))

        try StartAtLogin.set(true, appID: legacy, appName: "macOS Harness", executable: "/old/macos-harness-helper", environment: environment)
        try StartAtLogin.move(from: legacy, to: current, appName: "Otto", executable: "/usr/bin/otto-helper", environment: environment)
        #expect(!StartAtLogin.isOn(appID: legacy, environment: environment))
        let entry = try String(contentsOfFile: "\(config)/autostart/\(current).desktop", encoding: .utf8)
        #expect(entry.contains("Exec=/usr/bin/otto-helper") && entry.contains("Name=Otto"))
    }

    @Test func glyphTakesTheColourAndTheAttentionDot() {
        let plain = TrayIcon.glyph(color: "#bebebe", dot: false)
        #expect(plain.contains("stroke=\"#bebebe\"") && !plain.contains("#FF450F"))
        #expect(TrayIcon.glyph(color: "#ffffff", dot: true).contains("fill=\"#FF450F\""))
    }
}
