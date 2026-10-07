import Foundation
import HarnessProtocol

/// Makes helper calls: the connection in practice, a fake in tests.
public protocol HarnessCalling: AnyObject {
    func call<M: RPCMethod>(_ method: M.Type, _ params: M.Params, timeout: TimeInterval?) throws -> M.Result
}

extension HarnessConnection: HarnessCalling {}

/// How one flow run went.
public struct FlowResult: Codable, Sendable {
    public struct Step: Codable, Sendable, Equatable {
        public enum Status: String, Codable, Sendable {
            case passed, failed, skipped
        }

        public var phase: String
        public var index: Int
        public var summary: String
        public var status: Status
        public var message: String?
        public var milliseconds: Int

        public init(phase: String, index: Int, summary: String, status: Status, message: String? = nil, milliseconds: Int) {
            self.phase = phase
            self.index = index
            self.summary = summary
            self.status = status
            self.message = message
            self.milliseconds = milliseconds
        }
    }

    public var name: String
    public var path: String?
    public var passed: Bool
    public var milliseconds: Int
    public var steps: [Step]
    /// The first failure, e.g. `steps 5 (expect id=count-value value “2”): found “1”`.
    public var failure: String?
    /// Where screenshots and failure details were saved.
    public var artifacts: String?

    public init(
        name: String, path: String?, passed: Bool, milliseconds: Int, steps: [Step], failure: String? = nil, artifacts: String? = nil
    ) {
        self.name = name
        self.path = path
        self.passed = passed
        self.milliseconds = milliseconds
        self.steps = steps
        self.failure = failure
        self.artifacts = artifacts
    }
}

/// Runs flows against the helper.
public final class FlowRunner {
    /// When to keep a movie of the flow's app.
    public enum Recording: String, Sendable, CaseIterable {
        case off, failures, always
    }

    let caller: HarnessCalling
    let artifactsRoot: String
    let recording: Recording
    let progress: (String) -> Void
    let sleep: (Double) -> Void
    var artifactsDirectory: String?
    /// Apps this run launched (they weren't running before), lowercased as the flow named them.
    var launched: Set<String> = []

    /// `artifactsRoot` is where each run's folder goes; private flows always use the user's Library.
    public init(
        caller: HarnessCalling, artifactsRoot: String, recording: Recording = .off, progress: @escaping (String) -> Void = { _ in },
        sleep: @escaping (Double) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) {
        self.caller = caller
        self.artifactsRoot = artifactsRoot
        self.recording = recording
        self.progress = progress
        self.sleep = sleep
    }

    public static var privateArtifactsRoot: String {
        "\(HarnessPaths.homeDirectory)/Library/Logs/macos-harness/flow-results"
    }

    /// Runs setup, then the steps (unless setup failed), then teardown, which always runs.
    public func run(_ flow: Flow) -> FlowResult {
        let started = Date()
        artifactsDirectory = nil
        launched = []
        var result = FlowResult(name: flow.name, path: flow.path, passed: true, milliseconds: 0, steps: [])
        if !flow.restrictions.isEmpty {
            do {
                _ = try caller.call(RestrictMethod.self, flow.restrictions, timeout: 10)
            } catch {
                result.passed = false
                result.failure = "couldn't apply the flow's policy: \(Self.message(error))"
                result.milliseconds = Int(Date().timeIntervalSince(started) * 1000)
                return result
            }
        }
        var failed = false
        var movie: String?
        for (phase, steps) in [("setup", flow.setup), ("steps", flow.steps)] {
            if phase == "steps", !failed { movie = startRecording(flow) }
            for (index, step) in steps.enumerated() {
                guard !failed else {
                    let skipped = FlowResult.Step(phase: phase, index: index + 1, summary: step.summary, status: .skipped, milliseconds: 0)
                    result.steps.append(skipped)
                    progress(Self.line(skipped))
                    continue
                }
                let outcome = perform(step, flow: flow, phase: phase, index: index + 1)
                result.steps.append(outcome)
                if outcome.status == .failed {
                    failed = true
                    result.failure = "\(phase) \(index + 1) (\(step.summary)): \(outcome.message ?? "failed")"
                    saveFailure(step, flow: flow)
                }
            }
        }
        if let movie { finishRecording(movie, flow: flow, keep: failed || recording == .always) }
        for (index, step) in flow.teardown.enumerated() {
            let outcome = perform(step, flow: flow, phase: "teardown", index: index + 1)
            result.steps.append(outcome)
            if outcome.status == .failed, result.failure == nil {
                result.failure = "teardown \(index + 1) (\(step.summary)): \(outcome.message ?? "failed")"
            }
        }
        result.passed = result.failure == nil
        result.milliseconds = Int(Date().timeIntervalSince(started) * 1000)
        result.artifacts = artifactsDirectory
        if let directory = artifactsDirectory {
            let log = result.steps.map(Self.line).joined(separator: "\n") + "\n"
            try? log.write(toFile: "\(directory)/steps.txt", atomically: true, encoding: .utf8)
        }
        return result
    }

