import Foundation
import HarnessProtocol
import Testing
@testable import HarnessClient
@testable import HarnessCore

private let systemExtras = [
    MenuExtraInfo(details: "Wi‑Fi", identifier: "com.apple.menuextra.wifi"),
    MenuExtraInfo(details: "Battery", identifier: "com.apple.menuextra.battery"),
    MenuExtraInfo(title: "Fri 10 Oct 14:32", details: "Clock", identifier: "com.apple.menuextra.clock"),
]

private let harnessOnly = [MenuExtraInfo(details: "macOS Harness")]

private func failure(_ body: () throws -> Void) -> String? {
    do {
        try body()
        return nil
    } catch let error as RPCError {
        return error.message
    } catch {
        return String(describing: error)
    }
}

struct MenuExtraNamingTests {
    @Test func namesPreferTheDescriptionOverTitleHelpAndIdentifier() {
        #expect(systemExtras[2].name == "Clock")
        #expect(MenuExtraInfo(title: "12:34", help: "Timer").name == "12:34")
        #expect(MenuExtraInfo(help: "Sync status").name == "Sync status")
        #expect(MenuExtraInfo(identifier: "Item-0").name == "Item-0")
        #expect(MenuExtraInfo().name == "unnamed")
    }

    @Test func matchingIgnoresCaseAndTypographicPunctuation() {
        #expect(MenuService.normalize("Wi‑Fi") == MenuService.normalize("wi-fi"))
        #expect(MenuService.normalize("Don’t Save") == MenuService.normalize("Don't Save"))
        #expect(MenuService.normalize(" Export as PDF…") == "export as pdf...")
    }

    @Test func listsExtrasWithIdentifiersOnlyWhenNamesRepeat() {
        let twins = [MenuExtraInfo(details: "Sync", identifier: "a"), MenuExtraInfo(details: "Sync", identifier: "b"), MenuExtraInfo(details: "Other")]
        #expect(MenuExtras.listing(twins) == "Sync (id a), Sync (id b), Other")
        #expect(MenuExtras.listing(systemExtras) == "Wi‑Fi, Battery, Clock")
    }

    @Test func listedExtrasCarryTheirIdentifier() {
        let wifi = MenuExtras.item(systemExtras[0])
        #expect(wifi.title == "Wi‑Fi" && wifi.identifier == "com.apple.menuextra.wifi" && !wifi.hasSubmenu)
        #expect(MenuExtras.item(MenuExtraInfo(identifier: "Item-0")).identifier == nil)
    }
}

struct MenuExtraLocationTests {
    @Test func findsAnExtraByNameIdentifierOrPartOfAName() throws {
        #expect(try MenuExtras.locate(["wi-fi", "Turn Wi-Fi Off"], in: systemExtras, appName: "Control Center")
            == .init(index: 0, rest: ["Turn Wi-Fi Off"]))
        #expect(try MenuExtras.locate(["com.apple.menuextra.battery"], in: systemExtras, appName: "Control Center") == .init(index: 1, rest: []))
        #expect(try MenuExtras.locate(["Fri 10 Oct 14:32"], in: systemExtras, appName: "Control Center") == .init(index: 2, rest: []))
        #expect(try MenuExtras.locate(["batt"], in: systemExtras, appName: "Control Center") == .init(index: 1, rest: []))
    }

    @Test func mistakesSayWhatIsThere() {
        let missing = failure { _ = try MenuExtras.locate(["Bluetooth"], in: systemExtras, appName: "Control Center") }
        #expect(missing == "No menu bar extra “Bluetooth” in Control Center. Its extras: Wi‑Fi, Battery, Clock.")
        let ambiguous = failure { _ = try MenuExtras.locate(["com.apple"], in: systemExtras, appName: "Control Center") }
        #expect(ambiguous?.hasPrefix("“com.apple” matches 3 menu bar extras in Control Center: Wi‑Fi (id com.apple.menuextra.wifi)") == true)
        let unnamed = failure { _ = try MenuExtras.locate([], in: systemExtras, appName: "Control Center") }
        #expect(unnamed == "Control Center has 3 menu bar extras; say which: Wi‑Fi, Battery, Clock.")
        let none = failure { _ = try MenuExtras.locate(["Wi-Fi"], in: [], appName: "TextEdit") }
        #expect(none?.hasPrefix("TextEdit has no menu bar extras.") == true)
        #expect(none?.contains("Control Center") == true)
    }

    @Test func anAppsOnlyExtraNeedNotBeNamed() throws {
        #expect(try MenuExtras.locate([], in: harnessOnly, appName: "macOS Harness") == .init(index: 0, rest: []))
        #expect(try MenuExtras.locate(["macos harness"], in: harnessOnly, appName: "macOS Harness") == .init(index: 0, rest: []))
        #expect(try MenuExtras.locate(["Pause"], in: harnessOnly, appName: "macOS Harness") == .init(index: 0, rest: ["Pause"]))
        #expect(try MenuExtras.locate(["Harness", "Pause"], in: harnessOnly, appName: "macOS Harness") == .init(index: 0, rest: ["Harness", "Pause"]))
    }
}

