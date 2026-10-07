import Foundation
import HarnessProtocol
import Testing
@testable import HarnessCore

private let caller = CallerIdentity(displayName: "Claude Code", key: "Claude Code|Q6L2SF6YDW|com.anthropic.claude-code", chain: [])

private func act(_ action: String, value: String?, app: String = "Notes") -> RPCRequest {
    var params: [String: JSONValue] = [
        "target": .object(["app": .string(app)]),
        "action": .string(action),
        "element": .object(["text": .string("Body"), "exact": .bool(false)]),
    ]
    if let value { params["value"] = .string(value) }
    return RPCRequest(id: 1, method: ActMethod.name, params: .object(params))
}

private let pressed = RPCResponse(id: 1, result: .object([
    "app": .object(["name": .string("Notes"), "pid": .number(42)]),
    "window": .object(["id": .number(7)]),
    "element": .object(["ref": .string("k3"), "role": .string("AXTextArea"), "label": .string("Body")]),
    "performed": .string("typed “my secret phrase” into textarea “Body” (k3)"),
    "via": .string("AX"),
    "changes": .array([.object(["kind": .string("changed")])]),
    "moreChanges": .number(2),
    "notices": .array([.object(["kind": .string("editing"), "message": .string("…")])]),
]))

struct JournalTests {
    @Test func typedTextIsNeverRecorded() throws {
        let entry = Journal.entry(
            for: act("type", value: "my secret phrase"), response: pressed, caller: caller, session: "s", milliseconds: 12, at: Date()
        )
        #expect(entry.value == nil)
        #expect(entry.redactedLength == 16)
        #expect(entry.params?["value"] == nil)
        #expect(entry.params?["action"]?.stringValue == "type")
        let line = String(decoding: try JournalEntry.lineEncoder.encode(entry), as: UTF8.self)
        #expect(!line.contains("secret"))
        #expect(!line.contains("\n"))
    }

    @Test func setValuesAreRedactedToo() {
        let entry = Journal.entry(for: act("set-value", value: "hunter2"), response: pressed, caller: caller, session: "s", milliseconds: 1, at: Date())
        #expect(entry.value == nil)
        #expect(entry.redactedLength == 7)
    }

    @Test func recordsWhatHappened() {
        let entry = Journal.entry(for: act("key", value: "cmd+s"), response: pressed, caller: caller, session: "s", milliseconds: 5, at: Date())
        #expect(entry.value == "cmd+s")
        #expect(entry.app == "Notes")
        #expect(entry.window == 7)
        #expect(entry.action == "key")
        #expect(entry.selector == ElementSelector(text: "Body"))
        #expect(entry.element == .init(ref: "k3", role: "AXTextArea", label: "Body", identifier: nil))
        #expect(entry.via == "AX")
        #expect(entry.changes == 3)
        #expect(entry.notices == ["editing"])
    }

    @Test func noDiffMeansNoChangeCount() {
        var request = act("press", value: nil)
        if case .object(var params) = request.params {
            params["diff"] = .bool(false)
            request = RPCRequest(id: 1, method: ActMethod.name, params: .object(params))
        }
        let entry = Journal.entry(for: request, response: pressed, caller: caller, session: "s", milliseconds: 1, at: Date())
        #expect(entry.changes == nil)
    }

    @Test func failuresKeepTheError() {
        let refused = RPCResponse(id: 1, error: RPCError(code: RPCErrorCode.blockedByPolicy, message: "read-only"))
        let entry = Journal.entry(for: act("press", value: nil, app: "Mail"), response: refused, caller: caller, session: "s", milliseconds: 1, at: Date())
        #expect(entry.app == "Mail")
        #expect(entry.error?.code == RPCErrorCode.blockedByPolicy)
    }

    @Test func launchSecretsAreLeftOut() {
        let request = RPCRequest(id: 1, method: LaunchMethod.name, params: .object([
            "app": .string("MyApp"), "arguments": .array([.string("--token=abc123")]),
            "environment": .object(["API_KEY": .string("sk-secret")]), "open": .array([]), "activate": .bool(false),
        ]))
        let entry = Journal.entry(for: request, response: RPCResponse(id: 1, result: .object([:])), caller: caller, session: "s", milliseconds: 1, at: Date())
        let line = String(decoding: (try? JournalEntry.lineEncoder.encode(entry)) ?? Data(), as: UTF8.self)
        #expect(!line.contains("abc123") && !line.contains("sk-secret"))
        #expect(line.contains("API_KEY"))
    }

    @Test func menuPathsAreJoined() {
        let request = RPCRequest(id: 1, method: MenuSelectMethod.name, params: .object([
            "app": .string("TextEdit"), "path": .array([.string("File"), .string("Save…")]),
        ]))
        let entry = Journal.entry(for: request, response: RPCResponse(id: 1, result: .object([:])), caller: caller, session: "s", milliseconds: 1, at: Date())
        #expect(entry.value == "File › Save…")
    }

    @Test func sessionsSplitAfterQuietTime() async {
        let journal = Journal(directory: NSTemporaryDirectory())
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = await journal.sessionID(for: caller, at: start)
        let same = await journal.sessionID(for: caller, at: start.addingTimeInterval(60))
        let next = await journal.sessionID(for: caller, at: start.addingTimeInterval(60 + Journal.idleTimeout + 1))
        #expect(first == same)
        #expect(first != next)
        #expect(first.hasSuffix("-claude-code"))
        var other = caller
        other.agentPID = 4242
        let parallel = await journal.sessionID(for: other, at: start.addingTimeInterval(61))
        #expect(parallel != same)
        #expect(Journal.slug("pi") == "pi")
        #expect(Journal.slug("Terminal (typed by you)") == "terminal-typed-by-you")
    }

    @Test func recordsReadsBackAndPrunes() async throws {
        let directory = NSTemporaryDirectory() + "journal-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let journal = Journal(directory: directory)
        await journal.record(act("type", value: "hello"), response: pressed, caller: caller, milliseconds: 3)
        await journal.record(act("press", value: nil), response: pressed, caller: caller, milliseconds: 4)
        await journal.record(RPCRequest(id: 9, method: HelloMethod.name, params: nil), response: pressed, caller: caller, milliseconds: 1)

        let sessions = JournalReader.sessions(in: directory)
        #expect(sessions.count == 1)
        #expect(sessions.first?.entries == 2)
        #expect(sessions.first?.apps == ["Notes"])
        let entries = try JournalReader.entries(of: try #require(sessions.first?.id), in: directory)
        #expect(entries.map(\.action) == ["type", "press"])

        let file = (directory as NSString).appendingPathComponent("\(sessions[0].id).jsonl")
        let permissions = try FileManager.default.attributesOfItem(atPath: file)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-31 * 86_400)], ofItemAtPath: file)
        await journal.prune()
        #expect(JournalReader.sessions(in: directory).isEmpty)
    }
}
