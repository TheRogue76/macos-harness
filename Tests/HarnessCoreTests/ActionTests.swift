import CoreGraphics
import Foundation
import HarnessClient
import HarnessProtocol
import Testing
@testable import HarnessCore

struct KeyComboTests {
    @Test func parsesNamedModifiers() throws {
        let combo = try KeyCombo.parse("cmd+shift+s")
        #expect(combo.keyCode == 1)
        #expect(combo.flags.contains(.maskCommand))
        #expect(combo.flags.contains(.maskShift))
        #expect(combo.display == "⇧⌘S")
    }

    @Test func parsesSymbolsAndSpecialKeys() throws {
        #expect(try KeyCombo.parse("⇧⌘G").keyCode == 5)
        #expect(try KeyCombo.parse("return").keyCode == 36)
        #expect(try KeyCombo.parse("esc").display == "⎋")
        #expect(try KeyCombo.parse("ctrl+opt+cmd+.").display == "⌃⌥⌘.")
        #expect(try KeyCombo.parse("f5").keyCode == 96)
    }

    @Test func rejectsNonsense() {
        #expect(throws: RPCError.self) { try KeyCombo.parse("cmd+banana") }
        #expect(throws: RPCError.self) { try KeyCombo.parse("hyper+s") }
    }
}

struct ElementSearchTests {
    private func node(_ role: String, _ label: String? = nil, subrole: String? = nil, id: String? = nil, actions: [String] = [], frame: CGRect? = CGRect(x: 0, y: 0, width: 50, height: 20), children: [RawNode] = []) -> RawNode {
        RawNode(key: AnyHashable(UUID()), role: role, subrole: subrole, title: label, identifier: id, actions: actions, frame: frame, children: children)
    }

    @Test func anElementReachedTwiceIsOneMatch() {
        let key = AnyHashable("same element")
        let button = RawNode(key: key, role: "AXButton", title: "Play", actions: ["AXPress"], frame: CGRect(x: 0, y: 0, width: 50, height: 20))
        let root = node("AXWindow", "W", children: [node("AXGroup", children: [button]), node("AXGroup", children: [button])])
        #expect(ElementSearch.search(root, for: ElementSelector(text: "Play"), clip: CGRect(x: 0, y: 0, width: 500, height: 500), limit: 10).count == 1)
    }

    @Test func windowsMatchOnlyWhenAskedFor() {
        let window = node("AXWindow", "Notes – 1 note")
        #expect(!ElementSearch.matches(window, ElementSelector(text: "Notes")))
        #expect(ElementSearch.matches(window, ElementSelector(text: "1 note", role: "window")))
    }

    @Test func roleAliasesMatchSnapshotNames() {
        #expect(ElementSearch.roleMatches("switch", node("AXCheckBox", subrole: "AXSwitch")))
        #expect(!ElementSearch.roleMatches("switch", node("AXCheckBox")))
        #expect(ElementSearch.roleMatches("text", node("AXStaticText")))
        #expect(ElementSearch.roleMatches("button", node("AXButton")))
        #expect(ElementSearch.roleMatches("AXPopUpButton", node("AXPopUpButton")))
        #expect(ElementSearch.roleMatches("popup", node("AXPopUpButton")))
    }

    @Test func singlePrefersVisibleActionableExactMatches() throws {
        let window = CGRect(x: 0, y: 0, width: 400, height: 300)
        let root = node("AXWindow", frame: window, children: [
            node("AXStaticText", "Save", frame: CGRect(x: 10, y: 10, width: 40, height: 20)),
            node("AXButton", "Save As…", actions: ["AXPress"], frame: CGRect(x: 10, y: 40, width: 60, height: 20)),
            node("AXButton", "Save", actions: ["AXPress"], frame: CGRect(x: 10, y: 70, width: 60, height: 20)),
            node("AXButton", "Save", actions: ["AXPress"], frame: CGRect(x: 10, y: 900, width: 60, height: 20)),
        ])
        let selector = ElementSelector(text: "save")
        let hits = ElementSearch.search(root, for: selector, clip: window, limit: 10)
        #expect(hits.count == 4)
        let chosen = try ElementSearch.single(hits, selector: selector) { _ in "" }
        #expect(chosen.raw.label == "Save")
        #expect(chosen.raw.role == "AXButton")
        #expect(chosen.visible != nil)
    }