struct MenuExtraRequestTests {
    @Test func olderRequestsAndItemsStillDecode() throws {
        let menu = try JSONValue.object(["app": .string("TextEdit"), "path": .array([]), "depth": .number(1)]).decode(as: MenuMethod.Params.self)
        #expect(menu.extras == nil)
        let select = try JSONValue.object([
            "app": .string("TextEdit"), "path": .array([.string("File")]), "activate": .bool(true), "diff": .bool(true),
        ]).decode(as: MenuSelectMethod.Params.self)
        #expect(select.extras == nil)
        let item = try JSONValue.object([
            "title": .string("Save"), "enabled": .bool(true), "isSeparator": .bool(false), "hasSubmenu": .bool(false), "children": .array([]),
        ]).decode(as: MenuMethod.Item.self)
        #expect(item.identifier == nil)
    }

    @Test func plainMenuRequestsLookAsBefore() throws {
        let encoded = try JSONValue(encoding: MenuSelectMethod.Params(app: "TextEdit", path: ["File", "Save…"]))
        #expect(encoded["extras"] == nil)
        let extras = try JSONValue(encoding: MenuSelectMethod.Params(app: "Control Center", path: ["Wi‑Fi"], extras: true))
        #expect(extras["extras"]?.boolValue == true)
    }

    @Test func mcpToolsTakeExtras() throws {
        let menu = try MCPTools.menuParams(MCPArguments(.object(["app": .string("Control Center"), "extras": .bool(true)])))
        #expect(menu.extras == true && menu.path.isEmpty && menu.depth == 1)
        #expect(try MCPTools.menuParams(MCPArguments(.object(["app": .string("TextEdit")]))).extras == nil)

        let only = try MCPTools.menuSelectParams(MCPArguments(.object(["app": .string("macOS Harness"), "extras": .bool(true)])))
        #expect(only.extras == true && only.path.isEmpty && only.activate)
        let item = try MCPTools.menuSelectParams(MCPArguments(.object([
            "app": .string("Dropbox"), "path": .array([.string("Dropbox"), .string("Preferences…")]), "extras": .bool(true),
        ])))
        #expect(item.path == ["Dropbox", "Preferences…"])
        #expect(throws: RPCError.self) { try MCPTools.menuSelectParams(MCPArguments(.object(["app": .string("TextEdit")]))) }
    }

    @Test func mcpSchemasOfferExtras() throws {
        func tool(_ name: String) -> JSONValue? { MCPTools.definitions.first { $0["name"]?.stringValue == name } }
        let menu = try #require(tool("menu"))
        let select = try #require(tool("menu_select"))
        #expect(menu["inputSchema"]?["properties"]?["extras"] != nil)
        #expect(select["inputSchema"]?["properties"]?["extras"] != nil)
        #expect(select["inputSchema"]?["required"] == .array([.string("app")]))
        #expect(MCPTools.instructions.contains("extras=true"))
    }
}

struct MenuExtraRenderTests {
    private let app = AppRef(name: "Control Center", bundleIdentifier: "com.apple.controlcenter", pid: 3)

