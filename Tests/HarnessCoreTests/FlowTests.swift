import Foundation
import HarnessClient
import HarnessProtocol
import Testing

/// Answers helper calls from a closure, recording what was asked.
private final class FakeHelper: HarnessCalling, @unchecked Sendable {
    var calls: [(method: String, params: JSONValue)] = []
    let answer: (String, JSONValue, Int) throws -> JSONValue

    init(answer: @escaping (String, JSONValue, Int) throws -> JSONValue) {
        self.answer = answer
    }

    func call<M: RPCMethod>(_ method: M.Type, _ params: M.Params, timeout: TimeInterval?) throws -> M.Result {
        let encoded = try JSONValue(encoding: params)
        calls.append((M.name, encoded))
        let count = calls.filter { $0.method == M.name }.count
        return try answer(M.name, encoded, count).decode(as: M.Result.self)
    }
}

private let app = AppRef(name: "Calculator", bundleIdentifier: "com.apple.calculator", pid: 7)
private let window = WindowInfo(
    id: 1, app: app, title: "Calculator", frame: Rect(x: 0, y: 0, width: 200, height: 300), onScreen: true,
    minimized: false, focused: true, main: true, subrole: nil, hasSheet: false
)

private func actionResult() throws -> JSONValue {
    try JSONValue(encoding: ActionResult(app: app, window: window, element: nil, performed: "pressed", via: "AX"))
}

private func found(_ nodes: [UINode]) throws -> JSONValue {
    try JSONValue(encoding: FindMethod.Result(window: window, matches: nodes.map { .init(node: $0, path: []) }, notices: []))
}

private func display(_ value: String) -> UINode {
    UINode(ref: "b5", role: "AXStaticText", value: value, hit: Point(x: 10, y: 10))
}

struct FlowParserTests {
    @Test func parsesStepsAndSubstitutesVariables() throws {
        let flow = try FlowParser.parse("""
        name: Multiply
        app: Calculator
        vars:
          digit: "4"
        steps:
          - press: { id: AllClear }
          - type: "3${digit}"
          - click: { id: canvas, right: true }
          - scroll: { id: rows, down: 300 }
          - expect: { role: text, text: "408", exact: true, timeout: 2 }
        teardown:
          - quit: Calculator
        """, overrides: ["digit": "5"])
        #expect(flow.name == "Multiply")
        #expect(flow.steps.count == 5)
        #expect(flow.steps[0].action == .act(.press, ElementSelector(identifier: "AllClear"), value: nil, count: 1, real: false))
        #expect(flow.steps[1].action == .act(.type, nil, value: "35", count: 1, real: false))
        guard case .pointer(let click) = flow.steps[2].action, case .pointer(let scroll) = flow.steps[3].action else {
            Issue.record("expected pointer steps")
            return
        }
        #expect(click.action == .rightClick)
        #expect(flow.steps[2].summary == "right-click id=canvas")
        #expect(scroll.dy == -300)
        #expect(flow.steps[4].action == .expect(ElementSelector(text: "408", role: "text", exact: true), Expectation(), timeout: 2))
        #expect(flow.teardown == [FlowStep(action: .quit(app: "Calculator", force: false, ifLaunched: false), summary: "quit Calculator")])
    }

    @Test func mistakesSayWhere() {
        func message(_ yaml: String) -> String? {
            do {
                _ = try FlowParser.parse(yaml)
                return nil
            } catch {
                return (error as? FlowError)?.description
            }
        }
        #expect(message("app: X\nsteps:\n  - press: { idd: OK }\n")?.contains("step 1 in steps: unknown key `idd`") == true)
        #expect(message("app: X\nsteps:\n  - pres: OK\n")?.contains("unknown action `pres`") == true)
        #expect(message("steps:\n  - press: OK\n")?.contains("say which app") == true)
        #expect(message("app: X\nsteps:\n  - type: \"${secret}\"\n")?.contains("unknown variable `${secret}`") == true)
        #expect(message("app: X\nvars:\n  text_1: null\nsteps:\n  - type: \"${text_1}\"\n")?.contains("pass --var text_1=") == true)
        #expect(message("app: X\nstep:\n  - press: OK\n")?.contains("unknown key `step`") == true)
        #expect(message("app: X\nsteps: []\n")?.contains("no `steps`") == true)
    }

