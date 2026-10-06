import ArgumentParser
import Foundation
import HarnessClient
import HarnessProtocol

/// `macos-harness mcp`: a Model Context Protocol server over stdio.
///
/// Agent hosts start it outside their command sandbox, so it reaches the helper even where
/// a sandboxed shell can't. Each tool maps to one helper method; results use the same text
/// as the CLI, and screenshots come back as images.
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

