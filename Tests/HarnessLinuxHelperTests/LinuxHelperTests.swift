import Foundation
import HarnessCore
import HarnessLinux
import HarnessProtocol
import Testing
@testable import HarnessLinuxHelper

struct NotificationPromptTests {
    private let prompt = NotificationPrompt(appName: "macOS Harness")

    @Test func asksWithThreeButtonsAndTheProcessChain() {
        let caller = CallerIdentity(
            displayName: "Claude Code", key: "Claude Code|unsigned|claude",
            chain: [
                ProcessSnapshot(pid: 10, parentPID: 9, path: "/usr/bin/macos-harness", arguments: ["macos-harness"]),
                ProcessSnapshot(pid: 9, parentPID: 1, path: "/usr/bin/claude", arguments: ["claude"]),
            ],
            agentPID: 9, workingDirectory: "/home/someone/project"
        )
        let content = prompt.pairing(for: caller)
        #expect(content.actions.map(\.name) == ["allow", "session", "deny"])
        #expect(content.actions.map(\.label) == ["Allow", "This session", "Deny"])
        #expect(content.title == "Allow Claude Code to use macOS Harness?")
        #expect(content.body.contains("macos-harness ← claude"))
        #expect(content.body.contains("Working in /home/someone/project"))
    }

    @Test func readsTheChosenButton() {
        #expect(NotificationPrompt.decision(for: "allow") == .allow)
        #expect(NotificationPrompt.decision(for: "session") == .session)
        #expect(NotificationPrompt.decision(for: "deny") == .deny)
        #expect(NotificationPrompt.decision(for: nil) == .deny)
    }

    @Test func offersToSetUpAMissingPermission() {
        let item = PermissionsMethod.Item(id: "windows", name: "Windows", state: .missing, detail: "The extension isn't installed.")
        let content = prompt.setup(for: item)
        #expect(content.actions == [.init("setup", "Set up")])
        #expect(content.title == "macOS Harness needs a permission: Windows")
        #expect(content.body == "The extension isn't installed.")
    }
}
