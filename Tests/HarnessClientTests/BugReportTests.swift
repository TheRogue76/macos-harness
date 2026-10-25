import Foundation
@testable import HarnessClient
import HarnessProtocol
import Testing

struct BugReportTests {
    private func entry(_ method: String, action: String? = nil, error: String? = nil, at seconds: Double) -> JournalEntry {
        var entry = JournalEntry(
            time: Date(timeIntervalSince1970: 1_800_000_000 + seconds), session: "s1", agent: "Claude Code", agentKey: "k", method: method,
            milliseconds: 12
        )
        entry.action = action
        entry.app = "Mail"
        entry.element = JournalEntry.Element(ref: "k3", role: "AXButton", label: "Reply to “Dinner with Ada”", identifier: nil)
        entry.error = error.map { RPCError(code: RPCErrorCode.failed, message: $0) }
        return entry
    }

    private func inputs(includeTitles: Bool) -> BugReport.Inputs {
        let session = JournalSession(
            id: "s1", agent: "Claude Code", started: Date(timeIntervalSince1970: 1_800_000_000),
            ended: Date(timeIntervalSince1970: 1_800_000_010), entries: 2, apps: ["Mail"], failures: 1
        )
        return BugReport.Inputs(
            generated: Date(timeIntervalSince1970: 1_800_000_100), macOS: "27.2", architecture: "arm64", cli: "0.10.0 (/opt/homebrew/bin/macos-harness)",
            xcode: "Xcode 27.1", doctor: "✓ Caller: Claude Code\n  journal: \(HarnessPaths.homeDirectory)/Library/Logs/macos-harness/journal",
            sessions: [(session, [
                entry("act", action: "press", at: 1),
                entry("act", action: "press", error: "Window 7 “Dinner with Ada” closed", at: 2),
            ])],
            includeTitles: includeTitles
        )
    }

    @Test func titlesAndTheHomeFolderAreLeftOut() {
        let text = BugReport.text(inputs(includeTitles: false))
        #expect(!text.contains("Dinner"))
        #expect(text.contains("“…”"))
        #expect(!text.contains(HarnessPaths.homeDirectory))
        #expect(text.contains("~/Library/Logs/macos-harness/journal"))
        #expect(text.contains("## Recent errors"))
        #expect(text.contains("Xcode 27.1"))
    }

    @Test func titlesStayWhenAsked() {
        #expect(BugReport.text(inputs(includeTitles: true)).contains("Dinner with Ada"))
    }
}
