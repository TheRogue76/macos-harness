import Foundation
import HarnessProtocol
import Yams

/// A scripted UI check: setup, steps and teardown, run against the helper the way an agent would.
public struct Flow: Equatable, Sendable {
    public var name: String
    /// The app steps act on unless they name another.
    public var app: String?
    /// Restrictions added to the user's policy while the flow runs.
    public var restrictions: PolicyRestrictions
    /// Failure artifacts go to the user's Library instead of next to the flow, since they may show
    /// personal data.
    public var isPrivate: Bool
    public var setup: [FlowStep]
    public var steps: [FlowStep]
    public var teardown: [FlowStep]
    public var path: String?

    public init(
        name: String, app: String? = nil, restrictions: PolicyRestrictions = .init(), isPrivate: Bool = false,
        setup: [FlowStep] = [], steps: [FlowStep] = [], teardown: [FlowStep] = [], path: String? = nil
    ) {
        self.name = name
        self.app = app
        self.restrictions = restrictions
        self.isPrivate = isPrivate
        self.setup = setup
        self.steps = steps
        self.teardown = teardown
        self.path = path
    }
}

public struct FlowStep: Equatable, Sendable {
    public var action: Action
    public var app: String?
    public var window: UInt32?
    /// Run the step only when this element exists; otherwise it's skipped.
    public var onlyIf: ElementSelector?
    /// The step passes only if the policy refuses it, which proves the policy is in force.
    public var mustBeRefused = false
    /// The step as written, for reports, e.g. `press id=AllClear`.
    public var summary: String

    public init(action: Action, app: String? = nil, window: UInt32? = nil, onlyIf: ElementSelector? = nil, summary: String) {
        self.action = action
        self.app = app
        self.window = window
        self.onlyIf = onlyIf
        self.summary = summary
    }

    public enum Action: Equatable, Sendable {
        /// `alias` names the launched copy so later steps can say `app: <alias>`.
        case launch(app: String, open: [String], activate: Bool, arguments: [String], newInstance: Bool, alias: String?)
        /// `ifLaunched` quits only an app this flow launched, leaving one the user had open.
        case quit(app: String, force: Bool, ifLaunched: Bool)
        case act(ElementAction, ElementSelector?, value: String?, count: Int, real: Bool)
        case menu([String])
        case window(WindowActionMethod.Action, x: Double?, y: Double?, width: Double?, height: Double?)
        case pointer(PointerStep)
        case wait(ElementSelector, gone: Bool, timeout: Double)
        case expect(ElementSelector, Expectation, timeout: Double)
        case screenshot(String)
        case shell(String)
        case sleep(Double)
        /// A `simulator` call; a missing device means the flow's `sim:` target, or the booted one.
        case simulator(SimulatorMethod.Params)
        /// Builds an app for the simulator, then installs and launches it if asked.
        case build(AppBuilder.Request, install: Bool, launch: Bool)
        /// An `android` call; a missing device means the flow's `android:` target, or the running one.
        case android(AndroidMethod.Params)
    }

    /// Whether the step needs an app to act on.
    public var needsApp: Bool {
        switch action {
        case .launch, .quit, .shell, .sleep, .simulator, .build, .android: false
        default: true
        }
    }
}

public struct PointerStep: Equatable, Sendable {
    public var action: PointerAction
    public var selector: ElementSelector?
    public var point: Point?
    public var to: ElementSelector?
    public var toPoint: Point?
    /// The app a drag ends in, when it's another app; nil means the step's app.
    public var toApp: String?
    /// The window a drag ends in, when it's another window.
    public var toWindow: UInt32?
    public var modifiers: [String]
    public var dx: Double
    public var dy: Double
    public var hold: Double?
    public var duration: Double?

    public init(
        action: PointerAction, selector: ElementSelector? = nil, point: Point? = nil, to: ElementSelector? = nil,
        toPoint: Point? = nil, toApp: String? = nil, toWindow: UInt32? = nil, modifiers: [String] = [], dx: Double = 0,
        dy: Double = 0, hold: Double? = nil, duration: Double? = nil
    ) {
        self.action = action
        self.selector = selector
        self.point = point
        self.to = to
        self.toPoint = toPoint
        self.toApp = toApp
        self.toWindow = toWindow
        self.modifiers = modifiers
        self.dx = dx
        self.dy = dy
        self.hold = hold
        self.duration = duration
    }
}

