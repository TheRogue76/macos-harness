import ArgumentParser
import Foundation
import HarnessClient
import HarnessProtocol

@main
struct MacosHarness: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "macos-harness",
        abstract: "Let agents see and operate macOS apps.",
        discussion: "Commands talk to the macOS Harness menu bar helper, which holds the Screen Recording and Accessibility permissions. The helper starts automatically.",
        version: HarnessVersion.string,
        subcommands: [
            Doctor.self, Apps.self, Windows.self, Snapshot.self, Find.self, Screenshot.self, Menu.self,
            Press.self, SetValue.self, TypeText.self, Key.self, Focus.self, Select.self, ScrollTo.self,
            Increment.self, Decrement.self, MenuSelect.self, WindowCommand.self, Launch.self, Quit.self, Wait.self,
            Click.self, Hover.self, Drag.self, Scroll.self, MCP.self, Spike.self,
        ]
    )
}

struct OutputOptions: ParsableArguments {
    @Flag(help: "Print JSON instead of text.")
    var json = false
}

enum Output {
    static func json<T: Encodable>(_ value: T) throws {
        let encoder = HarnessJSON.encoder
        encoder.outputFormatting.insert(.prettyPrinted)
        print(String(decoding: try encoder.encode(value), as: UTF8.self))
    }

    static func error(_ message: String) {
        FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    }

    static func note(_ message: String) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }
}

extension HarnessConnection {
    /// Opens a connection and, if this agent isn't paired yet, tells the user where to approve it.
    static func openAnnouncingPairing() throws -> HarnessConnection {
        let connection = try HarnessConnection.open()
        let hello = try connection.call(
            HelloMethod.self,
            .init(clientVersion: HarnessVersion.string, clientKind: "cli"),
            timeout: 10
        )
        if !hello.caller.paired {
            Output.note("Waiting for you to allow “\(hello.caller.displayName)” in the macOS Harness prompt…")
        }
        return connection
    }
}

/// Runs a body, turning client and RPC errors into a message and exit code 1. With `json`, the
/// message is printed to stdout as `{"error": {"code": …, "message": …}}`.
func reportingErrors(json: Bool = false, _ body: () throws -> Void) throws {
    do {
        try body()
    } catch let error as HarnessClientError {
        try fail(RPCError(code: RPCErrorCode.internalError, message: error.description), json: json)
    } catch let error as RPCError {
        try fail(error, json: json)
    } catch let error as SocketError {
        try fail(RPCError(code: RPCErrorCode.internalError, message: error.description), json: json)
    }
}

/// Reports `error` as text on stderr, or as JSON on stdout, and exits with code 1.
func fail(_ error: RPCError, json: Bool) throws -> Never {
    if json {
        try Output.json(["error": error])
    } else {
        Output.error(error.message)
    }
    throw ExitCode.failure
}