    func perform(_ step: FlowStep, flow: Flow, phase: String, index: Int) -> FlowResult.Step {
        let started = Date()
        var outcome = FlowResult.Step(phase: phase, index: index, summary: step.summary, status: .passed, milliseconds: 0)
        do {
            if let reason = try skipReason(step, flow: flow) {
                outcome.status = .skipped
                outcome.message = reason
            } else if step.mustBeRefused {
                try expectRefusal(step, flow: flow)
            } else {
                try execute(step, flow: flow)
            }
        } catch {
            outcome.status = .failed
            outcome.message = Self.message(error)
        }
        outcome.milliseconds = Int(Date().timeIntervalSince(started) * 1000)
        progress(Self.line(outcome))
        return outcome
    }

    /// Why a step won't run: its `only_if` element is missing, or it quits an app the user had open.
    func skipReason(_ step: FlowStep, flow: Flow) throws -> String? {
        if case let .quit(app, _, ifLaunched) = step.action, ifLaunched, !launched.contains(app.lowercased()) {
            return "\(app) was already running before this flow"
        }
        guard let condition = step.onlyIf else { return nil }
        let target = Target(app: step.app ?? flow.app ?? "", window: step.window)
        let found = try? caller.call(
            FindMethod.self,
            .init(target: target, text: condition.text, role: condition.role, identifier: condition.identifier, exact: condition.exact, limit: 1),
            timeout: 30
        )
        return (found?.matches.isEmpty ?? true) ? "\(FlowParser.describe(condition)) isn't there" : nil
    }

    /// Runs a step that the policy must refuse; anything else fails the flow.
    func expectRefusal(_ step: FlowStep, flow: Flow) throws {
        do {
            try execute(step, flow: flow)
        } catch let error as RPCError where error.code == RPCErrorCode.blockedByPolicy {
            return
        }
        throw FlowError("the policy didn't refuse it")
    }

    func execute(_ step: FlowStep, flow: Flow) throws {
        let target = Target(app: step.app ?? flow.app ?? "", window: step.window)
        switch step.action {
        case let .launch(app, open, activate):
            let directory = flow.path.map { ($0 as NSString).deletingLastPathComponent } ?? FileManager.default.currentDirectoryPath
            let files = open.map { ($0 as NSString).isAbsolutePath ? $0 : (directory as NSString).appendingPathComponent($0) }
            let result = try caller.call(LaunchMethod.self, .init(app: app, open: files, activate: activate), timeout: 60)
            if !result.alreadyRunning { launched.insert(app.lowercased()) }
        case let .quit(app, force, _):
            let result = try caller.call(QuitMethod.self, .init(app: app, force: force), timeout: 30)
            guard result.quit else { throw FlowError(result.message) }
        case let .act(action, selector, value, count, real):
            _ = try caller.call(
                ActMethod.self,
                .init(target: target, element: selector, action: action, value: value, count: count, diff: true, real: real),
                timeout: 60
            )
        case let .menu(path):
            _ = try caller.call(MenuSelectMethod.self, .init(app: target.app, path: path), timeout: 60)
        case let .window(action, x, y, width, height):
            _ = try caller.call(
                WindowActionMethod.self, .init(target: target, action: action, x: x, y: y, width: width, height: height), timeout: 30
            )
        case let .pointer(pointer):
            _ = try caller.call(
                PointerMethod.self,
                .init(
                    target: target, action: pointer.action, element: pointer.selector, point: pointer.point, to: pointer.to,
                    toPoint: pointer.toPoint, modifiers: pointer.modifiers, dx: pointer.dx, dy: pointer.dy,
                    hold: pointer.hold ?? 0.3
                ),
                timeout: 60
            )
        case let .wait(selector, gone, timeout):
            let result = try caller.call(WaitMethod.self, .init(target: target, element: selector, gone: gone, timeout: timeout), timeout: timeout + 30)
            guard result.satisfied else {
                throw FlowError("\(FlowParser.describe(selector)) \(gone ? "didn't go away" : "didn't appear") within \(Self.seconds(timeout))")
            }
        case let .expect(selector, expectation, timeout):
            try expect(selector, expectation, target: target, timeout: timeout)
        case let .screenshot(name):
            let shot = try caller.call(ScreenshotMethod.self, .init(target: target), timeout: 30)
            try save(Data(base64Encoded: shot.pngBase64) ?? Data(), as: "\(Self.fileName(name)).png", flow: flow)
        case let .shell(command):
            try shell(command, flow: flow)
        case let .sleep(seconds):
            sleep(seconds)
        }
    }

