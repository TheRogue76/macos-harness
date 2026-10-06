import Foundation
import HarnessCore
import Testing

private func process(
    _ path: String, _ arguments: [String] = [], id: String? = nil, team: String? = nil, pid: Int32 = 100
) -> ProcessSnapshot {
    ProcessSnapshot(
        pid: pid, parentPID: pid - 1, path: path, arguments: arguments.isEmpty ? [path] : arguments,
        signingIdentifier: id, teamIdentifier: team
    )
}

private let cli = process(
    "/Users/me/Applications/macOS Harness Dev.app/Contents/MacOS/macos-harness",
    id: "io.github.therogue76.macos-harness.dev.cli", team: "26JTAUKKYH"
)
private let zsh = process("/bin/zsh", id: "com.apple.zsh")

struct AgentClassifierTests {
    @Test func recognizesClaudeCodeAcrossVersions() {
        let older = AgentClassifier.identify(chain: [
            cli, zsh,
            process("/Users/me/Library/Application Support/Claude/claude-code/2.1.288/x/claude.app/Contents/MacOS/claude",
                    id: "com.anthropic.claude-code", team: "Q6L2SF6YDW"),
            process("/Applications/Claude.app/Contents/MacOS/Claude", id: "com.anthropic.claudefordesktop", team: "Q6L2SF6YDW"),
        ])
        let newer = AgentClassifier.identify(chain: [
            cli, zsh,
            process("/Users/me/Library/Application Support/Claude/claude-code/2.2.0/y/claude.app/Contents/MacOS/claude",
                    id: "com.anthropic.claude-code", team: "Q6L2SF6YDW"),
        ])
        #expect(older.displayName == "Claude Code")
        #expect(older.key == newer.key)
    }

    @Test func recognizesCodexNativeBinary() {
        let caller = AgentClassifier.identify(chain: [
            cli, zsh,
            process("/Users/me/.bun/install/global/node_modules/@openai/codex/vendor/aarch64-apple-darwin/codex/codex"),
            process("/Users/me/.bun/bin/bun", ["bun", "/Users/me/.bun/bin/codex"]),
            process("/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal", id: "com.apple.Terminal"),
        ])
        #expect(caller.displayName == "Codex")
    }

    @Test func recognizesPiRunningUnderNode() {
        let caller = AgentClassifier.identify(chain: [
            cli, zsh,
            process("/Users/me/.nvm/versions/node/v26.5.0/bin/node",
                    ["node", "/Users/me/.nvm/versions/node/v26.5.0/bin/pi"], id: "node"),
        ])
        #expect(caller.displayName == "pi")
    }

    /// pi sets `process.title = "pi"`, which on macOS replaces its whole argument list.
    @Test func recognizesPiAfterItRenamesItself() {
        let caller = AgentClassifier.identify(chain: [
            cli, zsh,
            process("/Users/me/.nvm/versions/node/v26.5.0/bin/node", ["pi"], id: "node", team: "HX7739G8FX"),
            zsh,
            process("/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal", id: "com.apple.Terminal"),
        ])
        #expect(caller.displayName == "pi")
    }

    @Test func fallsBackToTerminalWhenTypedByHand() {
        let caller = AgentClassifier.identify(chain: [
            cli, zsh,
            process("/Applications/Ghostty.app/Contents/MacOS/ghostty", id: "com.mitchellh.ghostty", team: "24VZTF6M5V"),
        ])
        #expect(caller.displayName == "Ghostty (typed by you)")
    }

    @Test func fallsBackToNearestApp() {
        let caller = AgentClassifier.identify(chain: [
            cli, zsh,
            process("/Applications/Zed.app/Contents/MacOS/zed", id: "dev.zed.Zed", team: "MQ55VZLNZQ"),
        ])
        #expect(caller.displayName == "Zed")
        #expect(caller.key == "Zed|MQ55VZLNZQ|dev.zed.Zed")
    }

    @Test func unknownCallerStillGetsAStableName() {
        let caller = AgentClassifier.identify(chain: [cli, process("/usr/local/bin/mystery")])
        #expect(caller.displayName == "Unknown process (mystery)")
    }

    @Test func emptyChainDoesNotCrash() {
        #expect(AgentClassifier.identify(chain: []).displayName == "Unknown process")
    }
}

struct ProcessInspectorTests {
    @Test func parsesProcArgs() {
        var bytes: [UInt8] = []
        withUnsafeBytes(of: Int32(2).littleEndian) { bytes.append(contentsOf: $0) }
        bytes += Array("/usr/bin/node".utf8) + [0, 0, 0]
        bytes += Array("node".utf8) + [0] + Array("/opt/pi".utf8) + [0]
        bytes += Array("PATH=/usr/bin".utf8) + [0]
        #expect(ProcessInspector.parseProcArgs(bytes) == ["node", "/opt/pi"])
    }

    @Test func inspectsOwnProcessChain() {
        let chain = ProcessInspector.chain(from: getpid())
        #expect(chain.first?.pid == getpid())
        #expect(!(chain.first?.path.isEmpty ?? true))
        #expect(chain.count >= 1)
    }
}
