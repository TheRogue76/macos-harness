import ArgumentParser
import Foundation
import HarnessClient
import HarnessProtocol

/// `macos-harness mcp`: a Model Context Protocol server over stdio.
struct MCP: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Run as an MCP server on stdin/stdout (for Claude Code, Codex and other MCP hosts).",
        discussion: "--background-only keeps the agent off the real mouse and keyboard and stops it bringing apps to the front, for agents that run while you work (a scheduled job, say); steps that would need them fail with error 1005 instead. MACOS_HARNESS_BACKGROUND_ONLY=1 does the same for the CLI."
    )

    @Flag(help: "Never use the real mouse or keyboard or bring apps to the front; refuse steps that would.")
    var backgroundOnly = false

    func run() throws {
        if backgroundOnly { unsafe setenv(HarnessConnection.backgroundOnlyVariable, "1", 1) }
        let server = MCPServer()
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            if let reply = server.handle(line) {
                FileHandle.standardOutput.write(reply + Data("\n".utf8))
            }
        }
    }
}

