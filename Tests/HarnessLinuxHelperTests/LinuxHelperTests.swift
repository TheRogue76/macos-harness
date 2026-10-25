import Foundation
import HarnessCore
import HarnessProtocol
import Testing
@testable import HarnessLinuxHelper

struct NotificationPromptTests {
    private let prompt = NotificationPrompt(executable: "/usr/bin/notify-send", appName: "macOS Harness")

    @Test func asksWithThreeButtonsAndTheProcessChain() {
        let caller = CallerIdentity(
            displayName: "Claude Code", key: "Claude Code|unsigned|claude",
            chain: [
                ProcessSnapshot(pid: 10, parentPID: 9, path: "/usr/bin/macos-harness", arguments: ["macos-harness"]),
                ProcessSnapshot(pid: 9, parentPID: 1, path: "/usr/bin/claude", arguments: ["claude"]),
            ],
            agentPID: 9, workingDirectory: "/home/someone/project"
        )
        let arguments = prompt.arguments(for: caller, timeout: 120)
        #expect(arguments.contains("--action=allow=Allow"))
        #expect(arguments.contains("--action=session=This session"))
        #expect(arguments.contains("--action=deny=Deny"))
        #expect(arguments.contains("--expire-time=120000"))
        #expect(arguments.contains("Allow Claude Code to use macOS Harness?"))
        #expect(arguments.last?.contains("macos-harness ← claude") == true)
        #expect(arguments.last?.contains("Working in /home/someone/project") == true)
    }

    @Test func readsTheChosenButton() {
        #expect(NotificationPrompt.decision(fromOutput: "allow\n") == .allow)
        #expect(NotificationPrompt.decision(fromOutput: "session") == .session)
        #expect(NotificationPrompt.decision(fromOutput: "deny") == .deny)
        #expect(NotificationPrompt.decision(fromOutput: "") == .deny)
    }

    @Test func isMissingWithoutNotifySend() {
        #expect(NotificationPrompt.find(appName: "x", path: "/nonexistent") == nil)
    }
}

struct DistributionTests {
    @Test func readsThePrettyName() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("os-release-\(UUID())").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        try "NAME=\"Fedora Linux\"\nPRETTY_NAME=\"Fedora Linux 44 (Workstation Edition)\"\nID=fedora\n".write(toFile: path, atomically: true, encoding: .utf8)
        #expect(LinuxHelper.distribution(osRelease: path) == "Fedora Linux 44 (Workstation Edition)")
        #expect(LinuxHelper.distribution(osRelease: "/nonexistent") == nil)
    }
}
