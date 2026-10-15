import Foundation
@testable import HarnessClient
import Testing

struct MCPConfigFileTests {
    private func temporaryHome() throws -> String {
        let home = NSTemporaryDirectory() + "mcp-config-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        return home
    }

    @Test func cursorKeepsOtherServers() throws {
        let config: [String: Any] = ["mcpServers": ["other": ["command": "/usr/bin/other"]]]
        let updated = MCPConfigFile.registering("/opt/homebrew/bin/macos-harness", in: config, for: .cursor, name: "macos-harness")
        #expect(MCPConfigFile.registeredCommand(in: updated, for: .cursor, name: "macos-harness") == "/opt/homebrew/bin/macos-harness")
        #expect(MCPConfigFile.serverCommand(in: updated, name: "other") == "/usr/bin/other")
    }

    @Test func opencodeGetsALocalServer() throws {
        let updated = MCPConfigFile.registering("/opt/homebrew/bin/macos-harness", in: [:], for: .opencode, name: "macos-harness")
        let server = (updated["mcp"] as? [String: Any])?["macos-harness"] as? [String: Any]
        #expect(server?["type"] as? String == "local")
        #expect(server?["command"] as? [String] == ["/opt/homebrew/bin/macos-harness", "mcp"])
        #expect(updated["$schema"] as? String == "https://opencode.ai/config.json")
        #expect(MCPConfigFile.registeredCommand(in: updated, for: .opencode, name: "macos-harness") == "/opt/homebrew/bin/macos-harness")
    }

    @Test func writingKeepsTheOldFileAndRefusesComments() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let file = MCPConfigFile(host: .cursor, home: home)
        #expect(try file.read() == nil)
        try file.write(MCPConfigFile.registering("/bin/mh", in: [:], for: .cursor, name: "macos-harness"))
        try file.write(MCPConfigFile.registering("/bin/mh2", in: try file.read() ?? [:], for: .cursor, name: "macos-harness"))
        #expect(MCPConfigFile.registeredCommand(in: try file.read() ?? [:], for: .cursor, name: "macos-harness") == "/bin/mh2")
        let backup = try String(contentsOfFile: file.backupPath, encoding: .utf8)
        #expect(backup.contains("/bin/mh\""))
        try "{\n  // mine\n  \"mcpServers\": {}\n}\n".write(toFile: file.path, atomically: true, encoding: .utf8)
        #expect(throws: MCPConfigFile.Unreadable.self) { try file.read() }
    }
}