    func expect(_ selector: ElementSelector, _ expectation: Expectation, target: Target, timeout: Double) throws {
        let deadline = Date().addingTimeInterval(timeout)
        var problem = "nothing checked"
        repeat {
            let found = try caller.call(
                FindMethod.self,
                .init(target: target, text: selector.text, role: selector.role, identifier: selector.identifier, exact: selector.exact, limit: 20),
                timeout: 30
            )
            guard let reason = Self.check(found.matches.map(\.node), expectation) else { return }
            problem = reason
            guard Date() < deadline else { break }
            sleep(0.25)
        } while Date() < deadline
        throw FlowError("\(problem) (waited \(Self.seconds(timeout)))")
    }

    /// Why `nodes` (the elements a selector matched) don't meet `expectation`, or nil when they do.
    public static func check(_ nodes: [UINode], _ expectation: Expectation) -> String? {
        if expectation.gone {
            return nodes.isEmpty ? nil : "still there: \(Render.node(nodes[0]))"
        }
        guard !nodes.isEmpty else { return "nothing matches" }
        if let count = expectation.count, nodes.count != count {
            return "found \(nodes.count) matching, expected \(count)"
        }
        let failures = nodes.map { mismatch($0, expectation) }
        if failures.contains(where: { $0 == nil }) { return nil }
        return failures.compactMap { $0 }.first
    }

    static func mismatch(_ node: UINode, _ expectation: Expectation) -> String? {
        if let value = expectation.value, normalized(node.value ?? node.label ?? "") != normalized(value) {
            return "found “\(normalized(node.value ?? node.label ?? ""))”, expected “\(value)” (\(Render.node(node)))"
        }
        if let enabled = expectation.enabled, (node.enabled ?? true) != enabled {
            return "\(Render.node(node)) is \(enabled ? "disabled" : "enabled")"
        }
        if let focused = expectation.focused, (node.focused ?? false) != focused {
            return "\(Render.node(node)) is \(focused ? "not focused" : "focused")"
        }
        if let selected = expectation.selected, (node.selected ?? false) != selected {
            return "\(Render.node(node)) is \(selected ? "not selected" : "selected")"
        }
        if let checked = expectation.checked, ["1", "on", "true"].contains((node.value ?? "").lowercased()) != checked {
            return "\(Render.node(node)) is \(checked ? "unchecked" : "checked")"
        }
        if let visible = expectation.visible, (node.hit != nil) != visible {
            return "\(Render.node(node)) is \(visible ? "scrolled or clipped out of view" : "visible")"
        }
        return nil
    }