    @Test func rendersTheExtrasWithIdentifiers() {
        let result = MenuMethod.Result(app: app, items: systemExtras.map(MenuExtras.item))
        #expect(Render.menu(result, path: [], extras: true) == """
            Control Center menu bar extras
              Wi‑Fi  id=com.apple.menuextra.wifi
              Battery  id=com.apple.menuextra.battery
              Clock  id=com.apple.menuextra.clock
            """)
    }

    @Test func namesTheExtraAMenuCameFrom() {
        let item = MenuMethod.Item(title: "Turn Wi‑Fi Off", enabled: true, shortcut: nil, mark: nil, isSeparator: false, hasSubmenu: false, children: [])
        let result = MenuMethod.Result(app: app, items: [item])
        #expect(Render.menu(result, path: ["Wi‑Fi"], extras: true) == "Control Center menu bar extra: Wi‑Fi\n  Turn Wi‑Fi Off")
        #expect(Render.menu(result, path: ["File"]) == "Control Center menu: File\n  Turn Wi‑Fi Off")
        #expect(Render.menu(result, path: []) == "Control Center menu bar\n  Turn Wi‑Fi Off")
    }
}

struct MenuExtraPolicyTests {
    private func menu(extras: Bool?, path: [String]) -> RPCRequest {
        var params: [String: JSONValue] = ["app": .string("Menu Thing"), "path": .array(path.map(JSONValue.string)), "depth": .number(1)]
        if let extras { params["extras"] = .bool(extras) }
        return RPCRequest(id: 1, method: MenuMethod.name, params: .object(params))
    }

    @Test func readingAnExtrasMenuCountsAsAnAction() {
        #expect(PolicyEnforcer.policyMethod(of: menu(extras: true, path: ["Wi-Fi"])) == MenuSelectMethod.name)
        #expect(PolicyEnforcer.policyMethod(of: menu(extras: true, path: [])) == MenuMethod.name)
        #expect(PolicyEnforcer.policyMethod(of: menu(extras: nil, path: ["File"])) == MenuMethod.name)
        #expect(PolicyEnforcer.actionMethods.contains(MenuSelectMethod.name))
    }

    @Test func readOnlyAppsListExtrasButDontOpenThem() async throws {
        let path = NSTemporaryDirectory() + "policy-\(UUID().uuidString).yaml"
        defer { try? FileManager.default.removeItem(atPath: path) }
        try "read_only:\n  - Menu Thing\n".write(toFile: path, atomically: true, encoding: .utf8)
        let store = PolicyStore(path: path)
        #expect(await PolicyEnforcer.refusal(for: menu(extras: true, path: []), store: store) == nil)
        let opening = await PolicyEnforcer.refusal(for: menu(extras: true, path: ["Sync"]), store: store)
        #expect(opening?.code == RPCErrorCode.blockedByPolicy)
        #expect(opening?.message.contains("listing its menu bar extras works") == true)
        let choosing = RPCRequest(id: 2, method: MenuSelectMethod.name, params: .object([
            "app": .string("Menu Thing"), "path": .array([]), "extras": .bool(true),
        ]))
        #expect(await PolicyEnforcer.refusal(for: choosing, store: store)?.code == RPCErrorCode.blockedByPolicy)
    }
}

struct MenuExtraRecordTests {
    private let caller = CallerIdentity(displayName: "Claude Code", key: "Claude Code|Q6L2SF6YDW|com.anthropic.claude-code", chain: [])

    @Test func journalMarksExtras() {
        let request = RPCRequest(id: 1, method: MenuSelectMethod.name, params: .object([
            "app": .string("Control Center"), "path": .array([.string("Wi‑Fi"), .string("Turn Wi‑Fi Off")]), "extras": .bool(true),
        ]))
        let entry = Journal.entry(for: request, response: RPCResponse(id: 1, result: .object([:])), caller: caller, session: "s", milliseconds: 1, at: Date())
        #expect(entry.action == "extras")
        #expect(entry.value == "Wi‑Fi › Turn Wi‑Fi Off")
        let bare = RPCRequest(id: 2, method: MenuSelectMethod.name, params: .object([
            "app": .string("macOS Harness"), "path": .array([]), "extras": .bool(true),
        ]))
        #expect(Journal.entry(for: bare, response: RPCResponse(id: 2, result: .object([:])), caller: caller, session: "s", milliseconds: 1, at: Date()).value == nil)
    }

    @Test func activitySaysExtras() throws {
        let request = RPCRequest(id: 1, method: MenuMethod.name, params: .object([
            "app": .string("Control Center"), "path": .array([]), "extras": .bool(true),
        ]))
        let entry = try #require(ActivityDescriber.entry(
            for: request, response: RPCResponse(id: 1, result: .object([:])), agentKey: "k", agentName: "Codex"
        ))
        #expect(entry.summary == "read Control Center menu bar extras")
    }
}
