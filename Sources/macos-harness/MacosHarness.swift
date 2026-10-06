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
        subcommands: [Doctor.self, Apps.self, Spike.self]
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

/// Runs a body, turning client and RPC errors into a message and exit code 1.
func reportingErrors(_ body: () throws -> Void) throws {
    do {
        try body()
    } catch let error as HarnessClientError {
        Output.error(error.description)
        throw ExitCode.failure
    } catch let error as RPCError {
        Output.error(error.message)
        throw ExitCode.failure
    } catch let error as SocketError {
        Output.error(error.description)
        throw ExitCode.failure
    }
}
