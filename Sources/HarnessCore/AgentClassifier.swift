import Foundation
import HarnessProtocol

/// Who is calling, as shown in the pairing prompt and remembered once approved.
public struct CallerIdentity: Sendable, Equatable {
    public var displayName: String
    /// Stable across agent updates: built from signing identity, not from versioned paths.
    public var key: String
    public var chain: [ProcessSnapshot]
    /// The process recognized as the agent; "this session only" approvals last while it runs.
    public var agentPID: pid_t?

    public init(displayName: String, key: String, chain: [ProcessSnapshot], agentPID: pid_t? = nil) {
        self.displayName = displayName
        self.key = key
        self.chain = chain
        self.agentPID = agentPID
    }

    /// The process that identified this caller, for showing who vouches for it.
    public var agentProcess: ProcessSnapshot? {
        chain.first { $0.pid == agentPID }
    }

    /// The command that connected, e.g. `macos-harness apps`.
    public var command: String {
        guard let first = chain.first else { return "" }
        let arguments = first.arguments.dropFirst().prefix(4).joined(separator: " ")
        return arguments.isEmpty ? first.name : "\(first.name) \(arguments)"
    }
}

/// Recognizes the agent behind a connection by walking the caller's process ancestry.
///
/// This is a consent aid, not a security boundary: anything running as the same user
/// can fake its ancestry. macOS permissions remain the real boundary.
public enum AgentClassifier {
    struct KnownAgent: Sendable {
        let name: String
        let matches: @Sendable (ProcessSnapshot) -> Bool
    }

    static let knownAgents: [KnownAgent] = [
        KnownAgent(name: "Claude Code") {
            $0.name == "claude" || $0.title == "claude" || $0.path.contains("/claude-code/")
                || ($0.signingIdentifier?.hasPrefix("com.anthropic.claude-code") ?? false)
        },
        KnownAgent(name: "Claude") {
            $0.signingIdentifier == "com.anthropic.claudefordesktop"
                || $0.path.hasSuffix("/Claude.app/Contents/MacOS/Claude")
        },
        KnownAgent(name: "Codex") {
            $0.name == "codex" || $0.name.hasPrefix("codex-") || $0.title == "codex"
                || ($0.signingIdentifier?.lowercased().contains("codex") ?? false)
                || scriptArguments($0).contains { $0.hasSuffix("/codex") || $0.contains("@openai/codex") }
        },
        KnownAgent(name: "pi") {
            $0.name == "pi" || $0.title == "pi" || $0.title == "pi-rpc"
                || scriptArguments($0).contains { $0.hasSuffix("/pi") || $0.contains("pi-coding-agent") }
        },
        KnownAgent(name: "Cursor Agent") { $0.name == "cursor-agent" },
        KnownAgent(name: "Gemini CLI") {
            $0.name == "gemini" || scriptArguments($0).contains { $0.contains("gemini-cli") }
        },
        KnownAgent(name: "opencode") { $0.name == "opencode" },
    ]

    static let terminals: [String: String] = [
        "com.apple.Terminal": "Terminal",
        "com.googlecode.iterm2": "iTerm",
        "com.mitchellh.ghostty": "Ghostty",
        "dev.warp.Warp-Stable": "Warp",
        "net.kovidgoyal.kitty": "kitty",
        "com.github.wez.wezterm": "WezTerm",
    ]

    /// Arguments after argv[0] that look like script paths (for node, bun, python launchers).
    static func scriptArguments(_ process: ProcessSnapshot) -> [String] {
        Array(process.arguments.dropFirst().prefix(3))
    }

    /// `chain` runs from the connecting process (usually the harness CLI) up toward launchd.
    public static func identify(chain: [ProcessSnapshot]) -> CallerIdentity {
        // Skip our own binaries; the caller is whoever started them.
        let ancestors = chain.drop { isOwnProcess($0) }

        for process in ancestors {
            if let agent = knownAgents.first(where: { $0.matches(process) }) {
                return CallerIdentity(displayName: agent.name, key: key(agent.name, process), chain: chain, agentPID: process.pid)
            }
        }
        for process in ancestors {
            if let id = process.signingIdentifier, let terminal = terminals[id] {
                let name = "\(terminal) (typed by you)"
                return CallerIdentity(displayName: name, key: key(terminal, process), chain: chain, agentPID: process.pid)
            }
        }
        if let app = ancestors.first(where: { $0.path.contains(".app/Contents/MacOS/") }) {
            let name = appName(fromExecutable: app.path)
            return CallerIdentity(displayName: name, key: key(name, app), chain: chain, agentPID: app.pid)
        }
        let fallback = ancestors.first ?? chain.first
        let name = fallback.map { "Unknown process (\($0.name))" } ?? "Unknown process"
        return CallerIdentity(displayName: name, key: key(name, fallback), chain: chain, agentPID: fallback?.pid)
    }

    static func isOwnProcess(_ process: ProcessSnapshot) -> Bool {
        if let id = process.signingIdentifier, id.hasPrefix(HarnessVariant.signingIdentifierPrefix) {
            return true
        }
        return process.name == "macos-harness"
    }

    static func key(_ name: String, _ process: ProcessSnapshot?) -> String {
        guard let process else { return "\(name)|unknown" }
        let team = process.teamIdentifier ?? "unsigned"
        let identifier = process.signingIdentifier ?? process.name
        return "\(name)|\(team)|\(identifier)"
    }

    static func appName(fromExecutable path: String) -> String {
        guard let range = path.range(of: ".app/Contents/MacOS/") else { return (path as NSString).lastPathComponent }
        let bundlePath = String(path[..<range.lowerBound])
        return (bundlePath as NSString).lastPathComponent
    }
}