    @Test func ambiguityListsCandidates() {
        let window = CGRect(x: 0, y: 0, width: 400, height: 300)
        let root = node("AXWindow", frame: window, children: [
            node("AXButton", "OK", actions: ["AXPress"], frame: CGRect(x: 10, y: 10, width: 40, height: 20)),
            node("AXButton", "OK", actions: ["AXPress"], frame: CGRect(x: 10, y: 40, width: 40, height: 20)),
        ])
        let selector = ElementSelector(text: "OK")
        let hits = ElementSearch.search(root, for: selector, clip: window, limit: 10)
        #expect(throws: RPCError.self) { try ElementSearch.single(hits, selector: selector) { _ in "candidate" } }
    }
}

struct SettleDiffTests {
    @Test func reportsAddedRemovedAndChanged() {
        let before: [(ref: String, node: UINode)] = [
            ("a1", UINode(ref: "a1", role: "AXStaticText", value: "79")),
            ("a2", UINode(ref: "a2", role: "AXButton", label: "OK")),
            ("a3", UINode(ref: "a3", role: "AXButton", label: "Keep")),
        ]
        let after: [(ref: String, node: UINode)] = [
            ("a1", UINode(ref: "a1", role: "AXStaticText", value: "797")),
            ("a3", UINode(ref: "a3", role: "AXButton", label: "Keep")),
            ("a4", UINode(ref: "a4", role: "AXSheet", label: "save")),
        ]
        let changes = Settle.diff(before: before, after: after)
        #expect(changes.map(\.kind) == ["changed", "added", "removed"])
        #expect(Render.change(changes[0]) == #"~ a1 text "79" → "797""#)
        #expect(Render.change(changes[1]) == #"+ a4 sheet "save""#)
        #expect(Render.change(changes[2]) == #"- a2 button "OK""#)
    }

    @Test func aClosingMenuIsOneChange() {
        let before: [(ref: String, node: UINode)] = [
            ("m1", UINode(ref: "m1", role: "AXMenu")),
            ("m2", UINode(ref: "m2", role: "AXMenuItem", label: "Rename", selected: false)),
            ("m3", UINode(ref: "m3", role: "AXMenuItem", label: "Delete", selected: false)),
        ]
        let highlighted: [(ref: String, node: UINode)] = [
            ("m1", UINode(ref: "m1", role: "AXMenu")),
            ("m2", UINode(ref: "m2", role: "AXMenuItem", label: "Rename", selected: true)),
            ("m3", UINode(ref: "m3", role: "AXMenuItem", label: "Delete", selected: false)),
        ]
        #expect(Settle.diff(before: before, after: highlighted).isEmpty)
        let changes = Settle.diff(before: before, after: [])
        #expect(changes.map(\.node.ref) == ["m1"])
    }
}

struct MCPProtocolTests {
    private func reply(_ server: MCPServer, _ line: String) throws -> JSONValue? {
        guard let data = server.handle(line) else { return nil }
        return try HarnessJSON.decoder.decode(JSONValue.self, from: data)
    }

    @Test func negotiatesVersionAndListsTools() throws {
        let server = MCPServer()
        let initialize = try #require(try reply(server, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}"#))
        #expect(initialize["result"]?["protocolVersion"]?.stringValue == "2025-03-26")
        let unknownVersion = try #require(try reply(server, #"{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#))
        #expect(unknownVersion["result"]?["protocolVersion"]?.stringValue == MCPServer.supportedVersions[0])

        let tools = try #require(try reply(server, #"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#))
        let names = tools["result"]?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
        #expect(names.contains("snapshot"))
        #expect(names.contains("act"))
        #expect(names.count == MCPTools.definitions.count)
    }

    @Test func notificationsGetNoReplyAndUnknownMethodsError() throws {
        let server = MCPServer()
        #expect(try reply(server, #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
        let unknown = try #require(try reply(server, #"{"jsonrpc":"2.0","id":9,"method":"resources/list"}"#))
        #expect(unknown["error"]?["code"]?.numberValue == -32601)
        let ping = try #require(try reply(server, #"{"jsonrpc":"2.0","id":10,"method":"ping"}"#))
        #expect(ping["result"] == .object([:]))
    }
}

struct HiddenTreeTests {
    @Test func recognizesChromiumEngines() {
        #expect(HiddenTrees.detect(frameworks: ["Electron Framework.framework", "Squirrel.framework"]) == .electron)
        #expect(HiddenTrees.detect(frameworks: ["Chromium Embedded Framework.framework"]) == .cef)
        #expect(HiddenTrees.detect(frameworks: ["Google Chrome Framework.framework"]) == .chromium)
        #expect(HiddenTrees.detect(frameworks: ["Microsoft Edge Framework.framework"]) == .chromium)
        #expect(HiddenTrees.detect(frameworks: ["Sparkle.framework"]) == nil)
        #expect(HiddenTrees.detect(frameworks: []) == nil)
    }
}
