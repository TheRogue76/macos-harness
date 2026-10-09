import Foundation
import HarnessProtocol

/// Builds an Xcode project or workspace for the iOS Simulator with `xcodebuild`, and finds the
/// app it made.
public enum AppBuilder {
    public struct Request: Codable, Sendable, Equatable {
        /// A `.xcodeproj`; nil looks in `directory`.
        public var project: String?
        /// A `.xcworkspace`; preferred over a project when both are given.
        public var workspace: String?
        /// nil uses the only scheme there is.
        public var scheme: String?
        public var configuration: String
        /// The simulator to build for (UDID, name or booted); nil builds for any simulator.
        public var device: String?
        /// Where to look for a project or workspace when neither is given.
        public var directory: String

        public init(
            project: String? = nil, workspace: String? = nil, scheme: String? = nil, configuration: String = "Debug",
            device: String? = nil, directory: String = FileManager.default.currentDirectoryPath
        ) {
            self.project = project
            self.workspace = workspace
            self.scheme = scheme
            self.configuration = configuration
            self.device = device
            self.directory = directory
        }
    }

    public struct Outcome: Codable, Sendable {
        public var succeeded: Bool
        public var scheme: String
        /// The built `.app`, when the build succeeded.
        public var appPath: String?
        public var bundleIdentifier: String?
        /// The simulator it was built for, when one was named.
        public var device: SimulatorInfo?
        /// Compiler and build errors, one per line, at most 30.
        public var errors: [String]
        public var warnings: Int
        public var seconds: Double
        /// The full xcodebuild output.
        public var logPath: String
    }

    /// Runs the build to the end, passing each line of output to `progress`.
    public static func build(_ request: Request, progress: (@Sendable (String) -> Void)? = nil) throws -> Outcome {
        let started = Date()
        var arguments = try container(for: request)
        let scheme = try request.scheme ?? onlyScheme(arguments)
        arguments += ["-scheme", scheme, "-configuration", request.configuration]
        var device: SimulatorInfo?
        if let query = request.device {
            device = try simulator(query)
            arguments += ["-destination", "platform=iOS Simulator,id=\(device!.udid)"]
        } else {
            arguments += ["-destination", "generic/platform=iOS Simulator"]
        }

        let log = try logURL()
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        let collector = LineCollector()
        let status = try run(arguments + ["build"]) { line in
            handle.write(Data((line + "\n").utf8))
            collector.take(line)
            progress?(line)
        }

        var outcome = Outcome(
            succeeded: status == 0, scheme: scheme, device: device, errors: collector.errors, warnings: collector.warnings,
            seconds: (Date().timeIntervalSince(started) * 10).rounded() / 10, logPath: log.path
        )
        if status == 0, let product = try? product(arguments) {
            outcome.appPath = product.path
            outcome.bundleIdentifier = product.bundleIdentifier
        }
        if status != 0, outcome.errors.isEmpty {
            outcome.errors = ["xcodebuild exited with status \(status); see \(log.path)"]
        }
        return outcome
    }