/// What an `expect` step checks about the elements its selector matches.
public struct Expectation: Equatable, Sendable {
    public var value: String?
    public var enabled: Bool?
    public var focused: Bool?
    public var selected: Bool?
    public var checked: Bool?
    /// On screen and not scrolled or clipped out of view.
    public var visible: Bool?
    public var count: Int?
    public var gone: Bool

    public init(
        value: String? = nil, enabled: Bool? = nil, focused: Bool? = nil, selected: Bool? = nil,
        checked: Bool? = nil, visible: Bool? = nil, count: Int? = nil, gone: Bool = false
    ) {
        self.visible = visible
        self.value = value
        self.enabled = enabled
        self.focused = focused
        self.selected = selected
        self.checked = checked
        self.count = count
        self.gone = gone
    }
}

public struct FlowError: Error, CustomStringConvertible, Equatable {
    public var description: String

    public init(_ description: String) {
        self.description = description
    }
}

/// Reads flow files.
public enum FlowParser {
    static let topLevelKeys: Set<String> = ["name", "app", "vars", "policy", "private", "setup", "steps", "teardown"]
    static let selectorKeys: Set<String> = ["text", "role", "id", "exact", "ocr"]
    static let targetKeys: Set<String> = ["app", "window", "only_if", "refused"]

    /// Parses a flow file, filling `${name}` variables from the file's `vars`, then `overrides`.
    public static func parse(file path: String, overrides: [String: String] = [:]) throws -> Flow {
        let text: String
        do {
            text = try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            throw FlowError("\(path): can't read it (\(error.localizedDescription))")
        }
        do {
            return try parse(text, path: path, overrides: overrides)
        } catch let error as FlowError {
            throw FlowError("\(path): \(error.description)")
        }
    }

