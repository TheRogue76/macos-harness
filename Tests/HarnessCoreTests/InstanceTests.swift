import Foundation
import HarnessProtocol
import Testing
@testable import HarnessCore

@Suite struct InstanceTests {
    let claude = "Claude Code|Q6L2SF6YDW|com.anthropic.claude-code"

    func process(_ pid: pid_t, _ name: String, parent: pid_t = 1) -> ProcessSnapshot {
        ProcessSnapshot(pid: pid, parentPID: parent, path: "/usr/bin/\(name)", arguments: [name])
    }

    @Test func namesSessionsByTheirFolder() {
        var names = InstanceNames()
        #expect(names.name(for: "\(claude)#10", folder: "macos-harness") { _ in true } == "macos-harness")
        #expect(names.name(for: "\(claude)#11", folder: "scrubs") { _ in true } == "scrubs")
        #expect(names.name(for: "\(claude)#10", folder: "macos-harness") { _ in true } == "macos-harness")
    }

    @Test func numbersSessionsThatShareAFolder() {
        var names = InstanceNames()
        #expect(names.name(for: "\(claude)#10", folder: "macos-harness") { _ in true } == "macos-harness")
        #expect(names.name(for: "\(claude)#11", folder: "macos-harness") { _ in true } == "macos-harness 2")
        #expect(names.name(for: "\(claude)#12", folder: nil) { _ in true } == "")
        #expect(names.name(for: "\(claude)#13", folder: nil) { _ in true } == "2")
        #expect(names.name(for: "Codex|unsigned|codex#14", folder: "macos-harness") { _ in true } == "macos-harness")
    }

    @Test func freesTheNameOfASessionThatEnded() {
        var names = InstanceNames()
        _ = names.name(for: "\(claude)#10", folder: "macos-harness") { _ in true }
        let name = names.name(for: "\(claude)#11", folder: "macos-harness") { $0 != "\(claude)#10" }
        #expect(name == "macos-harness")
    }

    @Test func splitsInstanceKeys() {
        #expect(InstanceNames.kindKey(of: "\(claude)#4211") == claude)
        #expect(InstanceNames.pid(of: "\(claude)#4211") == 4211)
        #expect(InstanceNames.pid(of: "\(claude)#0") == nil)
        #expect(InstanceNames.pid(of: claude) == nil)
        #expect(InstanceNames.kindKey(of: claude) == claude)
    }

    @Test func anInstanceIsTheAgentAndItsProcess() {
        let caller = CallerIdentity(displayName: "Claude Code", key: claude, chain: [], agentPID: 4211, workingDirectory: "/Users/me/src/macos-harness/")
        #expect(caller.instanceKey == "\(claude)#4211")
        #expect(caller.folder == "macos-harness")
    }

    @Test func anUnrecognizedCallerIsOneSession() {
        let script = AgentClassifier.identify(chain: [process(50, "macos-harness"), process(51, "bash", parent: 52), process(52, "bash")])
        let next = AgentClassifier.identify(chain: [process(53, "macos-harness"), process(54, "bash", parent: 52), process(52, "bash")])
        #expect(!AgentClassifier.recognized(script))
        #expect(script.instanceKey == script.key)
        #expect(script.instanceKey == next.instanceKey)
    }

    @Test func folderNamesSayNothingForRootOrHome() {
        #expect(AgentClassifier.folderName(of: "/Users/me/src/app", home: "/Users/me") == "app")
        #expect(AgentClassifier.folderName(of: "/Users/me/src/app/.claude/worktrees/musing-golick", home: "/Users/me") == "musing-golick")
        #expect(AgentClassifier.folderName(of: "/Users/me", home: "/Users/me") == nil)
        #expect(AgentClassifier.folderName(of: "/Users/me/", home: "/Users/me") == nil)
        #expect(AgentClassifier.folderName(of: "/", home: "/Users/me") == nil)
        #expect(AgentClassifier.folderName(of: nil, home: "/Users/me") == nil)
    }

    @Test func stopsCoverTheSessionAndWhatItStarts() {
        let stopped = ["\(claude)#20"]
        let session = CallerIdentity(displayName: "Claude Code", key: claude, chain: [process(30, "macos-harness"), process(20, "claude")], agentPID: 20)
        let other = CallerIdentity(displayName: "Claude Code", key: claude, chain: [process(31, "macos-harness"), process(21, "claude")], agentPID: 21)
        let child = CallerIdentity(
            displayName: "Claude Code", key: claude,
            chain: [process(32, "macos-harness"), process(22, "claude"), process(23, "zsh"), process(20, "claude")], agentPID: 22
        )
        #expect(StopRules.covers(session, stopped: stopped))
        #expect(!StopRules.covers(other, stopped: stopped))
        #expect(StopRules.covers(child, stopped: stopped))
        #expect(StopRules.covers(other, stopped: [claude]))
    }

    @Test func sessionsOfOneAgentStayApart() throws {
        var tracker = SessionTracker()
        let start = Date()
        for (index, key) in ["\(claude)#10", "\(claude)#11"].enumerated() {
            let request = RPCRequest(id: 1, method: SnapshotMethod.name, params: nil)
            let entry = try #require(ActivityDescriber.entry(
                for: request, response: RPCResponse(id: 1, result: .object([:])), agentKey: key, agentName: "Claude Code",
                instance: index == 0 ? "macos-harness" : "scrubs", date: start
            ))
            tracker.record(entry)
        }
        let sessions = tracker.active(at: start)
        #expect(sessions.count == 2)
        #expect(Set(sessions.compactMap(\.instance)) == ["macos-harness", "scrubs"])
        #expect(Set(sessions.map(\.kindKey)) == [claude])
    }

    @Test func onlyTheUserResetsPermissions() throws {
        let agent = AgentClassifier.identify(chain: [process(60, "macos-harness", parent: 61), process(61, "bash", parent: 62), process(62, "claude")])
        let typed = AgentClassifier.identify(chain: [process(63, "macos-harness", parent: 64), process(64, "bash")])
        #expect(AgentClassifier.isAgent(agent))
        #expect(!AgentClassifier.isAgent(typed))
        #expect(throws: RPCError.self) { try AgentClassifier.checkPermissionsChange(.reset, caller: agent) }
        try AgentClassifier.checkPermissionsChange(.grant, caller: agent)
        try AgentClassifier.checkPermissionsChange(.reset, caller: typed)
    }
}
