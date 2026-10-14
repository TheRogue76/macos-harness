import Foundation
import HarnessProtocol
import Yams

/// Several steps sent in one call: run in order like a flow's steps, stopping at the first
/// failure, then one look at the app.
public enum Batch {
    /// What to report after the steps: every change the actions saw, a snapshot, or nothing.
    public enum Observe: String, CaseIterable, Sendable {
        case changes, snapshot, none
    }

    public static let maxSteps = 64

    /// The flow steps a batch may run: UI actions, waits and checks, but not shell commands,
    /// builds, launches, quits, screenshots to files or device management, which have their
    /// own tools.
    public static let allowedActions: Set<String> = [
        "press", "focus", "select", "scroll-to", "increment", "decrement", "set-value", "type", "key",
        "click", "double-click", "right-click", "hover", "scroll", "long-press", "swipe", "drag",
        "menu", "window", "wait", "expect", "sleep",
    ]

    /// The action a step names, the way flows read it: its one key besides `app`, `only_if`,
    /// `refused` and, when there's another, `window`.
    static func actionName(_ step: Any) -> String? {
        guard let map = step as? [String: Any] else { return nil }
        let named = map.keys.filter { !["app", "only_if", "refused"].contains($0) }
        let actions = named.count == 1 ? named : named.filter { $0 != "window" }
        return actions.count == 1 ? actions.first : nil
    }

    public struct Result: Sendable {
        public var flow: FlowResult
        public var changes: [UIChange]
        public var snapshot: SnapshotMethod.Result?
        public var snapshotError: String?
    }

    /// The steps, written the way a flow's `steps:` are, as a flow on `app` (and `window`, for
    /// steps that name neither).
    public static func flow(steps: [Any], app: String?, window: UInt32?) throws -> Flow {
        guard !steps.isEmpty else { throw FlowError("give at least one step") }
        guard steps.count <= maxSteps else { throw FlowError("at most \(maxSteps) steps in one call") }
        for (index, step) in steps.enumerated() {
            if let name = actionName(step), !allowedActions.contains(name) {
                throw FlowError("step \(index + 1): `\(name)` can't run in a batch; use its own command, or a flow")
            }
        }
        var parsed = try FlowParser.steps(steps, phase: "steps", flowApp: app)
        if let window {
            parsed = parsed.map { step in
                var step = step
                if step.app == nil, step.window == nil { step.window = window }
                return step
            }
        }
        return Flow(name: "\(parsed.count) step\(parsed.count == 1 ? "" : "s")", app: app, isPrivate: true, steps: parsed)
    }

    /// Steps written as a YAML or JSON list, as a flow on `app`.
    public static func flow(yaml text: String, app: String?, window: UInt32?) throws -> Flow {
        let loaded: Any?
        do {
            loaded = try Yams.load(yaml: text)
        } catch {
            throw FlowError("invalid YAML: \(error)")
        }
        guard let list = loaded as? [Any] else {
            throw FlowError("steps are a list, like `[{press: {id: OK}}, {type: hello}]`")
        }
        return try flow(steps: list, app: app, window: window)
    }

    /// Runs the steps without saving failure artifacts, then makes the observation.
    public static func run(_ flow: Flow, observe: Observe, window: UInt32?, maxNodes: Int, caller: HarnessCalling) -> Result {
        let runner = FlowRunner(caller: caller, artifactsRoot: NSTemporaryDirectory())
        runner.savesFailures = false
        let outcome = runner.run(flow)
        var result = Result(flow: outcome, changes: observe == .changes ? merged(runner.actionResults) : [], snapshot: nil)
        if observe == .snapshot, let app = flow.app {
            do {
                result.snapshot = try caller.call(
                    SnapshotMethod.self, .init(target: Target(app: app, window: window), maxNodes: maxNodes), timeout: 60
                )
            } catch {
                result.snapshotError = FlowRunner.message(error)
            }
        }
        return result
    }

    /// Each element's net change across the actions, in the order elements first changed: an
    /// element added and then removed drops out, and one added and then changed stays added.
    public static func merged(_ results: [ActionResult]) -> [UIChange] {
        var order: [String] = []
        var net: [String: UIChange] = [:]
        for change in results.flatMap(\.changes) {
            let key = change.node.ref ?? "\(change.node.role)|\(change.node.label ?? "")|\(change.node.identifier ?? "")"
            guard let earlier = net[key] else {
                order.append(key)
                net[key] = change
                continue
            }
            switch (earlier.kind, change.kind) {
            case ("added", "removed"): net[key] = nil
            case ("added", _): net[key] = UIChange(kind: "added", node: change.node)
            case ("changed", "changed"): net[key] = UIChange(kind: "changed", node: change.node, before: earlier.before)
            default: net[key] = change
            }
        }
        return order.compactMap { net[$0] }
    }

    /// The batch's outcome as text: each step, the failure, then the observation.
    public static func render(_ result: Result, observe: Observe) -> String {
        var lines = result.flow.steps.map(FlowRunner.line)
        let count = result.flow.steps.count
        if result.flow.passed {
            lines.append(count == 1 ? "The step passed." : "All \(count) steps passed.")
        } else {
            let failure = result.flow.failure ?? "a step failed"
            lines.append("Stopped at " + failure + (failure.hasSuffix(".") ? "" : "."))
        }
        switch observe {
        case .changes:
            lines.append(result.changes.isEmpty ? "No changes seen." : "Changes:")
            lines += result.changes.prefix(60).map { "  " + Render.change($0) }
            if result.changes.count > 60 { lines.append("  … \(result.changes.count - 60) more") }
        case .snapshot:
            if let snapshot = result.snapshot {
                lines.append(Render.snapshot(snapshot))
            } else if let error = result.snapshotError {
                lines.append("Couldn't take the snapshot: \(error)")
            }
        case .none:
            break
        }
        return lines.joined(separator: "\n")
    }

    /// A JSON value as the plain values YAML parsing gives, so JSON steps parse like YAML ones.
    public static func plain(_ value: JSONValue) -> Any {
        switch value {
        case .null: return NSNull()
        case .bool(let bool): return bool
        case .number(let number): return number.rounded() == number && abs(number) < 1e15 ? Int(number) : number
        case .string(let string): return string
        case .array(let values): return values.map(plain)
        case .object(let object): return object.mapValues(plain)
        }
    }
}
