import ArgumentParser
import Foundation
import HarnessClient
import HarnessProtocol

struct Setup: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Connect an agent: register the MCP server with Claude Code, Codex, Cursor, Gemini CLI or opencode, or install the skill for pi.",
        discussion: "Shows what it will change and asks first. Without an agent, shows what's set up."
    )

    enum Agent: String, ExpressibleByArgument, CaseIterable {
        case claude, codex, cursor, gemini, opencode, pi
    }

    @Argument(help: "claude, codex, cursor, gemini, opencode or pi.")
    var agent: Agent?

    @Flag(help: "Apply without asking (for scripts and agents, after asking the user yourself).")
    var yes = false

    func run() throws {
        let cli = SetupPlan.cliPath()
        guard let agent else {
            for agent in Agent.allCases {
                print(SetupPlan.make(for: agent, cli: cli).status)
            }
            return
        }
        let plan = SetupPlan.make(for: agent, cli: cli)
        if let problem = plan.problem {
            Output.error(problem)
            throw ExitCode.failure
        }
        guard !plan.steps.isEmpty else {
            print(plan.status)
            return
        }
        print("To set up \(plan.agentName), macos-harness will:")
        for step in plan.steps { print("  \(step.description)") }
        if !yes {
            guard isatty(STDIN_FILENO) != 0 else {
                Output.error("Nothing changed. Run again with --yes to apply (ask the user first if you're an agent).")
                throw ExitCode.failure
            }
            print("Proceed? [y/N] ", terminator: "")
            guard let answer = readLine(), ["y", "yes"].contains(answer.lowercased()) else {
                print("Nothing changed.")
                return
            }
        }
        for step in plan.steps {
            do {
                try step.apply()
            } catch {
                Output.error("\(step.description) failed: \(error)")
                throw ExitCode.failure
            }
        }
        print(plan.done)
    }
}

/// What `setup` would change for one agent.
struct SetupPlan {
    struct Step {
        var description: String
        var apply: () throws -> Void
    }

    var agentName: String
    var status: String
    var steps: [Step] = []
    var problem: String?
    var done: String

    static let serverName = "macos-harness"

    /// The CLI's name as the user typed it, for hints.
    static var command: String { (cliPath() as NSString).lastPathComponent }

    static func make(for agent: Setup.Agent, cli: String) -> SetupPlan {
        switch agent {
        case .claude: claude(cli: cli)
        case .codex: codex(cli: cli)
        case .cursor: configFile(.cursor, cli: cli)
        case .gemini: gemini(cli: cli)
        case .opencode: configFile(.opencode, cli: cli)
        case .pi: pi(cli: cli)
        }
    }

    static func gemini(cli: String) -> SetupPlan {
        var plan = SetupPlan(agentName: "Gemini CLI", status: "", done: "Done. Start a new Gemini CLI session to use the macos-harness tools.")
        guard let gemini = which("gemini") else {
            plan.problem = "Gemini CLI (`gemini`) isn't on your PATH. Install it, or add the server yourself: gemini mcp add -s user \(serverName) \(cli) mcp"
            plan.status = "Gemini CLI: not installed"
            return plan
        }
        let settings = "\(HarnessPaths.homeDirectory)/.gemini/settings.json"
        let existing = FileManager.default.contents(atPath: settings)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            .flatMap { MCPConfigFile.serverCommand(in: $0, name: serverName) }
        if existing == cli {
            plan.status = "Gemini CLI: set up (user scope, \(cli))"
            return plan
        }
        plan.status = existing.map { "Gemini CLI: registered with another CLI (\($0)); run `\(command) setup gemini`" }
            ?? "Gemini CLI: not set up; run `\(command) setup gemini`"
        if existing != nil {
            plan.steps.append(command(gemini, ["mcp", "remove", "-s", "user", serverName]))
        }
        plan.steps.append(command(gemini, ["mcp", "add", "-s", "user", serverName, cli, "mcp"]))
        return plan
    }