    @Test func variablesCanUseOtherVariables() throws {
        let flow = try FlowParser.parse("app: X\nvars:\n  folder: \"${home}/sandbox\"\n  file: \"${folder}/a.txt\"\nsteps:\n  - type: \"${file}\"\n")
        guard case .act(_, _, let value?, _, _) = flow.steps[0].action else {
            Issue.record("expected a type step")
            return
        }
        #expect(value == HarnessPaths.homeDirectory + "/sandbox/a.txt")
        #expect(throws: FlowError.self) { try FlowParser.parse("app: X\nvars:\n  a: \"${b}\"\n  b: \"${a}\"\nsteps:\n  - type: \"${a}\"\n") }
    }

    @Test func flowDirIsAbsolute() throws {
        let flow = try FlowParser.parse("app: X\nsteps:\n  - type: \"${flow_dir}\"\n", path: "flows/tier-c/page.yaml")
        guard case .act(_, _, let value?, _, _) = flow.steps[0].action else {
            Issue.record("expected a type step")
            return
        }
        #expect(value.hasPrefix("/") && value.hasSuffix("/flows/tier-c"))
    }

    @Test func parsesMenuBarExtraSteps() throws {
        let flow = try FlowParser.parse("""
        app: Calculator
        steps:
          - menu: [File, Close]
          - menu: { app: Control Center, path: [Wi-Fi, Turn Wi-Fi Off], extras: true }
          - menu: { app: macOS Harness, extras: true }
        """)
        #expect(flow.steps.map(\.action) == [
            .menu(["File", "Close"], extras: false), .menu(["Wi-Fi", "Turn Wi-Fi Off"], extras: true), .menu([], extras: true),
        ])
        #expect(flow.steps.map(\.summary) == ["menu File › Close", "menu bar extra › Wi-Fi › Turn Wi-Fi Off", "menu bar extra"])
        #expect(flow.steps[1].app == "Control Center")
        #expect(throws: FlowError.self) { try FlowParser.parse("app: X\nsteps:\n  - menu: { path: [] }\n") }
    }

    @Test func readsTheRunScopedPolicy() throws {
        let flow = try FlowParser.parse("""
        app: Mail
        private: true
        policy:
          read_only: [Mail, Messages]
        steps:
          - expect: { role: outline }
        """)
        #expect(flow.isPrivate)
        #expect(flow.restrictions == PolicyRestrictions(readOnly: ["Mail", "Messages"]))
    }

    @Test func dragsCanEndInAnotherWindowOrApp() throws {
        let flow = try FlowParser.parse("""
        app: Finder
        steps:
          - drag: { from: { text: a.txt }, to: { app: TextEdit, role: textarea } }
          - drag: { from: { x: 10, y: 20 }, to: { window: 812, x: 40, y: 60 } }
          - drag: { from: { id: drag-source }, to: { id: drop-target } }
        """)
        let pointers = flow.steps.compactMap { step -> PointerStep? in
            if case .pointer(let pointer) = step.action { return pointer }
            return nil
        }
        #expect(pointers.count == 3)
        #expect(pointers[0].toApp == "TextEdit" && pointers[0].toWindow == nil)
        #expect(pointers[0].to == ElementSelector(role: "textarea"))
        #expect(pointers[1].toApp == nil && pointers[1].toWindow == 812)
        #expect(pointers[1].toPoint == Point(x: 40, y: 60))
        #expect(pointers[2].toApp == nil && pointers[2].toWindow == nil)
        #expect(flow.steps.map(\.summary) == [
            "drag “a.txt” to textarea in TextEdit", "drag (10, 20) to (40, 60) in window 812", "drag id=drag-source to id=drop-target",
        ])
    }

    @Test func dragEndsRejectUnknownKeys() {
        #expect(throws: FlowError.self) { try FlowParser.parse("app: X\nsteps:\n  - drag: { from: { id: a }, to: { ap: TextEdit, id: b } }\n") }
        #expect(throws: FlowError.self) { try FlowParser.parse("app: X\nsteps:\n  - drag: { from: { id: a, app: Y }, to: { id: b } }\n") }
        #expect(throws: FlowError.self) { try FlowParser.parse("app: X\nsteps:\n  - drag: { from: { id: a }, to: { app: TextEdit } }\n") }
    }
}

