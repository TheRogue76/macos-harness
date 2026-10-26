import Foundation
import HarnessProtocol

/// Who is calling, as shown in the pairing prompt and remembered once approved.
public struct CallerIdentity: Sendable, Equatable {
    public var displayName: String
    /// Identifies the agent, and stays the same across agent updates.
    public var key: String
    public var chain: [ProcessSnapshot]
    /// The process recognized as the agent; "this session only" approvals last while it runs.
    public var agentPID: pid_t?
    /// The agent process's current directory, which names the project it works in.
    public var workingDirectory: String? {
        didSet { folder = AgentClassifier.folderName(of: workingDirectory) }
    }
    /// The folder the agent works in, which tells two sessions of the same agent apart.
    public private(set) var folder: String?

    public init(displayName: String, key: String, chain: [ProcessSnapshot], agentPID: pid_t? = nil, workingDirectory: String? = nil) {
        self.displayName = displayName
        self.key = key
        self.chain = chain
        self.agentPID = agentPID
        self.workingDirectory = workingDirectory
        folder = AgentClassifier.folderName(of: workingDirectory)
    }

    /// Identifies this one running agent, such as one of several Claude Code sessions: the
    /// agent's key and its process. An unrecognized caller (a script, CI) has just its key, since
    /// the process found for it can be a new subshell on every call.
    public var instanceKey: String {
        AgentClassifier.recognized(self) ? "\(key)#\(agentPID ?? 0)" : key
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

/// Recognizes the agent behind a connection from the caller's process ancestry.
public enum AgentClassifier {
    package struct KnownAgent: Sendable {
        let name: String
        let matches: @Sendable (ProcessSnapshot) -> Bool
    }

    package static let knownAgents: [KnownAgent] = [
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

    package static let terminals: [String: String] = [
        "com.apple.Terminal": "Terminal",
        "com.googlecode.iterm2": "iTerm",
        "com.mitchellh.ghostty": "Ghostty",
        "dev.warp.Warp-Stable": "Warp",
        "net.kovidgoyal.kitty": "kitty",
        "com.github.wez.wezterm": "WezTerm",
    ]

    /// Arguments after argv[0] that look like script paths (for node, bun, python launchers).
    package static func scriptArguments(_ process: ProcessSnapshot) -> [String] {
        Array(process.arguments.dropFirst().prefix(3))
    }

    /// The caller behind `chain`, which runs from the connecting process up toward launchd.
    public static func identify(chain: [ProcessSnapshot]) -> CallerIdentity {
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

    /// The last component of a working directory, or nil for none, the root or the home folder,
    /// which say nothing about the project.
    public static func folderName(of path: String?, home: String = HarnessPaths.homeDirectory) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let standardized = (path as NSString).standardizingPath
        guard standardized != "/", standardized != (home as NSString).standardizingPath else { return nil }
        let name = (standardized as NSString).lastPathComponent
        return name.isEmpty ? nil : name
    }

    /// Whether a known coding agent is behind the caller, rather than someone typing in a
    /// terminal.
    public static func isAgent(_ identity: CallerIdentity) -> Bool {
        identity.chain.drop { isOwnProcess($0) }.contains { process in knownAgents.contains { $0.matches(process) } }
    }

    /// Refuses `permissions reset` from agents: taking back the helper's permissions is the
    /// user's call, made in their own terminal.
    public static func checkPermissionsChange(_ action: PermissionsMethod.Action, caller: CallerIdentity, command: String = "macos-harness") throws {
        guard action == .reset, isAgent(caller) else { return }
        throw RPCError(
            code: RPCErrorCode.failed,
            message: "Only the user can reset permissions. Ask them to run `\(command) permissions reset` in their own terminal."
        )
    }

    /// Refuses `resume` from agents: letting agents act again after a stop is the user's call.
    public static func checkResume(caller: CallerIdentity, command: String = "macos-harness") throws {
        guard isAgent(caller) else { return }
        throw RPCError(
            code: RPCErrorCode.failed,
            message: "Only the user can resume agents after a stop. Ask them to run `\(command) resume` in their own terminal."
        )
    }

    /// Whether the identity names an agent or terminal, rather than an unknown process.
    public static func recognized(_ identity: CallerIdentity) -> Bool {
        !identity.displayName.hasPrefix("Unknown process")
    }

    package static func isOwnProcess(_ process: ProcessSnapshot) -> Bool {
        if let id = process.signingIdentifier, id.hasPrefix(HarnessVariant.signingIdentifierPrefix) {
            return true
        }
        return process.name == "macos-harness"
    }

    package static func key(_ name: String, _ process: ProcessSnapshot?) -> String {
        guard let process else { return "\(name)|unknown" }
        let team = process.teamIdentifier ?? "unsigned"
        let identifier = process.signingIdentifier ?? process.name
        return "\(name)|\(team)|\(identifier)"
    }

    package static func appName(fromExecutable path: String) -> String {
        guard let range = path.range(of: ".app/Contents/MacOS/") else { return (path as NSString).lastPathComponent }
        let bundlePath = String(path[..<range.lowerBound])
        return (bundlePath as NSString).lastPathComponent
    }
}