    /// Cursor and opencode have no command to add a local server, so their config file is edited.
    static func configFile(_ host: MCPConfigFile.Host, cli: String) -> SetupPlan {
        let home = HarnessPaths.homeDirectory
        let file = MCPConfigFile(host: host, home: home)
        let name = host == .cursor ? "Cursor" : "opencode"
        let next = host == .cursor
            ? "Done. Restart Cursor or start a new `agent` session; the Cursor CLI may ask you to approve the server (`agent mcp enable \(serverName)`)."
            : "Done. Start a new opencode session to use the macos-harness tools."
        var plan = SetupPlan(agentName: name, status: "", done: next)
        let installed: Bool
        switch host {
        case .cursor:
            installed = which("cursor-agent") != nil || which("cursor") != nil
                || FileManager.default.fileExists(atPath: "/Applications/Cursor.app") || FileManager.default.fileExists(atPath: "\(home)/.cursor")
        case .opencode:
            installed = which("opencode") != nil || FileManager.default.fileExists(atPath: "\(home)/.config/opencode")
        }
        let shown = file.path.replacingOccurrences(of: home, with: "~")
        guard installed else {
            plan.problem = "\(name) isn't installed. Once it is, run `\(command) setup \(host == .cursor ? "cursor" : "opencode")`, or add the server to \(shown) yourself."
            plan.status = "\(name): not installed"
            return plan
        }
        if host == .opencode, FileManager.default.fileExists(atPath: file.path + "c") {
            plan.problem = "opencode's config is \(shown)c, with comments, which setup won't rewrite. Add this under \"mcp\" yourself: \"\(serverName)\": {\"type\": \"local\", \"command\": [\"\(cli)\", \"mcp\"], \"enabled\": true}"
            plan.status = "\(name): config has comments; set up by hand"
            return plan
        }
        let config: [String: Any]?
        do {
            config = try file.read()
        } catch {
            plan.problem = "\(error). Add the macos-harness server to it yourself, running `\(cli) mcp`."
            plan.status = "\(name): \(shown) can't be read safely"
            return plan
        }
        let existing = config.flatMap { MCPConfigFile.registeredCommand(in: $0, for: host, name: serverName) }
        if existing == cli {
            plan.status = "\(name): set up (\(shown), \(cli))"
            return plan
        }
        let key = host == .cursor ? "mcpServers" : "mcp"
        plan.status = existing.map { "\(name): registered with another CLI (\($0)); run `\(command) setup \(host == .cursor ? "cursor" : "opencode")`" }
            ?? "\(name): not set up; run `\(command) setup \(host == .cursor ? "cursor" : "opencode")`"
        let kept = config == nil ? "" : " (the old file is kept as \((file.backupPath as NSString).lastPathComponent))"
        plan.steps.append(Step(description: "\(config == nil ? "create" : "update") \(shown): set \(key).\(serverName) to run `\(cli) mcp`\(kept)") {
            try file.write(MCPConfigFile.registering(cli, in: config ?? [:], for: host, name: serverName))
        })
        return plan
    }

    static func claude(cli: String) -> SetupPlan {
        var plan = SetupPlan(agentName: "Claude Code", status: "", done: "Done. Start a new Claude Code session to use the macos-harness tools.")
        guard let claude = which("claude") else {
            plan.problem = "Claude Code (`claude`) isn't on your PATH. Install it, or add the server yourself: claude mcp add --scope user \(serverName) -- \(cli) mcp"
            plan.status = "Claude Code: not installed"
            return plan
        }
        let existing = claudeUserServerCommand()
        if existing == cli {
            plan.status = "Claude Code: set up (user scope, \(cli))"
            return plan
        }
        plan.status = existing.map { "Claude Code: registered with another CLI (\($0)); run `\(command) setup claude`" }
            ?? "Claude Code: not set up; run `\(command) setup claude`"
        if existing != nil {
            plan.steps.append(command(claude, ["mcp", "remove", "--scope", "user", serverName]))
        }
        plan.steps.append(command(claude, ["mcp", "add", "--scope", "user", serverName, "--", cli, "mcp"]))
        return plan
    }