struct FlowRunnerTests {
    @Test func expectWaitsForTheValue() throws {
        let helper = FakeHelper { method, _, count in
            method == FindMethod.name ? try found([display(count < 3 ? "\u{200E}40" : "\u{200E}408")]) : try actionResult()
        }
        let flow = try FlowParser.parse("app: Calculator\nsteps:\n  - press: { id: Equals }\n  - expect: { role: text, value: \"408\" }\n")
        let result = FlowRunner(caller: helper, artifactsRoot: NSTemporaryDirectory(), sleep: { _ in }).run(flow)
        #expect(result.passed)
        #expect(helper.calls.filter { $0.method == FindMethod.name }.count == 3)
    }

    @Test func setupFailureSkipsStepsButNotTeardown() throws {
        let helper = FakeHelper { method, _, _ in
            if method == LaunchMethod.name { throw RPCError(code: RPCErrorCode.failed, message: "no such app") }
            if method == QuitMethod.name {
                return try JSONValue(encoding: QuitMethod.Result(app: app, quit: true, message: "quit"))
            }
            return try actionResult()
        }
        let flow = try FlowParser.parse("app: Nope\nsetup:\n  - launch: Nope\nsteps:\n  - press: OK\nteardown:\n  - quit: Nope\n")
        let result = FlowRunner(caller: helper, artifactsRoot: NSTemporaryDirectory(), sleep: { _ in }).run(flow)
        #expect(!result.passed)
        #expect(result.steps.map(\.status) == [.failed, .skipped, .passed])
        #expect(result.failure == "setup 1 (launch Nope): no such app")
        #expect(helper.calls.map(\.method) == [LaunchMethod.name, ScreenshotMethod.name, SnapshotMethod.name, QuitMethod.name])
    }

    @Test func dragsNameTheWindowTheyEndIn() throws {
        let helper = FakeHelper { method, _, _ in
            if method == LaunchMethod.name {
                return try JSONValue(encoding: LaunchMethod.Result(
                    app: AppRef(name: "TextEdit", bundleIdentifier: nil, pid: 4242), windows: [], alreadyRunning: false, milliseconds: 1
                ))
            }
            return try actionResult()
        }
        let flow = try FlowParser.parse("""
        app: Finder
        steps:
          - launch: { app: TextEdit, as: editor }
          - drag: { from: { text: a.txt }, to: { app: editor, x: 40, y: 60 } }
          - drag: { from: { text: a.txt }, to: { window: 812, x: 40, y: 60 } }
          - drag: { from: { text: a.txt }, to: { x: 40, y: 60 } }
        """)
        let result = FlowRunner(caller: helper, artifactsRoot: NSTemporaryDirectory(), sleep: { _ in }).run(flow)
        #expect(result.passed)
        let drags = try helper.calls.filter { $0.method == PointerMethod.name }.map { try $0.params.decode(as: PointerMethod.Params.self) }
        #expect(drags.map(\.toTarget) == [Target(app: "4242"), Target(app: "Finder", window: 812), nil])
        #expect(drags.allSatisfy { $0.target == Target(app: "Finder") })
    }

