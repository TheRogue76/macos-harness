import Foundation
import HarnessCore
import HarnessProtocol
import Testing

private func request(_ method: String, _ params: JSONValue? = nil) -> RPCRequest {
    RPCRequest(id: 1, method: method, params: params)
}

private func describe(_ method: String, params: JSONValue? = nil, result: JSONValue = .object([:]), error: RPCError? = nil) -> ActivityEntry? {
    let response = error.map { RPCResponse(id: 1, error: $0) } ?? RPCResponse(id: 1, result: result)
    return ActivityDescriber.entry(for: request(method, params), response: response, agentKey: "k", agentName: "Codex")
}

private let calculatorWindow: JSONValue = .object([
    "id": .number(9074),
    "app": .object(["name": .string("Calculator"), "pid": .number(1)]),
    "frame": .object(["x": .number(10), "y": .number(20), "width": .number(230), "height": .number(408)]),
])

struct ActivityDescriberTests {
    @Test func skipsBookkeeping() {
        #expect(describe("hello") == nil)
        #expect(describe("doctor") == nil)
    }

    @Test func describesASnapshot() throws {
        let entry = try #require(describe(
            "snapshot",
            params: .object(["target": .object(["app": .string("calculator")])]),
            result: .object(["window": calculatorWindow, "shownCount": .number(31)])
        ))
        #expect(entry.summary == "read Calculator · 31 elements")
        #expect(entry.kind == "reading")
        #expect(entry.windowID == 9074)
        #expect(entry.windowFrame == Rect(x: 10, y: 20, width: 230, height: 408))
    }

    @Test func describesFindAndScreenshot() throws {
        let find = try #require(describe(
            "find",
            params: .object(["target": .object(["app": .string("TextEdit")]), "text": .string("Save")]),
            result: .object(["matches": .array([.null, .null])])
        ))
        #expect(find.summary == "found 2 × “Save” in TextEdit")

        let shot = try #require(describe(
            "screenshot",
            params: .object(["target": .object(["app": .string("Weather")]), "labels": .bool(true), "element": .string("e17")]),
            result: .object(["window": calculatorWindow])
        ))
        #expect(shot.summary == "screenshot of Calculator · e17 (labeled)")
    }

    @Test func marksFailures() throws {
        let entry = try #require(describe(
            "snapshot", params: .object(["target": .object(["app": .string("Nope")])]),
            error: RPCError(code: 1003, message: "no app")
        ))
        #expect(entry.failed)
        #expect(entry.summary == "read Nope (failed)")
    }
}

struct SessionTrackerTests {
    private func entry(_ agent: String, at seconds: TimeInterval, window: UInt32? = nil) -> ActivityEntry {
        ActivityEntry(
            date: Date(timeIntervalSince1970: seconds), agentKey: agent, agentName: agent, method: "snapshot",
            summary: "read", kind: "reading", app: "App", windowID: window
        )
    }

    @Test func groupsStepsIntoOneSession() {
        var tracker = SessionTracker(idleTimeout: 120)
        tracker.record(entry("codex", at: 0, window: 1))
        tracker.record(entry("codex", at: 30))
        tracker.record(entry("pi", at: 40))
        let active = tracker.active(at: Date(timeIntervalSince1970: 50))
        #expect(active.map(\.agentKey) == ["pi", "codex"])
        #expect(active.last?.steps == 2)
        #expect(active.last?.lastWindowID == 1)
        #expect(tracker.recent.count == 3)
    }

    @Test func startsOverAfterGoingQuiet() {
        var tracker = SessionTracker(idleTimeout: 120)
        tracker.record(entry("codex", at: 0))
        tracker.record(entry("codex", at: 500))
        let session = tracker.active(at: Date(timeIntervalSince1970: 510)).first
        #expect(session?.steps == 1)
        #expect(session?.startedAt == Date(timeIntervalSince1970: 500))
        #expect(tracker.active(at: Date(timeIntervalSince1970: 700)).isEmpty)
    }

    @Test func capsRecentActivity() {
        var tracker = SessionTracker()
        tracker.recentLimit = 3
        for second in 0..<5 { tracker.record(entry("codex", at: TimeInterval(second))) }
        #expect(tracker.recent.count == 3)
        #expect(tracker.recent.first?.date == Date(timeIntervalSince1970: 4))
    }
}

struct SignerNameTests {
    @Test func extractsTheOrganization() {
        #expect(ProcessInspector.signerName(fromCertificateSummary: "Developer ID Application: OpenAI, L.L.C. (2DC432GLL2)") == "OpenAI, L.L.C.")
        #expect(ProcessInspector.signerName(fromCertificateSummary: "Apple Development: Parsa Nasirimehr (26JTAUKKYH)") == "Parsa Nasirimehr")
        #expect(ProcessInspector.signerName(fromCertificateSummary: "Software Signing") == "Apple")
    }
}
