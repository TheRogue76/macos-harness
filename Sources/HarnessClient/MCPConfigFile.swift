import Foundation
import HarnessProtocol

/// An agent's JSON config file that lists MCP servers, which `setup` reads and edits in place
/// for agents without a command of their own to add one.
public struct MCPConfigFile: Sendable {
    /// The agents whose config `setup` edits.
    public enum Host: Sendable {
        /// `~/.cursor/mcp.json`, shared by Cursor and its `agent` CLI.
        case cursor
        /// `~/.config/opencode/opencode.json`.
        case opencode
    }

    public let host: Host
    public let path: String

    public init(host: Host, home: String) {
        self.host = host
        switch host {
        case .cursor: path = "\(home)/.cursor/mcp.json"
        case .opencode: path = "\(home)/.config/opencode/opencode.json"
        }
    }

    /// Why the file can't be edited safely.
    public struct Unreadable: Error, CustomStringConvertible {
        public var description: String
    }

    /// The file's contents; nil when it doesn't exist. Throws when it isn't a plain JSON object
    /// (comments or trailing commas), which setup won't rewrite.
    public func read() throws -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data), let config = object as? [String: Any] else {
            throw Unreadable(description: "\(path) isn't plain JSON (it may have comments), so setup won't rewrite it")
        }
        return config
    }

    /// The command an `mcpServers` map (Cursor's, Gemini CLI's, Claude Code's) runs a server with.
    public static func serverCommand(in config: [String: Any], name: String) -> String? {
        ((config["mcpServers"] as? [String: Any])?[name] as? [String: Any])?["command"] as? String
    }

    /// The command an `mcpServers` map in the JSON file at `path` runs a server with; nil when the
    /// file or the entry is missing or the file isn't JSON.
    public static func serverCommand(inFileAt path: String, name: String) -> String? {
        FileManager.default.contents(atPath: path)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            .flatMap { serverCommand(in: $0, name: name) }
    }

    /// The command the config runs the server called `name` with, if it registers it.
    public static func registeredCommand(in config: [String: Any], for host: Host, name: String) -> String? {
        switch host {
        case .cursor:
            return serverCommand(in: config, name: name)
        case .opencode:
            return (((config["mcp"] as? [String: Any])?[name] as? [String: Any])?["command"] as? [String])?.first
        }
    }

    /// The config without the server called `name`, leaving every other entry as it was.
    public static func removing(_ name: String, from config: [String: Any], for host: Host) -> [String: Any] {
        var config = config
        let key = host == .cursor ? "mcpServers" : "mcp"
        guard var servers = config[key] as? [String: Any], servers[name] != nil else { return config }
        servers[name] = nil
        config[key] = servers
        return config
    }

    /// The config with this product's server registered to run `cli mcp`, and the server under its
    /// name before 2.0 removed when it runs this product's CLI, leaving every other entry as it was.
    public static func migrating(_ cli: String, in config: [String: Any], for host: Host) -> [String: Any] {
        let registration = MCPRegistration(cli: cli) { registeredCommand(in: config, for: host, name: $0) }
        var updated = config
        if registration.replacesLegacy {
            updated = removing(HarnessProduct.legacyMCPServerName, from: updated, for: host)
        }
        if registration.registers {
            updated = registering(cli, in: updated, for: host, name: HarnessProduct.mcpServerName)
        }
        return updated
    }

    /// The config with the server called `name` registered to run `cli mcp`, leaving every other
    /// entry as it was.
    public static func registering(_ cli: String, in config: [String: Any], for host: Host, name: String) -> [String: Any] {
        var config = config
        switch host {
        case .cursor:
            var servers = config["mcpServers"] as? [String: Any] ?? [:]
            servers[name] = ["type": "stdio", "command": cli, "args": ["mcp"]]
            config["mcpServers"] = servers
        case .opencode:
            if config.isEmpty { config["$schema"] = "https://opencode.ai/config.json" }
            var servers = config["mcp"] as? [String: Any] ?? [:]
            servers[name] = ["type": "local", "command": [cli, "mcp"], "enabled": true]
            config["mcp"] = servers
        }
        return config
    }

    /// The path the previous contents are kept at when the file is rewritten.
    public var backupPath: String { path + ".before-\(HarnessProduct.commandName)" }

    /// Writes `config`, keeping the previous file at `backupPath` first.
    public func write(_ config: [String: Any]) throws {
        let manager = FileManager.default
        try manager.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if manager.fileExists(atPath: path) {
            if manager.fileExists(atPath: backupPath) { try manager.removeItem(atPath: backupPath) }
            try manager.copyItem(atPath: path, toPath: backupPath)
        }
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try (data + Data("\n".utf8)).write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}

/// What an agent host has registered of this product's MCP server, and what `setup` changes.
public struct MCPRegistration: Sendable, Equatable {
    /// The CLI `setup` registers.
    public var cli: String
    /// The command the server under `mcpServerName` runs, if the host has one.
    public var current: String?
    /// The command the server under `legacyMCPServerName` runs, if the host has one.
    public var legacy: String?

    /// Reads both entries through `command`, which gives the command a server name runs.
    public init(cli: String, command: (String) -> String?) {
        self.cli = cli
        current = command(HarnessProduct.mcpServerName)
        legacy = command(HarnessProduct.legacyMCPServerName)
    }

    /// Whether `command` runs this product's CLI, under its name now or before 2.0.
    public static func runsThisProduct(_ command: String) -> Bool {
        HarnessProduct.commandNames.contains((command as NSString).lastPathComponent)
    }

    /// Whether the host has the server under its name before 2.0, running this product's CLI,
    /// which `setup` removes.
    public var replacesLegacy: Bool {
        legacy.map(Self.runsThisProduct) ?? false
    }

    /// Whether `setup` registers `cli` under `mcpServerName`, as the host doesn't run it there yet.
    public var registers: Bool {
        current != cli
    }

    /// Whether the host runs `cli` under `mcpServerName` and has nothing left to replace.
    public var isDone: Bool {
        !registers && !replacesLegacy
    }

    /// What `setup` says it did about the old entry in `host`, or nil when there was none.
    public func replacedNotice(in host: String) -> String? {
        guard replacesLegacy else { return nil }
        return "Replaced the \(HarnessProduct.legacyMCPServerName) server with \(HarnessProduct.mcpServerName) in \(host)."
    }

    /// The status line `setup` shows for `host` while it isn't done, naming `rerun` as the command
    /// that finishes it.
    public func pendingStatus(in host: String, rerun: String) -> String {
        if replacesLegacy, let legacy {
            return "\(host): registered as \(HarnessProduct.legacyMCPServerName) (\(legacy)); run `\(rerun)` to rename it \(HarnessProduct.mcpServerName)"
        }
        if let current, current != cli {
            return "\(host): registered with another CLI (\(current)); run `\(rerun)`"
        }
        return "\(host): not set up; run `\(rerun)`"
    }
}