    @Test func runScopedPolicyIsAppliedFirst() throws {
        let helper = FakeHelper { method, params, _ in
            if method == RestrictMethod.name {
                return try JSONValue(encoding: RestrictMethod.Result(restrictions: try params.decode(as: PolicyRestrictions.self)))
            }
            return try found([display("1")])
        }
        let flow = try FlowParser.parse("app: Mail\npolicy:\n  read_only: [Mail]\nsteps:\n  - expect: { role: text }\n")
        _ = FlowRunner(caller: helper, artifactsRoot: NSTemporaryDirectory(), sleep: { _ in }).run(flow)
        #expect(helper.calls.first?.method == RestrictMethod.name)
    }

    @Test func menuStepsAskForExtrasOnlyWhenTheyUseThem() throws {
        let helper = FakeHelper { _, _, _ in try actionResult() }
        let flow = try FlowParser.parse("app: Calculator\nsteps:\n  - menu: [View, Scientific]\n  - menu: { app: Control Center, path: [Wi-Fi], extras: true }\n")
        let result = FlowRunner(caller: helper, artifactsRoot: NSTemporaryDirectory(), sleep: { _ in }).run(flow)
        #expect(result.passed)
        let menus = helper.calls.filter { $0.method == MenuSelectMethod.name }.map(\.params)
        #expect(menus.count == 2)
        #expect(menus.first?["extras"] == nil)
        #expect(menus.last?["extras"]?.boolValue == true)
        #expect(menus.last?["app"]?.stringValue == "Control Center")
    }

    @Test func checksDescribeWhatsWrong() {
        let toggle = UINode(ref: "k1", role: "AXCheckBox", value: "0", enabled: false, hit: nil)
        #expect(FlowRunner.check([], Expectation()) == "nothing matches")
        #expect(FlowRunner.check([], Expectation(gone: true)) == nil)
        #expect(FlowRunner.check([toggle], Expectation(checked: true))?.contains("unchecked") == true)
        #expect(FlowRunner.check([toggle], Expectation(enabled: false, checked: false, visible: false)) == nil)
        #expect(FlowRunner.check([toggle, toggle], Expectation(count: 1)) == "found 2 matching, expected 1")
        #expect(FlowRunner.check([display("\u{200E}12\u{200E} ")], Expectation(value: "12")) == nil)
    }

    @Test func junitEscapesAndCountsFailures() {
        let results = [
            FlowResult(name: "a <b>", path: "flows/a.yaml", passed: true, milliseconds: 1500, steps: []),
            FlowResult(name: "c", path: nil, passed: false, milliseconds: 500, steps: [], failure: "expected “1” & got \"2\""),
        ]
        let xml = JUnitReport.xml(results)
        #expect(xml.contains(#"tests="2" failures="1" time="2.0""#))
        #expect(xml.contains("a &lt;b&gt;"))
        #expect(xml.contains("&amp; got &quot;2&quot;"))
    }
}

struct FlowExportTests {
    private func entry(
        _ method: String, app: String? = "Notes", action: String? = nil, params: JSONValue? = nil,
        element: JournalEntry.Element? = nil, redacted: Int? = nil, value: String? = nil, error: RPCError? = nil
    ) -> JournalEntry {
        JournalEntry(
            time: Date(), session: "s", agent: "Claude Code", agentKey: "k", method: method, app: app, action: action,
            element: element, value: value, redactedLength: redacted, error: error, milliseconds: 1
        ).with(params: params)
    }