    /// Text without invisible formatting characters (Calculator wraps its display in them) or outer spaces.
    static func normalized(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { $0.properties.generalCategory != .format }))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func shell(_ command: String, flow: Flow) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]
        if let path = flow.path {
            process.currentDirectoryURL = URL(fileURLWithPath: (path as NSString).deletingLastPathComponent)
        }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw FlowError("exited with \(process.terminationStatus)\(text.isEmpty ? "" : ": \(text.suffix(400))")")
        }
    }

    /// Starts recording the flow's app into a temporary movie, or returns nil when that isn't wanted or possible.
    func startRecording(_ flow: Flow) -> String? {
        guard recording != .off, let app = flow.app else { return nil }
        let path = NSTemporaryDirectory() + "macos-harness-flow-\(UUID().uuidString).mov"
        do {
            _ = try caller.call(RecordStartMethod.self, .init(target: Target(app: app), path: path, maxSeconds: 900), timeout: 30)
            return path
        } catch {
            progress("! not recording: \(Self.message(error))")
            return nil
        }
    }

    /// Stops the recording and moves the movie into the artifacts folder, or deletes it.
    func finishRecording(_ path: String, flow: Flow, keep: Bool) {
        _ = try? caller.call(RecordStopMethod.self, .init(), timeout: 30)
        defer { try? FileManager.default.removeItem(atPath: path) }
        guard keep, let directory = try? artifacts(for: flow) else { return }
        try? FileManager.default.moveItem(atPath: path, toPath: "\(directory)/recording.mov")
    }

    /// Saves a screenshot and the window's UI tree after the first failure, when the step names an app.
    func saveFailure(_ step: FlowStep, flow: Flow) {
        guard let app = step.app ?? flow.app else { return }
        let target = Target(app: app, window: step.window)
        if let shot = try? caller.call(ScreenshotMethod.self, .init(target: target), timeout: 30),
           let data = Data(base64Encoded: shot.pngBase64) {
            try? save(data, as: "failure.png", flow: flow)
        }
        if let snapshot = try? caller.call(SnapshotMethod.self, .init(target: target, maxNodes: 600), timeout: 30) {
            try? save(Data(Render.snapshot(snapshot).utf8), as: "failure-tree.txt", flow: flow)
        }
    }

    func save(_ data: Data, as name: String, flow: Flow) throws {
        let directory = try artifacts(for: flow)
        try data.write(to: URL(fileURLWithPath: "\(directory)/\(name)"))
    }

    func artifacts(for flow: Flow) throws -> String {
        if let artifactsDirectory { return artifactsDirectory }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let root = flow.isPrivate ? Self.privateArtifactsRoot : artifactsRoot
        let directory = "\(root)/\(Self.fileName(flow.name))-\(formatter.string(from: Date()))"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        artifactsDirectory = directory
        return directory
    }

    static func fileName(_ text: String) -> String {
        let words = text.lowercased().split { !$0.isLetter && !$0.isNumber }
        return words.isEmpty ? "flow" : words.joined(separator: "-")
    }

    static func message(_ error: Error) -> String {
        switch error {
        case let error as RPCError: error.message
        case let error as FlowError: error.description
        case let error as HarnessClientError: error.description
        default: String(describing: error)
        }
    }

    static func seconds(_ value: Double) -> String {
        value == value.rounded() ? "\(Int(value)) s" : String(format: "%.1f s", value)
    }

    /// `✓ steps 3  press id=One  (412 ms)`
    public static func line(_ step: FlowResult.Step) -> String {
        let mark = switch step.status {
        case .passed: "✓"
        case .failed: "✗"
        case .skipped: "-"
        }
        let time = step.status == .skipped && step.milliseconds == 0 ? "" : "  (\(step.milliseconds) ms)"
        let detail = step.message.map { "\n      \($0)" } ?? ""
        return "\(mark) \(step.phase) \(step.index)  \(step.summary)\(time)\(detail)"
    }
}

/// JUnit XML for CI systems: one test case per flow.
public enum JUnitReport {
    public static func xml(_ results: [FlowResult]) -> String {
        let failures = results.filter { !$0.passed }.count
        let total = Double(results.reduce(0) { $0 + $1.milliseconds }) / 1000
        var lines = [
            #"<?xml version="1.0" encoding="UTF-8"?>"#,
            #"<testsuites name="macos-harness flows" tests="\#(results.count)" failures="\#(failures)" time="\#(total)">"#,
            #"  <testsuite name="flows" tests="\#(results.count)" failures="\#(failures)" time="\#(total)">"#,
        ]
        for result in results {
            let time = Double(result.milliseconds) / 1000
            lines.append(#"    <testcase name="\#(escape(result.name))" classname="\#(escape(result.path ?? "flows"))" time="\#(time)">"#)
            let log = escape(result.steps.map(FlowRunner.line).joined(separator: "\n"))
            if let failure = result.failure {
                lines.append(#"      <failure message="\#(escape(failure))">\#(log)</failure>"#)
            }
            lines.append("      <system-out>\(log)</system-out>")
            lines.append("    </testcase>")
        }
        lines += ["  </testsuite>", "</testsuites>"]
        return lines.joined(separator: "\n") + "\n"
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
