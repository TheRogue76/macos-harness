import ArgumentParser
import Foundation
import HarnessClient
import HarnessProtocol

extension PermissionsMethod.Action: ExpressibleByArgument {}

struct PermissionsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "permissions",
        abstract: "Show what the system lets macOS Harness do, ask for what's missing, or take it all back.",
        discussion: """
            grant walks through the system's own dialogs one at a time, saying before each what it \
            will ask: Accessibility and Screen Recording on macOS; on GNOME the harness's Shell \
            extension, screenshots and the mouse and keyboard. reset removes only what macOS \
            Harness was given, so you can start over; it asks first.
            """
    )

    @Argument(help: "status (the default), grant or reset.")
    var action: PermissionsMethod.Action = .status

    @Argument(help: "One permission's id, as status lists it; every one when left out.")
    var item: String?

    @Flag(help: "Reset without asking (for scripts and agents, after asking the user yourself).")
    var yes = false

    @OptionGroup var output: OutputOptions

    func run() throws {
        try reportingErrors(json: output.json) {
            let connection = try HarnessConnection.open()
            let status = try connection.call(PermissionsMethod.self, .init(action: .status, item: item), timeout: 30)
            let chosen = status.items.filter { item == nil || $0.id == item }
            switch action {
            case .status:
                try show(.init(items: chosen))
            case .grant:
                try grant(chosen, connection: connection, status: status)
            case .reset:
                try reset(chosen, connection: connection)
            }
        }
    }

    func show(_ result: PermissionsMethod.Result) throws {
        if output.json { return try Output.json(result) }
        for line in result.performed { print(line) }
        for item in result.items { print("\(Render.permission(item))  [\(item.id)]") }
        for notice in result.notices { print("! \(notice)") }
    }

    func grant(_ chosen: [PermissionsMethod.Item], connection: HarnessConnection, status: PermissionsMethod.Result) throws {
        let missing = chosen.filter { $0.state == .missing }
        guard !missing.isEmpty else {
            if !output.json { print("Nothing to set up.") }
            return try show(status)
        }
        var performed: [String] = []
        var notices: [String] = []
        var last = status
        for (index, item) in missing.enumerated() {
            if !output.json {
                print("\(index + 1)/\(missing.count) \(item.name): \(item.prompt ?? item.detail)")
            }
            last = try connection.call(PermissionsMethod.self, .init(action: .grant, item: item.id), timeout: 330)
            performed += last.performed
            notices += last.notices
            if !output.json { for line in last.performed { print("  ✓ \(line)") } }
            if !last.notices.isEmpty { break }
            if index < missing.count - 1 {
                last = try waitForGrant(item, connection: connection, last: last)
            }
        }
        last.performed = performed
        last.notices = notices
        if output.json { return try Output.json(last) }
        print("")
        try show(.init(items: last.items, notices: notices))
    }

    /// Waits for the user to finish granting an item in the system's settings before asking for
    /// the next one, for up to three minutes.
    func waitForGrant(_ item: PermissionsMethod.Item, connection: HarnessConnection, last: PermissionsMethod.Result) throws -> PermissionsMethod.Result {
        var current = last
        guard current.items.first(where: { $0.id == item.id })?.state == .missing else { return current }
        if !output.json { print("  Waiting for you to turn it on (Ctrl-C to stop)…") }
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline, current.items.first(where: { $0.id == item.id })?.state == .missing {
            Thread.sleep(forTimeInterval: 1)
            current = try connection.call(PermissionsMethod.self, .init(action: .status), timeout: 30)
        }
        return current
    }

    func reset(_ chosen: [PermissionsMethod.Item], connection: HarnessConnection) throws {
        let names = chosen.filter { $0.state == .granted || $0.state == .missing }.map(\.name)
        guard !names.isEmpty else {
            if !output.json { print("Nothing to reset here.") }
            return
        }
        if !yes {
            print("This takes back what macOS Harness was given for: \(names.joined(separator: ", ")).")
            print("Agents can't use them until you run `\(SetupPlan.command) permissions grant` again.")
            guard isatty(STDIN_FILENO) != 0 else {
                Output.error("Nothing changed. Run again with --yes to reset (ask the user first if you're an agent).")
                throw ExitCode.failure
            }
            print("Proceed? [y/N] ", terminator: "")
            guard let answer = readLine(), ["y", "yes"].contains(answer.lowercased()) else {
                print("Nothing changed.")
                return
            }
        }
        try show(try connection.call(PermissionsMethod.self, .init(action: .reset, item: item), timeout: 60))
    }
}