    @Test func exportedFlowsParseAndReplayTheActions() throws {
        let entries = [
            entry(LaunchMethod.name, params: .object(["app": .string("Notes"), "activate": .bool(true)])),
            entry(SnapshotMethod.name),
            entry(ActMethod.name, action: "press", element: .init(ref: "k3", role: "AXButton", label: "New Note", identifier: nil)),
            entry(ActMethod.name, action: "type", params: .object(["action": .string("type"), "real": .bool(true)]), redacted: 12),
            entry(ActMethod.name, action: "key", value: "cmd+s"),
            entry(ActMethod.name, action: "press", element: .init(ref: "k9", role: "AXButton", label: nil, identifier: nil)),
            entry(ActMethod.name, action: "press", element: .init(ref: "k4", role: "AXButton", label: "Gone", identifier: "gone"),
                  error: RPCError(code: 1003, message: "no")),
            entry(PointerMethod.name, app: "Finder", action: "drag", params: .object([
                "action": .string("drag"), "element": .object(["text": .string("a.txt"), "exact": .bool(false)]),
                "to": .object(["identifier": .string("done"), "exact": .bool(false)]),
            ])),
            entry(MenuSelectMethod.name, params: .object(["app": .string("Notes"), "path": .array([.string("File"), .string("Close")])])),
        ]
        let yaml = FlowExporter.yaml(name: "Agent session", entries: entries)
        #expect(yaml.contains("text_1: null  # 12 characters were typed"))
        #expect(yaml.contains("1 action couldn't be turned into steps"))
        let flow = try FlowParser.parse(yaml, overrides: ["text_1": "Hello there!"])
        #expect(flow.app == "Notes")
        #expect(flow.steps.map(\.summary) == [
            "launch Notes", "press button “New Note” (exact)", "type 12 characters", "key cmd+s",
            "drag “a.txt” to id=done", "menu File › Close",
        ])
        #expect(flow.steps[4].app == "Finder")
        #expect(flow.steps[2].action == .act(.type, nil, value: "Hello there!", count: 1, real: true))
    }

    @Test func dragsIntoAnotherWindowKeepTheirDestination() throws {
        let yaml = FlowExporter.yaml(name: "Drop", entries: [
            entry(PointerMethod.name, app: "Finder", action: "drag", params: .object([
                "action": .string("drag"), "element": .object(["text": .string("a.txt"), "exact": .bool(false)]),
                "toPoint": .object(["x": .number(40), "y": .number(60)]),
                "toTarget": .object(["app": .string("TextEdit"), "window": .number(455)]),
            ])),
        ])
        #expect(yaml.contains(#"to: { app: "TextEdit", window: 455, x: 40, y: 60 }"#))
        let flow = try FlowParser.parse(yaml)
        guard case .pointer(let drag) = flow.steps.first?.action else {
            Issue.record("expected a drag step")
            return
        }
        #expect(drag.toApp == "TextEdit")
        #expect(drag.toWindow == 455)
        #expect(drag.toPoint == Point(x: 40, y: 60))
    }

    @Test func menuBarExtrasExportAsExtrasSteps() throws {
        let yaml = FlowExporter.yaml(name: "Extras", entries: [
            entry(MenuSelectMethod.name, app: "Control Center", action: "extras", params: .object([
                "app": .string("Control Center"), "path": .array([.string("Wi-Fi"), .string("Turn Wi-Fi Off")]), "extras": .bool(true),
            ])),
            entry(MenuSelectMethod.name, app: "Control Center", action: "extras", params: .object([
                "app": .string("Control Center"), "path": .array([]), "extras": .bool(true),
            ])),
        ])
        #expect(yaml.contains(#"menu: { path: ["Wi-Fi", "Turn Wi-Fi Off"], extras: true }"#))
        #expect(yaml.contains("menu: { extras: true }"))
        let flow = try FlowParser.parse(yaml)
        #expect(flow.app == "Control Center")
        #expect(flow.steps.map(\.action) == [.menu(["Wi-Fi", "Turn Wi-Fi Off"], extras: true), .menu([], extras: true)])
    }

    @Test func unfilledTextMustBeProvided() {
        let yaml = FlowExporter.yaml(name: "x", entries: [
            entry(ActMethod.name, action: "type", params: .object(["action": .string("type")]), redacted: 3),
        ])
        #expect(throws: FlowError.self) { try FlowParser.parse(yaml) }
    }
}

private extension JournalEntry {
    func with(params: JSONValue?) -> JournalEntry {
        var copy = self
        copy.params = params
        return copy
    }
}
