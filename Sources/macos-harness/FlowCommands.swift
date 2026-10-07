import ArgumentParser
import Foundation
import HarnessClient
import HarnessProtocol

struct FlowCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "flow",
        abstract: "Run and check UI flows: YAML files of steps with expectations.",
        subcommands: [FlowRun.self, FlowCheck.self]
    )
}

struct FlowRun: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run flows; failures save a screenshot, the UI tree and the step log."
    )

    @Argument(help: "Flow files, or folders of .yaml files.")
    var paths: [String]

    @Option(name: .customLong("var"), help: "name=value for a ${name} variable (repeatable).")
    var variables: [String] = []

    @Option(help: "Write a JUnit XML report here.")
    var junit: String?

    @Option(help: "Folder for failure artifacts (private flows use ~/Library/Logs/macos-harness/flow-results).")
    var artifacts = "flow-results"

    @OptionGroup var output: OutputOptions

    func run() throws {
        let overrides = try FlowFiles.variables(variables)
        let files = try FlowFiles.expand(paths)
        var results: [FlowResult] = []
        try reportingErrors(json: output.json) {
            for file in files {
                let flow: Flow
                do {
                    flow = try FlowParser.parse(file: file, overrides: overrides)
                } catch {
                    let message = (error as? FlowError)?.description ?? String(describing: error)
                    results.append(FlowResult(name: file, path: file, passed: false, milliseconds: 0, steps: [], failure: message))
                    if !output.json { print("✗ \(message)") }
                    continue
                }
                if !output.json { print("▶ \(flow.name)") }
                let connection = try HarnessConnection.openAnnouncingPairing()
                let runner = FlowRunner(caller: connection, artifactsRoot: artifacts) { line in
                    if !output.json { print("  " + line.replacingOccurrences(of: "\n", with: "\n  ")) }
                }
                let result = runner.run(flow)
                results.append(result)
                if !output.json {
                    let verdict = result.passed ? "PASS" : "FAIL"
                    print("\(verdict) \(flow.name) (\(String(format: "%.1f", Double(result.milliseconds) / 1000)) s)")
                    if let artifacts = result.artifacts { print("  artifacts: \(artifacts)") }
                    print("")
                }
            }
        }
        if let junit {
            let folder = (junit as NSString).deletingLastPathComponent
            if !folder.isEmpty {
                try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            }
            try JUnitReport.xml(results).write(toFile: junit, atomically: true, encoding: .utf8)
        }
        let failed = results.filter { !$0.passed }
        if output.json {
            try Output.json(results)
        } else {
            print("\(results.count - failed.count) passed, \(failed.count) failed")
        }
        if !failed.isEmpty { throw ExitCode.failure }
    }
}

struct FlowCheck: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "check",
        abstract: "Check flow files for mistakes without running them."
    )

    @Argument(help: "Flow files, or folders of .yaml files.")
    var paths: [String]

    @Option(name: .customLong("var"), help: "name=value for a ${name} variable (repeatable).")
    var variables: [String] = []

    func run() throws {
        let overrides = try FlowFiles.variables(variables)
        var failures = 0
        for file in try FlowFiles.expand(paths) {
            do {
                let flow = try FlowParser.parse(file: file, overrides: overrides)
                let count = flow.setup.count + flow.steps.count + flow.teardown.count
                print("✓ \(file): \(flow.name), \(count) step\(count == 1 ? "" : "s")")
            } catch {
                failures += 1
                print("✗ \((error as? FlowError)?.description ?? String(describing: error))")
            }
        }
        if failures > 0 { throw ExitCode.failure }
    }
}

enum FlowFiles {
    /// The flow files named, with folders replaced by the .yaml and .yml files in them, recursively.
    static func expand(_ paths: [String]) throws -> [String] {
        var files: [String] = []
        for path in paths {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
                throw ValidationError("No such file or folder: \(path)")
            }
            guard isDirectory.boolValue else {
                files.append(path)
                continue
            }
            let found = (FileManager.default.enumerator(atPath: path)?.allObjects as? [String] ?? [])
                .filter { $0.hasSuffix(".yaml") || $0.hasSuffix(".yml") }
                .sorted()
                .map { (path as NSString).appendingPathComponent($0) }
            files += found
        }
        guard !files.isEmpty else { throw ValidationError("No flow files in \(paths.joined(separator: ", ")).") }
        return files
    }

    static func variables(_ pairs: [String]) throws -> [String: String] {
        var result: [String: String] = [:]
        for pair in pairs {
            guard let equals = pair.firstIndex(of: "=") else { throw ValidationError("--var takes name=value, not \(pair)") }
            result[String(pair[..<equals])] = String(pair[pair.index(after: equals)...])
        }
        return result
    }
}
