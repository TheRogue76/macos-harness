import CoreGraphics
import Foundation
@testable import HarnessClient
import HarnessProtocol
import Testing
@testable import HarnessCore

struct ErrorCodeTests {
    @Test func codesAreStable() {
        #expect(RPCErrorCode.pairingDenied == 1001)
        #expect(RPCErrorCode.permissionMissing == 1002)
        #expect(RPCErrorCode.failed == 1003)
        #expect(RPCErrorCode.stoppedByUser == 1004)
        #expect(RPCErrorCode.blockedByPolicy == 1005)
        #expect(RPCErrorCode.windowClaimed == 1006)
        #expect(RPCErrorCode.inputBusy == 1007)
        #expect(RPCErrorCode.notFound == 1008)
        #expect(RPCErrorCode.ambiguous == 1009)
        #expect(RPCErrorCode.disabled == 1010)
        #expect(RPCErrorCode.timedOut == 1011)
    }

    private func hit(_ key: String, _ label: String) -> ElementSearch.Hit {
        let frame = CGRect(x: 10, y: 10, width: 80, height: 20)
        let node = RawNode(key: AnyHashable(key), role: "AXButton", title: label, actions: ["AXPress"], frame: frame)
        return ElementSearch.Hit(raw: node, path: [], visible: frame)
    }

    private func code(_ hits: [ElementSearch.Hit]) -> Int? {
        do {
            _ = try ElementSearch.single(hits, selector: ElementSelector(text: "Save"), describe: { $0.raw.title ?? "" })
            return nil
        } catch let error as RPCError {
            return error.code
        } catch {
            return nil
        }
    }

    @Test func searchesSayWhetherNothingOrTooMuchMatched() {
        #expect(code([]) == RPCErrorCode.notFound)
        #expect(code([hit("a", "Save draft"), hit("b", "Save all")]) == RPCErrorCode.ambiguous)
        #expect(code([hit("a", "Save draft")]) == nil)
    }
}

struct MCPParityTests {
    private func properties(_ tool: String) -> Set<String> {
        for definition in MCPTools.definitions {
            guard case .object(let object) = definition, object["name"] == .string(tool),
                  case .object(let schema)? = object["inputSchema"], case .object(let properties)? = schema["properties"]
            else { continue }
            return Set(properties.keys)
        }
        return []
    }

    @Test func toolsTakeWhatTheCommandsTake() {
        #expect(properties("snapshot").isSuperset(of: ["max_nodes", "max_depth", "since", "query", "links"]))
        #expect(properties("find").contains("links"))
        #expect(properties("read") == ["app", "window", "ref", "text", "role", "id", "exact"])
        #expect(properties("quit").contains("timeout"))
        #expect(properties("pointer").contains("diff"))
        #expect(properties("menu_select").contains("diff"))
        #expect(properties("build").contains("run"))
        #expect(properties("simulator").isSuperset(of: ["battery_state", "wifi", "cellular", "network", "carrier"]))
    }

    @Test func recordTakesOutLikeTheCommand() {
        #expect(properties("record").contains("out"))
        #expect(!properties("record").contains("path"))
    }

    @Test func diffCanBeTurnedOff() throws {
        let pointer = try MCPTools.pointerParams(MCPArguments(.object([
            "app": .string("Fixture"), "action": .string("click"), "id": .string("ok"), "diff": .bool(false),
        ])))
        #expect(pointer.diff == false)
        let menu = try MCPTools.menuSelectParams(MCPArguments(.object([
            "app": .string("TextEdit"), "path": .array([.string("Format"), .string("Font")]), "diff": .bool(false),
        ])))
        #expect(menu.diff == false)
        #expect(try MCPTools.menuSelectParams(MCPArguments(.object(["app": .string("TextEdit"), "path": .array([.string("File")])]))).diff)
    }
}

struct WaitRecognitionTests {
    @Test func recognitionNeedsText() {
        #expect(throws: RPCError.self) { try AppControl.checkRecognizable(ElementSelector(role: "button", ocr: true)) }
        #expect(throws: RPCError.self) { try AppControl.checkRecognizable(ElementSelector(text: "", ocr: true)) }
        #expect(throws: Never.self) { try AppControl.checkRecognizable(ElementSelector(text: "Done", ocr: true)) }
        #expect(throws: Never.self) { try AppControl.checkRecognizable(ElementSelector(role: "button")) }
    }
}
