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
        print("To set up \(plan.agentName), \(HarnessProduct.commandName) will:")
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

    static let serverName = HarnessProduct.mcpServerName
    static let legacyServerName = HarnessProduct.legacyMCPServerName

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
        var plan = SetupPlan(agentName: "Gemini CLI", status: "", done: "Done. Start a new Gemini CLI session to use the \(HarnessProduct.mcpServerName) tools.")
        guard let gemini = which("gemini") else {
            plan.problem = "Gemini CLI (`gemini`) isn't on your PATH. Install it, or add the server yourself: gemini mcp add -s user \(serverName) \(cli) mcp"
            plan.status = "Gemini CLI: not installed"
            return plan
        }
        let settings = "\(HarnessPaths.homeDirectory)/.gemini/settings.json"
        let registration = MCPRegistration(cli: cli) { MCPConfigFile.serverCommand(inFileAt: settings, name: $0) }
        if registration.isDone {
            plan.status = "Gemini CLI: set up (user scope, \(cli))"
            return plan
        }
        if let problem = registration.conflictProblem(in: "Gemini CLI") {
            plan.problem = problem
            plan.status = "Gemini CLI: \(serverName) runs another program"
            return plan
        }
        plan.status = registration.pendingStatus(in: "Gemini CLI", rerun: "\(command) setup gemini")
        plan.migrate(registration, in: "Gemini CLI", with: gemini, remove: { ["mcp", "remove", "-s", "user", $0] }, add: ["mcp", "add", "-s", "user", serverName, cli, "mcp"])
        return plan
    }

    /// Says in the closing message that the old server was replaced, when it is.
    mutating func replaced(_ registration: MCPRegistration, in host: String) {
        if let notice = registration.replacedNotice(in: host) {
            done = "\(notice) \(done)"
        }
    }

    /// Adds the steps for a host with `mcp remove` and `mcp add` commands of its own: removing
    /// the old server when it runs this CLI, then registering `serverName` unless it already runs
    /// the right CLI.
    mutating func migrate(
        _ registration: MCPRegistration, in host: String, with program: String, remove: (String) -> [String], add: [String]
    ) {
        replaced(registration, in: host)
        if registration.replacesLegacy {
            steps.append(Self.command(program, remove(Self.legacyServerName)))
        }
        guard registration.registers else { return }
        if registration.current != nil {
            steps.append(Self.command(program, remove(Self.serverName)))
        }
        steps.append(Self.command(program, add))
    }

    /// Cursor and opencode have no command to add a local server, so their config file is edited.
    static func configFile(_ host: MCPConfigFile.Host, cli: String) -> SetupPlan {
        let home = HarnessPaths.homeDirectory
        let file = MCPConfigFile(host: host, home: home)
        let name = host == .cursor ? "Cursor" : "opencode"
        let next = host == .cursor
            ? "Done. Restart Cursor or start a new `agent` session; the Cursor CLI may ask you to approve the server (`agent mcp enable \(serverName)`)."
            : "Done. Start a new opencode session to use the \(HarnessProduct.mcpServerName) tools."
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
            plan.problem = "\(error). Add the \(HarnessProduct.mcpServerName) server to it yourself, running `\(cli) mcp`."
            plan.status = "\(name): \(shown) can't be read safely"
            return plan
        }
        let registration = MCPRegistration(cli: cli) { server in
            config.flatMap { MCPConfigFile.registeredCommand(in: $0, for: host, name: server) }
        }
        if registration.isDone {
            plan.status = "\(name): set up (\(shown), \(cli))"
            return plan
        }
        if let problem = registration.conflictProblem(in: name) {
            plan.problem = problem
            plan.status = "\(name): \(serverName) runs another program"
            return plan
        }
        let key = host == .cursor ? "mcpServers" : "mcp"
        plan.status = registration.pendingStatus(in: name, rerun: "\(command) setup \(host == .cursor ? "cursor" : "opencode")")
        plan.replaced(registration, in: name)
        let changes = [
            registration.registers ? "set \(key).\(serverName) to run `\(cli) mcp`" : nil,
            registration.replacesLegacy ? "remove \(key).\(legacyServerName)" : nil,
        ].compactMap { $0 }.joined(separator: " and ")
        let kept = config == nil ? "" : " (the old file is kept as \((file.backupPath as NSString).lastPathComponent))"
        plan.steps.append(Step(description: "\(config == nil ? "create" : "update") \(shown): \(changes)\(kept)") {
            try file.write(MCPConfigFile.migrating(cli, in: config ?? [:], for: host))
        })
        return plan
    }

    static func claude(cli: String) -> SetupPlan {
        var plan = SetupPlan(agentName: "Claude Code", status: "", done: "Done. Start a new Claude Code session to use the \(HarnessProduct.mcpServerName) tools.")
        guard let claude = which("claude") else {
            plan.problem = "Claude Code (`claude`) isn't on your PATH. Install it, or add the server yourself: claude mcp add --scope user \(serverName) -- \(cli) mcp"
            plan.status = "Claude Code: not installed"
            return plan
        }
        let settings = "\(HarnessPaths.homeDirectory)/.claude.json"
        let registration = MCPRegistration(cli: cli) { MCPConfigFile.serverCommand(inFileAt: settings, name: $0) }
        if registration.isDone {
            plan.status = "Claude Code: set up (user scope, \(cli))"
            return plan
        }
        if let problem = registration.conflictProblem(in: "Claude Code") {
            plan.problem = problem
            plan.status = "Claude Code: \(serverName) runs another program"
            return plan
        }
        plan.status = registration.pendingStatus(in: "Claude Code", rerun: "\(command) setup claude")
        plan.migrate(
            registration, in: "Claude Code", with: claude,
            remove: { ["mcp", "remove", "--scope", "user", $0] }, add: ["mcp", "add", "--scope", "user", serverName, "--", cli, "mcp"]
        )
        return plan
    }

    static func codex(cli: String) -> SetupPlan {
        var plan = SetupPlan(agentName: "Codex", status: "", done: "Done. Start a new Codex session to use the \(HarnessProduct.mcpServerName) tools.")
        guard let codex = which("codex") else {
            plan.problem = "Codex (`codex`) isn't on your PATH. Install it, or add the server yourself: codex mcp add \(serverName) -- \(cli) mcp"
            plan.status = "Codex: not installed"
            return plan
        }
        let registration = MCPRegistration(cli: cli) { codexServerCommand(codex, name: $0) }
        if registration.isDone {
            plan.status = "Codex: set up (\(cli))"
            return plan
        }
        if let problem = registration.conflictProblem(in: "Codex") {
            plan.problem = problem
            plan.status = "Codex: \(serverName) runs another program"
            return plan
        }
        plan.status = registration.pendingStatus(in: "Codex", rerun: "\(command) setup codex")
        plan.migrate(registration, in: "Codex", with: codex, remove: { ["mcp", "remove", $0] }, add: ["mcp", "add", serverName, "--", cli, "mcp"])
        return plan
    }

    static func pi(cli: String) -> SetupPlan {
        let home = HarnessPaths.homeDirectory
        let destination = "\(home)/.pi/agent/skills/\(HarnessProduct.skillName)"
        var plan = SetupPlan(agentName: "pi", status: "", done: "Done. pi loads the skill in new sessions (or run /reload).")
        guard which("pi") != nil || FileManager.default.fileExists(atPath: "\(home)/.pi/agent") else {
            plan.problem = "pi isn't installed (no `pi` on your PATH and no ~/.pi/agent)."
            plan.status = "pi: not installed"
            return plan
        }
        guard let skill = bundledSkill(cli: cli) else {
            plan.problem = "This \(HarnessProduct.commandName) has no bundled skill; reinstall it."
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
        let path = app.appendingPathComponent("Contents/Resources/skills/\(HarnessProduct.skillName)/SKILL.md").path
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let name = (cli as NSString).lastPathComponent
        guard name != skillCommand else { return text }
        return text.replacingOccurrences(of: "`\(skillCommand) ", with: "`\(name) ")
    }

    /// The command name the bundled skill's text uses.
    static let skillCommand = HarnessProduct.legacyCommandName

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

    static func codexServerCommand(_ codex: String, name: String) -> String? {
        guard let output = try? run(codex, ["mcp", "get", name, "--json"]),
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
