import Foundation

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

    /// The command the config runs macos-harness with, if it registers it.
    public static func registeredCommand(in config: [String: Any], for host: Host, name: String) -> String? {
        switch host {
        case .cursor:
            return serverCommand(in: config, name: name)
        case .opencode:
            return (((config["mcp"] as? [String: Any])?[name] as? [String: Any])?["command"] as? [String])?.first
        }
    }

    /// The config with macos-harness registered to run `cli mcp`, leaving every other entry as it was.
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
    public var backupPath: String { path + ".before-macos-harness" }

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
