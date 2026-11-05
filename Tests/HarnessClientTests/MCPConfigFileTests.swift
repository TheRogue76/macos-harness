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

    private func write(_ json: String, to path: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try json.write(toFile: path, atomically: true, encoding: .utf8)
    }

    @Test func cursorReplacesTheOldServerWhenItRunsThisCLI() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let file = MCPConfigFile(host: .cursor, home: home)
        try write("""
            {"mcpServers": {
              "macos-harness": {"type": "stdio", "command": "/Applications/macOS Harness.app/Contents/MacOS/macos-harness", "args": ["mcp"]},
              "other": {"command": "/usr/bin/other"}
            }}
            """, to: file.path)
        let config = try #require(try file.read())
        let registration = MCPRegistration(cli: "/opt/homebrew/bin/otto") { MCPConfigFile.registeredCommand(in: config, for: .cursor, name: $0) }
        #expect(registration.replacesLegacy)
        #expect(registration.replacedNotice(in: "Cursor") == "Replaced the macos-harness server with otto in Cursor.")
        try file.write(MCPConfigFile.migrating("/opt/homebrew/bin/otto", in: config, for: .cursor))
        let updated = try #require(try file.read())
        #expect(MCPConfigFile.registeredCommand(in: updated, for: .cursor, name: "otto") == "/opt/homebrew/bin/otto")
        #expect(MCPConfigFile.registeredCommand(in: updated, for: .cursor, name: "macos-harness") == nil)
        #expect(MCPConfigFile.serverCommand(in: updated, name: "other") == "/usr/bin/other")
        let after = MCPRegistration(cli: "/opt/homebrew/bin/otto") { MCPConfigFile.registeredCommand(in: updated, for: .cursor, name: $0) }
        #expect(after.isDone)
        #expect(after.replacedNotice(in: "Cursor") == nil)
    }

    @Test func opencodeReplacesTheOldServerEvenWhenOttoIsAlreadyThere() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let file = MCPConfigFile(host: .opencode, home: home)
        try write("""
            {"$schema": "https://opencode.ai/config.json", "mcp": {
              "macos-harness": {"type": "local", "command": ["/home/me/.local/bin/macos-harness-dev", "mcp"], "enabled": true},
              "otto": {"type": "local", "command": ["/usr/bin/otto", "mcp"], "enabled": true}
            }}
            """, to: file.path)
        let config = try #require(try file.read())
        let registration = MCPRegistration(cli: "/usr/bin/otto") { MCPConfigFile.registeredCommand(in: config, for: .opencode, name: $0) }
        #expect(registration.replacesLegacy)
        #expect(!registration.registers)
        #expect(!registration.isDone)
        try file.write(MCPConfigFile.migrating("/usr/bin/otto", in: config, for: .opencode))
        let servers = try #require(try file.read()?["mcp"] as? [String: Any])
        #expect(Set(servers.keys) == ["otto"])
        #expect((servers["otto"] as? [String: Any])?["command"] as? [String] == ["/usr/bin/otto", "mcp"])
    }

    @Test func anOldServerNamedTheSameButRunningSomethingElseStays() throws {
        let config: [String: Any] = ["mcp": ["macos-harness": ["type": "local", "command": ["/usr/bin/node", "my-server.js"]]]]
        let registration = MCPRegistration(cli: "/usr/bin/otto") { MCPConfigFile.registeredCommand(in: config, for: .opencode, name: $0) }
        #expect(!registration.replacesLegacy)
        #expect(registration.pendingStatus(in: "opencode", rerun: "otto setup opencode") == "opencode: not set up; run `otto setup opencode`")
        let updated = MCPConfigFile.migrating("/usr/bin/otto", in: config, for: .opencode)
        let servers = try #require(updated["mcp"] as? [String: Any])
        #expect(Set(servers.keys) == ["macos-harness", "otto"])
    }

    @Test func claudeCodeAndGeminiSettingsAreReadForBothNames() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let claude = "\(home)/.claude.json"
        try write("""
            {"projects": {}, "mcpServers": {"macos-harness": {"type": "stdio", "command": "/opt/homebrew/bin/macos-harness", "args": ["mcp"], "env": {}}}}
            """, to: claude)
        let registration = MCPRegistration(cli: "/opt/homebrew/bin/otto") { MCPConfigFile.serverCommand(inFileAt: claude, name: $0) }
        #expect(registration.current == nil)
        #expect(registration.legacy == "/opt/homebrew/bin/macos-harness")
        #expect(registration.replacesLegacy && registration.registers)
        #expect(
            registration.pendingStatus(in: "Claude Code", rerun: "otto setup claude")
                == "Claude Code: registered as macos-harness (/opt/homebrew/bin/macos-harness); run `otto setup claude` to rename it otto"
        )
        let gemini = "\(home)/.gemini/settings.json"
        try write(#"{"mcpServers": {"otto": {"command": "/usr/local/bin/otto-dev", "args": ["mcp"]}}}"#, to: gemini)
        let set = MCPRegistration(cli: "/usr/local/bin/otto-dev") { MCPConfigFile.serverCommand(inFileAt: gemini, name: $0) }
        #expect(set.isDone)
        #expect(MCPConfigFile.serverCommand(inFileAt: "\(home)/missing.json", name: "otto") == nil)
    }

    @Test func recognizesThisProductsCLIByName() {
        #expect(MCPRegistration.runsThisProduct("/opt/homebrew/bin/otto"))
        #expect(MCPRegistration.runsThisProduct("/Users/me/.local/bin/otto-dev"))
        #expect(MCPRegistration.runsThisProduct("/Applications/macOS Harness.app/Contents/MacOS/macos-harness"))
        #expect(MCPRegistration.runsThisProduct("macos-harness-dev"))
        #expect(!MCPRegistration.runsThisProduct("/usr/bin/ottoman"))
        #expect(!MCPRegistration.runsThisProduct("/usr/bin/node"))
    }
}
