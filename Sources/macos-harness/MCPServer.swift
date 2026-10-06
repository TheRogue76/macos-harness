import ArgumentParser
import Foundation
import HarnessClient
import HarnessProtocol

/// `macos-harness mcp`: a Model Context Protocol server over stdio.
struct MCP: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Run as an MCP server on stdin/stdout (for Claude Code, Codex and other MCP hosts)."
    )

    func run() throws {
        let server = MCPServer()
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            if let reply = server.handle(line) {
                FileHandle.standardOutput.write(reply + Data("\n".utf8))
            }
        }
    }
}