    /// `-project`/`-workspace` arguments for the request, finding one in the directory when needed.
    static func container(for request: Request) throws -> [String] {
        if let workspace = request.workspace { return ["-workspace", expand(workspace, in: request.directory)] }
        if let project = request.project { return ["-project", expand(project, in: request.directory)] }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: request.directory)) ?? []
        let workspaces = names.filter { $0.hasSuffix(".xcworkspace") }
        let projects = names.filter { $0.hasSuffix(".xcodeproj") }
        if workspaces.count == 1 { return ["-workspace", (request.directory as NSString).appendingPathComponent(workspaces[0])] }
        if projects.count == 1 { return ["-project", (request.directory as NSString).appendingPathComponent(projects[0])] }
        let found = (workspaces + projects).joined(separator: ", ")
        throw RPCError(
            code: RPCErrorCode.invalidParams,
            message: found.isEmpty
                ? "No .xcodeproj or .xcworkspace in \(request.directory); pass --project or --workspace."
                : "Several projects here (\(found)); pass --project or --workspace."
        )
    }

    static func expand(_ path: String, in directory: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return (expanded as NSString).isAbsolutePath ? expanded : (directory as NSString).appendingPathComponent(expanded)
    }

    /// The scheme to build when none was named: the only one there is.
    static func onlyScheme(_ container: [String]) throws -> String {
        struct Listing: Decodable {
            struct Info: Decodable { var schemes: [String]? }
            var project: Info?
            var workspace: Info?
        }
        let data = try capture(container + ["-list", "-json"])
        let listing = try? JSONDecoder().decode(Listing.self, from: data)
        let schemes = listing?.workspace?.schemes ?? listing?.project?.schemes ?? []
        guard schemes.count == 1 else {
            throw RPCError(
                code: RPCErrorCode.invalidParams,
                message: schemes.isEmpty ? "xcodebuild found no schemes." : "Name a scheme with --scheme: \(schemes.joined(separator: ", "))."
            )
        }
        return schemes[0]
    }

    /// The simulator a query names, from `simctl`.
    static func simulator(_ query: String) throws -> SimulatorInfo {
        let data = try capture(["list", "devices", "available", "--json"], tool: "simctl")
        return try SimulatorCatalog.pick(query, from: try SimulatorCatalog.parseDevices(data))
    }

    /// The application the build made, from the build settings.
    static func product(_ arguments: [String]) throws -> (path: String, bundleIdentifier: String?) {
        struct Target: Decodable {
            var buildSettings: [String: String]
        }
        let data = try capture(arguments + ["-showBuildSettings", "-json"])
        let targets = try JSONDecoder().decode([Target].self, from: data)
        guard let app = targets.first(where: { $0.buildSettings["WRAPPER_EXTENSION"] == "app" }),
              let directory = app.buildSettings["TARGET_BUILD_DIR"], let name = app.buildSettings["FULL_PRODUCT_NAME"] else {
            throw RPCError(code: RPCErrorCode.failed, message: "The scheme doesn't build an app.")
        }
        return ((directory as NSString).appendingPathComponent(name), app.buildSettings["PRODUCT_BUNDLE_IDENTIFIER"])
    }

    static func logURL() throws -> URL {
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/macos-harness/builds")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return directory.appendingPathComponent("build-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(4)).log")
    }

    /// Runs xcodebuild (or another developer tool) and returns what it printed.
    static func capture(_ arguments: [String], tool: String = "xcodebuild") throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [tool] + arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw RPCError(code: RPCErrorCode.failed, message: "\(tool) \(arguments.suffix(2).joined(separator: " ")) failed (status \(process.terminationStatus)).")
        }
        return data
    }

    /// Runs xcodebuild, handing over each line of its combined output; returns its exit status.
    static func run(_ arguments: [String], line: (String) -> Void) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["xcodebuild"] + arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        try process.run()
        var pending = Data()
        let reader = output.fileHandleForReading
        while true {
            let chunk = reader.availableData
            if chunk.isEmpty { break }
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 0x0A) {
                line(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
                pending.removeSubrange(pending.startIndex...newline)
            }
        }
        if !pending.isEmpty { line(String(decoding: pending, as: UTF8.self)) }
        process.waitUntilExit()
        return process.terminationStatus
    }
}

/// Picks errors out of build output and counts warnings.
final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var errorLines: [String] = []
    private var warningCount = 0

    var errors: [String] { lock.withLock { errorLines } }
    var warnings: Int { lock.withLock { warningCount } }

    func take(_ line: String) {
        lock.withLock {
            if line.contains(": error: ") || line.hasPrefix("error: ") || line.contains("xcodebuild: error:") {
                if errorLines.count < 30, !errorLines.contains(line) { errorLines.append(line) }
            } else if line.contains(": warning: ") {
                warningCount += 1
            }
        }
    }
}

/// Builds started from the MCP server, running in the background so the tool call returns at once.
final class BuildJobs: @unchecked Sendable {
    static let shared = BuildJobs()

    private struct Job {
        var started: Date
        var lastLine: String
        var outcome: AppBuilder.Outcome?
        var failure: String?
    }

    private let lock = NSLock()
    private var jobs: [String: Job] = [:]
    private var counter = 0

    /// Starts a build and returns its ID.
    func start(_ request: AppBuilder.Request) -> String {
        let id = lock.withLock { () -> String in
            counter += 1
            let next = "build-\(counter)"
            jobs[next] = Job(started: Date(), lastLine: "")
            return next
        }
        Thread.detachNewThread { [self] in
            do {
                let outcome = try AppBuilder.build(request) { line in
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return }
                    self.lock.withLock { self.jobs[id]?.lastLine = String(trimmed.prefix(160)) }
                }
                lock.withLock { jobs[id]?.outcome = outcome }
            } catch let error as RPCError {
                lock.withLock { jobs[id]?.failure = error.message }
            } catch {
                lock.withLock { jobs[id]?.failure = String(describing: error) }
            }
        }
        return id
    }

    /// Where a build is, in a sentence or a short report.
    func status(_ id: String) throws -> String {
        guard let job = lock.withLock({ jobs[id] }) else {
            throw RPCError(code: RPCErrorCode.invalidParams, message: "No build \(id) in this session.")
        }
        if let failure = job.failure { return "\(id) couldn't run: \(failure)" }
        guard let outcome = job.outcome else {
            let seconds = Int(Date().timeIntervalSince(job.started))
            return "\(id) is still building (\(seconds) s so far). Last output: \(job.lastLine)"
        }
        guard outcome.succeeded else {
            return (["\(id) failed after \(outcome.seconds) s:"] + outcome.errors + ["Log: \(outcome.logPath)"]).joined(separator: "\n")
        }
        var lines = ["\(id) succeeded in \(outcome.seconds) s (\(outcome.warnings) warnings).", "App: \(outcome.appPath ?? "?")"]
        if let bundle = outcome.bundleIdentifier { lines.append("Bundle ID: \(bundle)") }
        if let device = outcome.device { lines.append("Built for \(device.name) (\(device.udid)); install it with simulator action install.") }
        return lines.joined(separator: "\n")
    }
}