    static func codex(cli: String) -> SetupPlan {
        var plan = SetupPlan(agentName: "Codex", status: "", done: "Done. Start a new Codex session to use the macos-harness tools.")
        guard let codex = which("codex") else {
            plan.problem = "Codex (`codex`) isn't on your PATH. Install it, or add the server yourself: codex mcp add \(serverName) -- \(cli) mcp"
            plan.status = "Codex: not installed"
            return plan
        }
        let existing = codexServerCommand(codex)
        if existing == cli {
            plan.status = "Codex: set up (\(cli))"
            return plan
        }
        plan.status = existing.map { "Codex: registered with another CLI (\($0)); run `\(command) setup codex`" }
            ?? "Codex: not set up; run `\(command) setup codex`"
        if existing != nil {
            plan.steps.append(command(codex, ["mcp", "remove", serverName]))
        }
        plan.steps.append(command(codex, ["mcp", "add", serverName, "--", cli, "mcp"]))
        return plan
    }

    static func pi(cli: String) -> SetupPlan {
        let home = HarnessPaths.homeDirectory
        let destination = "\(home)/.pi/agent/skills/\(serverName)"
        var plan = SetupPlan(agentName: "pi", status: "", done: "Done. pi loads the skill in new sessions (or run /reload).")
        guard which("pi") != nil || FileManager.default.fileExists(atPath: "\(home)/.pi/agent") else {
            plan.problem = "pi isn't installed (no `pi` on your PATH and no ~/.pi/agent)."
            plan.status = "pi: not installed"
            return plan
        }
        guard let skill = bundledSkill(cli: cli) else {
            plan.problem = "This macos-harness has no bundled skill; reinstall it."
            plan.status = "pi: skill unavailable"
            return plan
        }
        let target = "\(destination)/SKILL.md"
        let installed = try? String(contentsOfFile: target, encoding: .utf8)
        if installed == skill {
            plan.status = "pi: skill installed (\(target))"
            return plan
        }
        plan.status = installed == nil ? "pi: not set up; run `\(command) setup pi`" : "pi: skill out of date; run `\(command) setup pi`"
        plan.steps.append(Step(description: "\(installed == nil ? "write" : "update") \(target)") {
            try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
            try skill.write(toFile: target, atomically: true, encoding: .utf8)
        })
        return plan
    }

    /// The skill shipped in the app, naming this CLI the way the user invokes it.
    static func bundledSkill(cli: String) -> String? {
        guard let app = HelperLocator.locate()?.appURL else { return nil }
        let path = app.appendingPathComponent("Contents/Resources/skills/\(serverName)/SKILL.md").path
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let name = (cli as NSString).lastPathComponent
        guard name != serverName else { return text }
        return text.replacingOccurrences(of: "`\(serverName) ", with: "`\(name) ")
    }

    /// The path this CLI was started by, without resolving symlinks, so it survives upgrades.
    static func cliPath() -> String {
        let invoked = CommandLine.arguments[0]
        if invoked.contains("/") {
            return URL(fileURLWithPath: invoked).standardizedFileURL.path
        }
        return which(invoked) ?? Bundle.main.executablePath ?? invoked
    }

    static func which(_ program: String) -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        return path.split(separator: ":").map { "\($0)/\(program)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func claudeUserServerCommand() -> String? {
        let path = "\(HarnessPaths.homeDirectory)/.claude.json"
        guard let data = FileManager.default.contents(atPath: path),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = config["mcpServers"] as? [String: Any],
              let server = servers[serverName] as? [String: Any] else { return nil }
        return server["command"] as? String
    }

    static func codexServerCommand(_ codex: String) -> String? {
        guard let output = try? run(codex, ["mcp", "get", serverName, "--json"]),
              let config = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any],
              let transport = config["transport"] as? [String: Any] else { return nil }
        return transport["command"] as? String
    }

    static func command(_ program: String, _ arguments: [String]) -> Step {
        let shown = ([(program as NSString).lastPathComponent] + arguments).joined(separator: " ")
        return Step(description: "run: \(shown)") { _ = try run(program, arguments) }
    }

    @discardableResult
    static func run(_ program: String, _ arguments: [String]) throws -> String {
        try CommandRunner.run(program, arguments)
    }
}