    public static func parse(_ text: String, path: String? = nil, overrides: [String: String] = [:]) throws -> Flow {
        let loaded: Any?
        do {
            loaded = try Yams.load(yaml: text)
        } catch {
            throw FlowError("invalid YAML: \(error)")
        }
        guard let document = loaded as? [String: Any] else {
            throw FlowError("a flow is a mapping with `steps:` and optionally `name`, `app`, `vars`, `policy`, `private`, `setup` and `teardown`")
        }
        if let unknown = document.keys.sorted().first(where: { !topLevelKeys.contains($0) }) {
            throw FlowError("unknown key `\(unknown)`")
        }
        let variables = try variables(document["vars"], overrides: overrides, path: path)
        let resolved = try substitute(document, variables: variables, location: "flow") as? [String: Any] ?? [:]

        let fileName = path.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension }
        let name = try string(resolved["name"], "name", optional: true) ?? fileName ?? "Untitled flow"
        var flow = Flow(
            name: name,
            app: try string(resolved["app"], "app", optional: true),
            isPrivate: try bool(resolved["private"], "private") ?? false,
            path: path
        )
        if let policy = resolved["policy"] {
            guard let map = policy as? [String: Any] else { throw FlowError("`policy` takes `blocked` and `read_only` lists") }
            if let unknown = map.keys.sorted().first(where: { !["blocked", "read_only"].contains($0) }) {
                throw FlowError("unknown key `\(unknown)` in policy; use `blocked` and `read_only`")
            }
            flow.restrictions = PolicyRestrictions(
                blocked: try strings(map["blocked"], "policy.blocked"),
                readOnly: try strings(map["read_only"], "policy.read_only")
            )
        }
        flow.setup = try steps(resolved["setup"], phase: "setup", flowApp: flow.app)
        flow.steps = try steps(resolved["steps"], phase: "steps", flowApp: flow.app)
        flow.teardown = try steps(resolved["teardown"], phase: "teardown", flowApp: flow.app)
        guard !flow.steps.isEmpty else { throw FlowError("the flow has no `steps`") }
        return flow
    }

    static func variables(_ raw: Any?, overrides: [String: String], path: String?) throws -> [String: String?] {
        var variables: [String: String?] = [
            "home": HarnessPaths.homeDirectory,
            "flow_dir": path.map { URL(fileURLWithPath: $0).standardizedFileURL.deletingLastPathComponent().path }
                ?? FileManager.default.currentDirectoryPath,
        ]
        if let raw {
            guard let map = raw as? [String: Any] else { throw FlowError("`vars` is a mapping of names to values") }
            for (name, value) in map {
                variables[name] = value is NSNull ? String?.none : scalarText(value)
            }
        }
        for (name, value) in overrides { variables[name] = value }
        return try expandReferences(in: variables)
    }

    /// Variables whose values use other variables (`folder: "${home}/x"`), expanded; a cycle is an error.
    static func expandReferences(in variables: [String: String?]) throws -> [String: String?] {
        var expanded = variables
        for _ in 0...variables.count {
            var changed = false
            for (name, value) in expanded {
                guard let value, value.contains("${") else { continue }
                let next = try substitute(value, variables: expanded)
                if next != value {
                    expanded[name] = next
                    changed = true
                }
            }
            if !changed { break }
        }
        if let name = expanded.first(where: { $0.value?.contains("${") == true })?.key {
            throw FlowError("variable `\(name)` refers to itself through other variables")
        }
        return expanded
    }

    static func substitute(_ value: Any, variables: [String: String?], location: String) throws -> Any {
        switch value {
        case let text as String:
            return try substitute(text, variables: variables)
        case let list as [Any]:
            return try list.map { try substitute($0, variables: variables, location: location) }
        case let map as [String: Any]:
            var result: [String: Any] = [:]
            for (key, item) in map where key != "vars" {
                result[key] = try substitute(item, variables: variables, location: location)
            }
            return result
        default:
            return value
        }
    }

    static func substitute(_ text: String, variables: [String: String?]) throws -> String {
        var result = ""
        var rest = Substring(text)
        while let start = rest.range(of: "${") {
            result += rest[..<start.lowerBound]
            guard let end = rest[start.upperBound...].firstIndex(of: "}") else {
                throw FlowError("unclosed `${` in “\(text)”")
            }
            let name = String(rest[start.upperBound..<end])
            guard let entry = variables[name] else {
                throw FlowError("unknown variable `${\(name)}`; define it under `vars` or pass --var \(name)=…")
            }
            guard let value = entry else {
                throw FlowError("variable `\(name)` has no value; pass --var \(name)=…")
            }
            result += value
            rest = rest[rest.index(after: end)...]
        }
        return result + rest
    }

    static func steps(_ raw: Any?, phase: String, flowApp: String?) throws -> [FlowStep] {
        guard let raw else { return [] }
        guard let list = raw as? [Any] else { throw FlowError("`\(phase)` is a list of steps") }
        return try list.enumerated().map { index, item in
            do {
                let step = try self.step(item)
                if step.needsApp, step.app == nil, flowApp == nil {
                    throw FlowError("say which app: add `app:` to the flow or the step")
                }
                return step
            } catch let error as FlowError {
                throw FlowError("step \(index + 1) in \(phase): \(error.description)")
            }
        }
    }

    static func step(_ raw: Any) throws -> FlowStep {
        guard let map = raw as? [String: Any] else {
            throw FlowError("a step is a mapping like `- press: { id: OK }`")
        }
        let named = map.keys.filter { $0 != "app" && $0 != "only_if" && $0 != "refused" }
        let actions = named.count == 1 ? named : named.filter { $0 != "window" }
        guard actions.count == 1, let name = actions.first else {
            throw FlowError("a step has exactly one action (\(actions.sorted().joined(separator: ", ")))")
        }
        let value = map[name] as Any
        var step = try action(name, value)
        if let app = try string(map["app"], "app", optional: true) { step.app = app }
        if name != "window", let window = try number(map["window"], "window") { step.window = UInt32(window) }
        if let condition = map["only_if"] {
            guard let selector = try selectorIfAny(try mapping(condition, "only_if", allowed: selectorKeys)) else {
                throw FlowError("`only_if` needs an element: `text`, `role` or `id`")
            }
            step.onlyIf = selector
            step.summary += " (only if \(describe(selector)))"
        }
        if try bool(map["refused"], "refused") == true {
            step.mustBeRefused = true
            step.summary += " (must be refused)"
        }
        return step
    }

    static func action(_ name: String, _ value: Any) throws -> FlowStep {
        switch name {
        case "launch":
            if let app = value as? String {
                return FlowStep(action: .launch(app: app, open: [], activate: false, arguments: [], newInstance: false, alias: nil), summary: "launch \(app)")
            }
            let map = try mapping(value, name, allowed: ["app", "open", "activate", "arguments", "new_instance", "as"])
            let app = try required(string(map["app"], "app", optional: true), "launch needs an app")
            let alias = try string(map["as"], "as", optional: true)
            return FlowStep(
                action: .launch(
                    app: app, open: try strings(map["open"], "open"), activate: try bool(map["activate"], "activate") ?? false,
                    arguments: try strings(map["arguments"], "arguments"), newInstance: try bool(map["new_instance"], "new_instance") ?? false,
                    alias: alias
                ),
                summary: "launch \(app)\(alias.map { " as \($0)" } ?? "")"
            )
        case "quit":
            if let app = value as? String { return FlowStep(action: .quit(app: app, force: false, ifLaunched: false), summary: "quit \(app)") }
            let map = try mapping(value, name, allowed: ["app", "force", "if_launched"])
            let app = try required(string(map["app"], "app", optional: true), "quit needs an app")
            let ifLaunched = try bool(map["if_launched"], "if_launched") ?? false
            return FlowStep(
                action: .quit(app: app, force: try bool(map["force"], "force") ?? false, ifLaunched: ifLaunched),
                summary: "quit \(app)\(ifLaunched ? " if this flow launched it" : "")"
            )
        case "press", "focus", "select", "scroll-to", "increment", "decrement":
            let extra: Set<String> = name == "increment" || name == "decrement" ? ["count"] : []
            let (selector, map) = try selected(value, name, extra: extra)
            let action = ElementAction(rawValue: name)!
            var step = FlowStep(
                action: .act(action, selector, value: nil, count: try number(map["count"], "count").map { Int($0) } ?? 1, real: false),
                summary: "\(name) \(describe(selector))"
            )
            try target(map, into: &step)
            return step
        case "set-value":
            let (selector, map) = try selected(value, name, extra: ["value"])
            let text = try required(string(map["value"], "value", optional: true), "set-value needs a `value`")
            var step = FlowStep(action: .act(.setValue, selector, value: text, count: 1, real: false), summary: "set-value \(describe(selector))")
            try target(map, into: &step)
            return step
        case "type":
            if let text = value as? String {
                return FlowStep(action: .act(.type, nil, value: text, count: 1, real: false), summary: "type \(text.count) characters")
            }
            let map = try mapping(value, name, allowed: selectorKeys.union(targetKeys).union(["text", "real"]))
            let text = try required(string(map["text"], "text", optional: true), "type needs `text`")
            var selectorMap = map
            selectorMap.removeValue(forKey: "text")
            let selector = try selectorIfAny(selectorMap)
            var step = FlowStep(
                action: .act(.type, selector, value: text, count: 1, real: try bool(map["real"], "real") ?? false),
                summary: "type \(text.count) characters\(selector.map { " into \(describe($0))" } ?? "")"
            )
            try target(map, into: &step)
            return step
        case "key":
            if let combo = value as? String { return FlowStep(action: .act(.key, nil, value: combo, count: 1, real: false), summary: "key \(combo)") }
            let map = try mapping(value, name, allowed: targetKeys.union(["combo", "real"]))
            let combo = try required(string(map["combo"], "combo", optional: true), "key needs a `combo`")
            var step = FlowStep(action: .act(.key, nil, value: combo, count: 1, real: try bool(map["real"], "real") ?? false), summary: "key \(combo)")
            try target(map, into: &step)
            return step
        case "menu":
            if let path = value as? [Any] {
                let titles = try strings(path, "menu")
                return FlowStep(action: .menu(titles), summary: "menu \(titles.joined(separator: " › "))")
            }
            let map = try mapping(value, name, allowed: ["path", "app"])
            let titles = try strings(map["path"], "path")
            guard !titles.isEmpty else { throw FlowError("menu needs a `path` such as [File, Save…]") }
            var step = FlowStep(action: .menu(titles), summary: "menu \(titles.joined(separator: " › "))")
            try target(map, into: &step)
            return step
        case "window":
            if let action = value as? String {
                return FlowStep(action: .window(try windowAction(action), x: nil, y: nil, width: nil, height: nil), summary: "window \(action)")
            }
            let map = try mapping(value, name, allowed: targetKeys.union(["action", "x", "y", "width", "height"]))
            let action = try required(string(map["action"], "action", optional: true), "window needs an `action`")
            var step = FlowStep(
                action: .window(
                    try windowAction(action), x: try number(map["x"], "x"), y: try number(map["y"], "y"),
                    width: try number(map["width"], "width"), height: try number(map["height"], "height")
                ),
                summary: "window \(action)"
            )
            try target(map, into: &step)
            return step
        case "click", "double-click", "right-click", "hover", "scroll", "long-press", "swipe":
            return try pointer(name, value)
        case "sim":
            return try simulator(value)
        case "android":
            return try android(value)
        case "build":
            let map = try mapping(value, name, allowed: ["project", "workspace", "scheme", "configuration", "device", "install", "launch"])
            let request = AppBuilder.Request(
                project: try string(map["project"], "project", optional: true), workspace: try string(map["workspace"], "workspace", optional: true),
                scheme: try string(map["scheme"], "scheme", optional: true),
                configuration: try string(map["configuration"], "configuration", optional: true) ?? "Debug",
                device: try string(map["device"], "device", optional: true)
            )
            let launch = try bool(map["launch"], "launch") ?? false
            let install = try bool(map["install"], "install") ?? launch
            let what = request.scheme ?? request.workspace ?? request.project ?? "the project here"
            return FlowStep(
                action: .build(request, install: install, launch: launch),
                summary: "build \(what)\(launch ? " and launch it" : install ? " and install it" : "")"
            )
        case "drag":
            let map = try mapping(value, name, allowed: targetKeys.union(["from", "to", "hold", "modifiers"]))
            if let source = map["from"] as? [String: Any] {
                _ = try mapping(source, "from", allowed: selectorKeys.union(["x", "y"]))
            }
            let (from, fromPoint) = try place(map["from"], "from")
            var toMap: [String: Any] = [:]
            if let destination = map["to"] as? [String: Any] {
                toMap = try mapping(destination, "to", allowed: selectorKeys.union(["x", "y", "app", "window"]))
            }
            let (to, toPoint) = try place(map["to"], "to")
            let toApp = try string(toMap["app"], "app", optional: true)
            let toWindow = try number(toMap["window"], "window").map { UInt32($0) }
            let elsewhere = [toApp, toWindow.map { "window \($0)" }].compactMap { $0 }.joined(separator: " ")
            var step = FlowStep(
                action: .pointer(PointerStep(
                    action: .drag, selector: from, point: fromPoint, to: to, toPoint: toPoint, toApp: toApp, toWindow: toWindow,
                    modifiers: try strings(map["modifiers"], "modifiers"), hold: try number(map["hold"], "hold")
                )),
                summary: "drag \(describePlace(from, fromPoint)) to \(describePlace(to, toPoint))\(elsewhere.isEmpty ? "" : " in \(elsewhere)")"
            )
            try target(map, into: &step)
            return step
        case "wait":
            let (selector, map) = try selected(value, name, extra: ["gone", "timeout"])
            var step = FlowStep(
                action: .wait(selector, gone: try bool(map["gone"], "gone") ?? false, timeout: try number(map["timeout"], "timeout") ?? 10),
                summary: "wait for \(describe(selector))\(try bool(map["gone"], "gone") == true ? " to go away" : "")"
            )
            try target(map, into: &step)
            return step
        case "expect":
            let (selector, map) = try selected(value, name, extra: ["value", "enabled", "focused", "selected", "checked", "visible", "count", "gone", "timeout"])
            let expectation = Expectation(
                value: try string(map["value"], "value", optional: true),
                enabled: try bool(map["enabled"], "enabled"), focused: try bool(map["focused"], "focused"),
                selected: try bool(map["selected"], "selected"), checked: try bool(map["checked"], "checked"),
                visible: try bool(map["visible"], "visible"), count: try number(map["count"], "count").map { Int($0) }, gone: try bool(map["gone"], "gone") ?? false
            )
            var step = FlowStep(
                action: .expect(selector, expectation, timeout: try number(map["timeout"], "timeout") ?? 5),
                summary: "expect \(describe(selector))\(describe(expectation))"
            )
            try target(map, into: &step)
            return step
        case "screenshot":
            if let name = value as? String { return FlowStep(action: .screenshot(name), summary: "screenshot \(name)") }
            let map = try mapping(value, name, allowed: targetKeys.union(["name"]))
            let shot = try required(string(map["name"], "name", optional: true), "screenshot needs a `name`")
            var step = FlowStep(action: .screenshot(shot), summary: "screenshot \(shot)")
            try target(map, into: &step)
            return step
        case "shell":
            guard let command = value as? String else { throw FlowError("shell takes a command string") }
            return FlowStep(action: .shell(command), summary: "shell \(command)")
        case "sleep":
            guard let seconds = try number(value, "sleep") else { throw FlowError("sleep takes seconds") }
            return FlowStep(action: .sleep(seconds), summary: "sleep \(seconds)")
        default:
            throw FlowError("unknown action `\(name)`")
        }
    }

    static func pointer(_ name: String, _ value: Any) throws -> FlowStep {
        let extra: Set<String> = switch name {
        case "click": ["right", "count", "modifiers"]
        case "hover": ["dwell"]
        case "scroll": ["down", "up", "left", "right"]
        case "long-press": ["hold"]
        case "swipe": ["down", "up", "left", "right", "duration"]
        default: ["modifiers"]
        }
        let map: [String: Any] = value is String ? ["text": value] : try mapping(value, name, allowed: selectorKeys.union(targetKeys).union(extra).union(["x", "y"]))
        let (selector, point) = try place(map, name)
        var action: PointerAction = switch name {
        case "double-click": .doubleClick
        case "right-click": .rightClick
        case "hover": .hover
        case "scroll": .scroll
        case "long-press": .longPress
        case "swipe": .swipe
        default: .click
        }
        if name == "click", try bool(map["right"], "right") == true { action = .rightClick }
        if name == "click", try number(map["count"], "count") == 2 { action = .doubleClick }
        var pointer = PointerStep(action: action, selector: selector, point: point, modifiers: try strings(map["modifiers"], "modifiers"))
        if name == "hover" { pointer.hold = try number(map["dwell"], "dwell") ?? 1.2 }
        if name == "long-press" { pointer.hold = try number(map["hold"], "hold") ?? 1.0 }
        if name == "swipe" {
            pointer.dx = (try number(map["right"], "right") ?? 0) - (try number(map["left"], "left") ?? 0)
            pointer.dy = (try number(map["down"], "down") ?? 0) - (try number(map["up"], "up") ?? 0)
            pointer.duration = try number(map["duration"], "duration")
            guard pointer.dx != 0 || pointer.dy != 0 else { throw FlowError("swipe needs `down`, `up`, `left` or `right` points") }
        }
        if name == "scroll" {
            pointer.dy = -(try number(map["down"], "down") ?? 0) + (try number(map["up"], "up") ?? 0)
            pointer.dx = -(try number(map["right"], "right") ?? 0) + (try number(map["left"], "left") ?? 0)
            guard pointer.dx != 0 || pointer.dy != 0 else { throw FlowError("scroll needs `down`, `up`, `left` or `right` pixels") }
        }
        let verb = switch action {
        case .rightClick: "right-click"
        case .doubleClick: "double-click"
        default: name
        }
        var step = FlowStep(action: .pointer(pointer), summary: "\(verb) \(describePlace(selector, point))")
        try target(map, into: &step)
        return step
    }

    static let simulatorKeys: Set<String> = [
        "action", "device", "bundle_id", "path", "url", "args", "env", "button", "operation", "service", "payload",
        "latitude", "longitude", "appearance", "time", "battery", "text",
    ]

    /// A `sim:` step: the same fields as the MCP simulator tool.
    static func simulator(_ value: Any) throws -> FlowStep {
        let map = try mapping(value, "sim", allowed: simulatorKeys)
        let name = try required(string(map["action"], "action", optional: true), "sim needs an `action`")
        guard let action = SimulatorAction(rawValue: name) else {
            throw FlowError("unknown sim action `\(name)` (expected \(SimulatorAction.allCases.map(\.rawValue).joined(separator: ", ")))")
        }
        var environment: [String: String] = [:]
        if let env = map["env"] {
            guard let pairs = env as? [String: Any] else { throw FlowError("`env` takes a mapping") }
            for (key, value) in pairs { environment[key] = try string(value, key, optional: false) }
        }
        let buttonName = try string(map["button"], "button", optional: true)
        let button = try buttonName.map { name in
            guard let button = SimulatorButton(rawValue: name) else {
                throw FlowError("unknown button `\(name)` (expected \(SimulatorButton.allCases.map(\.rawValue).joined(separator: ", ")))")
            }
            return button
        }
        let overrides = StatusBarOverrides(time: try string(map["time"], "time", optional: true), batteryLevel: try number(map["battery"], "battery").map { Int($0) })
        let params = SimulatorMethod.Params(
            action: action, device: try string(map["device"], "device", optional: true),
            bundleIdentifier: try string(map["bundle_id"], "bundle_id", optional: true), path: try string(map["path"], "path", optional: true),
            url: try string(map["url"], "url", optional: true), arguments: try strings(map["args"], "args"), environment: environment,
            button: button, operation: try string(map["operation"], "operation", optional: true),
            service: try string(map["service"], "service", optional: true), payload: try string(map["payload"], "payload", optional: true),
            latitude: try number(map["latitude"], "latitude"), longitude: try number(map["longitude"], "longitude"),
            appearance: try string(map["appearance"], "appearance", optional: true), statusBar: overrides.isEmpty ? nil : overrides,
            text: try string(map["text"], "text", optional: true)
        )
        let detail = [params.bundleIdentifier, buttonName, params.url, params.appearance, params.operation].compactMap { $0 }.first
        return FlowStep(action: .simulator(params), summary: "sim \(name)\(detail.map { " \($0)" } ?? "")")
    }

    static let androidKeys: Set<String> = [
        "action", "device", "package", "path", "url", "button", "operation", "permission", "latitude", "longitude",
        "appearance", "orientation", "time", "battery", "headless",
    ]

    /// An `android:` step: the same fields as the MCP android tool.
    static func android(_ value: Any) throws -> FlowStep {
        let map = try mapping(value, "android", allowed: androidKeys)
        let name = try required(string(map["action"], "action", optional: true), "android needs an `action`")
        guard let action = AndroidAction(rawValue: name) else {
            throw FlowError("unknown android action `\(name)` (expected \(AndroidAction.allCases.map(\.rawValue).joined(separator: ", ")))")
        }
        let buttonName = try string(map["button"], "button", optional: true)
        let button = try buttonName.map { name in
            guard let button = AndroidButton(rawValue: name) else {
                throw FlowError("unknown button `\(name)` (expected \(AndroidButton.allCases.map(\.rawValue).joined(separator: ", ")))")
            }
            return button
        }
        let overrides = StatusBarOverrides(time: try string(map["time"], "time", optional: true), batteryLevel: try number(map["battery"], "battery").map { Int($0) })
        let params = AndroidMethod.Params(
            action: action, device: try string(map["device"], "device", optional: true),
            package: try string(map["package"], "package", optional: true), path: try string(map["path"], "path", optional: true),
            url: try string(map["url"], "url", optional: true), button: button,
            operation: try string(map["operation"], "operation", optional: true),
            permission: try string(map["permission"], "permission", optional: true),
            latitude: try number(map["latitude"], "latitude"), longitude: try number(map["longitude"], "longitude"),
            appearance: try string(map["appearance"], "appearance", optional: true),
            orientation: try string(map["orientation"], "orientation", optional: true),
            statusBar: overrides.isEmpty ? nil : overrides, headless: try bool(map["headless"], "headless")
        )
        let detail = [params.package, buttonName, params.url, params.appearance, params.orientation, params.operation].compactMap { $0 }.first
        return FlowStep(action: .android(params), summary: "android \(name)\(detail.map { " \($0)" } ?? "")")
    }

    static func mapping(_ value: Any, _ action: String, allowed: Set<String>) throws -> [String: Any] {
        guard let map = value as? [String: Any] else { throw FlowError("\(action) takes a mapping") }
        if let unknown = map.keys.sorted().first(where: { !allowed.contains($0) }) {
            throw FlowError("unknown key `\(unknown)` for \(action) (expected \(allowed.sorted().joined(separator: ", ")))")
        }
        return map
    }

    /// A selector from a string (its text) or a mapping, plus the mapping for the action's other keys.
    static func selected(_ value: Any, _ action: String, extra: Set<String>) throws -> (ElementSelector, [String: Any]) {
        if let text = value as? String { return (ElementSelector(text: text), [:]) }
        let map = try mapping(value, action, allowed: selectorKeys.union(targetKeys).union(extra))
        guard let selector = try selectorIfAny(map) else {
            throw FlowError("\(action) needs an element: `text`, `role` or `id`")
        }
        return (selector, map)
    }

    static func selectorIfAny(_ map: [String: Any]) throws -> ElementSelector? {
        let selector = ElementSelector(
            text: try string(map["text"], "text", optional: true), role: try string(map["role"], "role", optional: true),
            identifier: try string(map["id"], "id", optional: true), exact: try bool(map["exact"], "exact") ?? false,
            ocr: try bool(map["ocr"], "ocr") == true ? true : nil
        )
        return selector.isEmpty ? nil : selector
    }

    /// An element or a window-relative `x`, `y` point.
    static func place(_ value: Any?, _ name: String) throws -> (ElementSelector?, Point?) {
        if let text = value as? String { return (ElementSelector(text: text), nil) }
        guard let map = value as? [String: Any] else { throw FlowError("`\(name)` needs an element or `x` and `y`") }
        if let x = try number(map["x"], "x") {
            guard let y = try number(map["y"], "y") else { throw FlowError("`\(name)` has `x` but no `y`") }
            return (nil, Point(x: x, y: y))
        }
        guard let selector = try selectorIfAny(map) else { throw FlowError("`\(name)` needs an element or `x` and `y`") }
        return (selector, nil)
    }

    static func target(_ map: [String: Any], into step: inout FlowStep) throws {
        if let app = try string(map["app"], "app", optional: true) { step.app = app }
        if let window = try number(map["window"], "window") { step.window = UInt32(window) }
    }

    static func windowAction(_ name: String) throws -> WindowActionMethod.Action {
        guard let action = WindowActionMethod.Action(rawValue: name) else {
            throw FlowError("unknown window action `\(name)` (\(WindowActionMethod.Action.allCases.map(\.rawValue).joined(separator: ", ")))")
        }
        return action
    }

    static func scalarText(_ value: Any) -> String {
        switch value {
        case let text as String: text
        case let flag as Bool: flag ? "true" : "false"
        case let number as Int: String(number)
        case let number as Double: number == number.rounded() ? String(Int(number)) : String(number)
        default: String(describing: value)
        }
    }

    static func string(_ value: Any?, _ key: String, optional: Bool) throws -> String? {
        guard let value, !(value is NSNull) else { return nil }
        if value is [Any] || value is [String: Any] { throw FlowError("`\(key)` should be text") }
        return scalarText(value)
    }

    static func strings(_ value: Any?, _ key: String) throws -> [String] {
        guard let value, !(value is NSNull) else { return [] }
        guard let list = value as? [Any] else { throw FlowError("`\(key)` should be a list") }
        return try list.map { item in
            guard let text = try string(item, key, optional: true) else { throw FlowError("`\(key)` has an empty item") }
            return text
        }
    }

    static func bool(_ value: Any?, _ key: String) throws -> Bool? {
        guard let value, !(value is NSNull) else { return nil }
        guard let flag = value as? Bool else { throw FlowError("`\(key)` should be true or false") }
        return flag
    }

    static func number(_ value: Any?, _ key: String) throws -> Double? {
        guard let value, !(value is NSNull) else { return nil }
        if let number = value as? Int { return Double(number) }
        if let number = value as? Double { return number }
        if let text = value as? String, let number = Double(text) { return number }
        throw FlowError("`\(key)` should be a number")
    }

    static func required<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw FlowError(message) }
        return value
    }

    static func describe(_ selector: ElementSelector) -> String {
        (selector.ocr == true ? "ocr " : "") + [
            selector.role, selector.identifier.map { "id=\($0)" },
            selector.text.map { selector.exact ? "“\($0)” (exact)" : "“\($0)”" },
        ].compactMap { $0 }.joined(separator: " ")
    }

    static func describePlace(_ selector: ElementSelector?, _ point: Point?) -> String {
        if let selector { return describe(selector) }
        if let point { return "(\(Int(point.x)), \(Int(point.y)))" }
        return "?"
    }

    static func describe(_ expectation: Expectation) -> String {
        var parts: [String] = []
        if expectation.gone { parts.append("gone") }
        if let value = expectation.value { parts.append("value “\(value)”") }
        if let enabled = expectation.enabled { parts.append(enabled ? "enabled" : "disabled") }
        if let focused = expectation.focused { parts.append(focused ? "focused" : "not focused") }
        if let selected = expectation.selected { parts.append(selected ? "selected" : "not selected") }
        if let checked = expectation.checked { parts.append(checked ? "checked" : "unchecked") }
        if let visible = expectation.visible { parts.append(visible ? "visible" : "not visible") }
        if let count = expectation.count { parts.append("× \(count)") }
        return parts.isEmpty ? "" : " " + parts.joined(separator: ", ")
    }
}
