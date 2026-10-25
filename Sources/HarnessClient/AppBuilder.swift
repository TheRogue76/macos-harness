import Foundation
import HarnessProtocol

/// Builds an Xcode project or workspace with `xcodebuild`, for the iOS Simulator or this Mac, and
/// finds the app it made.
public enum AppBuilder {
    /// Where a build's app runs.
    public enum Platform: String, Codable, Sendable, Equatable {
        case iosSimulator = "ios-simulator"
        case macOS = "macos"
        case macCatalyst = "mac-catalyst"

        /// Whether the app runs on this Mac rather than on a simulator.
        public var isMac: Bool { self != .iosSimulator }

        /// The platform as build reports name it.
        public var displayName: String {
            switch self {
            case .iosSimulator: "the iOS Simulator"
            case .macOS: "macOS"
            case .macCatalyst: "Mac Catalyst"
            }
        }
    }

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
        /// Build for this Mac, natively or as Mac Catalyst, even when the scheme has a simulator.
        public var mac: Bool
        /// Where to look for a project or workspace when neither is given.
        public var directory: String

        public init(
            project: String? = nil, workspace: String? = nil, scheme: String? = nil, configuration: String = "Debug",
            device: String? = nil, mac: Bool = false, directory: String = FileManager.default.currentDirectoryPath
        ) {
            self.project = project
            self.workspace = workspace
            self.scheme = scheme
            self.configuration = configuration
            self.device = device
            self.mac = mac
            self.directory = directory
        }
    }

    /// What a request comes to once the scheme and platform are known.
    public struct Plan: Sendable {
        public var scheme: String
        public var platform: Platform
        /// The simulator, when one was named.
        public var device: SimulatorInfo?
        /// xcodebuild's arguments, up to the action.
        var arguments: [String]

        /// Whether a run after the build has somewhere to go: this Mac, or a named simulator.
        public var canRun: Bool { platform.isMac || device != nil }
    }

    /// A destination `xcodebuild -showdestinations` lists for a scheme.
    struct Destination: Equatable {
        var platform: String
        var arch: String?
        var variant: String?
    }

    /// What running a Mac build did: the older copies it quit, and the launch.
    public struct MacRun: Codable, Sendable {
        /// Running copies of the app (the same bundle ID) quit before the launch.
        public var replaced: [AppRef]
        public var launch: LaunchMethod.Result
    }

    public struct Outcome: Codable, Sendable {
        public var succeeded: Bool
        public var scheme: String
        public var platform: Platform
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
        try build(plan(request), progress: progress)
    }

    /// Finds the project, the scheme and the platform to build for, without building.
    public static func plan(_ request: Request) throws -> Plan {
        var arguments = try container(for: request)
        let scheme = try request.scheme ?? onlyScheme(arguments)
        arguments += ["-scheme", scheme, "-configuration", request.configuration]
        if let query = request.device {
            guard !request.mac else {
                throw RPCError(code: RPCErrorCode.invalidParams, message: "A device is a simulator; leave it out to build for this Mac.")
            }
            let device = try simulator(query)
            return Plan(
                scheme: scheme, platform: .iosSimulator, device: device,
                arguments: arguments + ["-destination", "platform=iOS Simulator,id=\(device.udid)"]
            )
        }
        let listed = (try? capture(arguments + ["-showdestinations"])).map { destinations(in: String(decoding: $0, as: UTF8.self)) } ?? []
        let platform = try platform(for: listed, mac: request.mac, scheme: scheme)
        return Plan(
            scheme: scheme, platform: platform, device: nil,
            arguments: arguments + ["-destination", destination(for: platform, from: listed)]
        )
    }

    /// The destinations a scheme can build for, from `xcodebuild -showdestinations`, leaving out
    /// the ones listed as incompatible or ineligible.
    static func destinations(in output: String) -> [Destination] {
        var eligible = true
        var found: [Destination] = []
        for raw in output.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasSuffix(":"), !line.hasPrefix("{") {
                let header = line.lowercased()
                eligible = !header.contains("incompatible") && !header.contains("ineligible")
                continue
            }
            guard eligible, line.hasPrefix("{"), line.hasSuffix("}") else { continue }
            var fields: [String: String] = [:]
            for pair in line.dropFirst().dropLast().components(separatedBy: ", ") {
                guard let colon = pair.firstIndex(of: ":") else { continue }
                let key = pair[..<colon].trimmingCharacters(in: .whitespaces)
                fields[key] = pair[pair.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            guard let platform = fields["platform"], fields["error"] == nil else { continue }
            found.append(Destination(platform: platform, arch: fields["arch"], variant: fields["variant"]))
        }
        return found
    }

    /// The platform to build for: this Mac when `mac` is set or the scheme has no iOS Simulator
    /// (natively when the scheme supports macOS, as Mac Catalyst otherwise), the iOS Simulator
    /// otherwise and when the destinations couldn't be read.
    static func platform(for destinations: [Destination], mac: Bool, scheme: String) throws -> Platform {
        let macPlatform: Platform? = destinations.contains { $0.platform == "macOS" && $0.variant == nil }
            ? .macOS
            : destinations.contains { $0.platform == "macOS" && $0.variant == "Mac Catalyst" } ? .macCatalyst : nil
        let platforms = Set(destinations.map { [$0.platform, $0.variant].compactMap { $0 }.joined(separator: " ") }).sorted()
        if mac {
            if let macPlatform { return macPlatform }
            if destinations.isEmpty { return .macOS }
            throw RPCError(
                code: RPCErrorCode.invalidParams,
                message: "\(scheme) doesn't build for this Mac; it builds for \(platforms.joined(separator: ", "))."
            )
        }
        if destinations.isEmpty || destinations.contains(where: { $0.platform == "iOS Simulator" }) { return .iosSimulator }
        if let macPlatform { return macPlatform }
        throw RPCError(
            code: RPCErrorCode.invalidParams,
            message: "\(scheme) builds for \(platforms.joined(separator: ", ")); build covers the iOS Simulator and this Mac."
        )
    }

    /// The `-destination` for a platform, with this Mac's architecture as the scheme lists it, so
    /// xcodebuild doesn't also match the Rosetta destination.
    static func destination(for platform: Platform, from destinations: [Destination]) -> String {
        let variant = platform == .macCatalyst ? "Mac Catalyst" : nil
        let arch = destinations.first { $0.platform == "macOS" && $0.variant == variant && $0.arch != nil }?.arch
        let mac = "platform=macOS" + (arch.map { ",arch=\($0)" } ?? "")
        switch platform {
        case .iosSimulator: return "generic/platform=iOS Simulator"
        case .macOS: return mac
        case .macCatalyst: return mac + ",variant=Mac Catalyst"
        }
    }

    /// Builds what `plan` describes, passing each line of output to `progress`.
    public static func build(_ plan: Plan, progress: (@Sendable (String) -> Void)? = nil) throws -> Outcome {
        let started = Date()
        let arguments = plan.arguments
        let log = try logURL()
        _ = FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        let collector = LineCollector()
        let status = try run(arguments + ["build"]) { line in
            handle.write(Data((line + "\n").utf8))
            collector.take(line)
            progress?(line)
        }

        var outcome = Outcome(
            succeeded: status == 0, scheme: plan.scheme, platform: plan.platform, device: plan.device, errors: collector.errors,
            warnings: collector.warnings, seconds: (Date().timeIntervalSince(started) * 10).rounded() / 10, logPath: log.path
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

    /// Runs a Mac build the way `launch` does: quits the running copies of the app (the same
    /// bundle ID, never another app), launches the new build and waits up to `timeout` seconds for
    /// its first window.
    public static func runOnMac(_ outcome: Outcome, caller: HarnessCalling, timeout: Double = 15) throws -> MacRun {
        guard outcome.platform.isMac, let path = outcome.appPath else {
            throw RPCError(code: RPCErrorCode.failed, message: "The build didn't say which Mac app it made.")
        }
        var replaced: [AppRef] = []
        if let bundle = outcome.bundleIdentifier {
            let running = try caller.call(AppsMethod.self, .init(includeBackground: true), timeout: 30).apps
            for copy in olderCopies(of: bundle, in: running) {
                let result = try caller.call(QuitMethod.self, .init(app: String(copy.pid), timeout: 10), timeout: 40)
                guard result.quit else {
                    throw RPCError(
                        code: RPCErrorCode.failed,
                        message: "An older copy of \(copy.name) (pid \(copy.pid)) is still running; it may be asking to save changes. Quit it (`quit \(copy.pid) --force` loses unsaved work) and run again."
                    )
                }
                replaced.append(AppRef(name: copy.name, bundleIdentifier: copy.bundleIdentifier, pid: copy.pid))
            }
        }
        let launch = try caller.call(LaunchMethod.self, .init(app: path, timeout: timeout), timeout: timeout + 60)
        return MacRun(replaced: replaced, launch: launch)
    }

    /// The running apps a new build replaces: those with its bundle ID.
    static func olderCopies(of bundleIdentifier: String, in apps: [AppsMethod.App]) -> [AppsMethod.App] {
        apps.filter { $0.bundleIdentifier?.caseInsensitiveCompare(bundleIdentifier) == .orderedSame }
    }

    static func logURL() throws -> URL {
        let directory = URL(fileURLWithPath: HarnessPaths.logsDirectory()).appendingPathComponent("builds")
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
        process.standardInput = FileHandle.nullDevice
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
        var launching = false
        var launch: String?
    }

    private let lock = NSLock()
    private var jobs: [String: Job] = [:]
    private var counter = 0

    /// Starts a build and returns its ID; with `run`, a successful build is then installed and
    /// launched on the simulator it was built for, or launched on this Mac in place of any older
    /// copy.
    func start(_ request: AppBuilder.Request, run: Bool = false) -> String {
        let id = lock.withLock { () -> String in
            counter += 1
            let next = "build-\(counter)"
            jobs[next] = Job(started: Date(), lastLine: "")
            return next
        }
        Thread.detachNewThread { [self] in
            do {
                let plan = try AppBuilder.plan(request)
                if run, !plan.canRun {
                    throw RPCError(
                        code: RPCErrorCode.invalidParams,
                        message: "\(plan.scheme) builds for the iOS Simulator, so run needs device to say which one (or mac=true to build it for this Mac)."
                    )
                }
                let outcome = try AppBuilder.build(plan) { line in
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return }
                    self.lock.withLock { self.jobs[id]?.lastLine = String(trimmed.prefix(160)) }
                }
                let launches = run && outcome.succeeded
                lock.withLock {
                    jobs[id]?.outcome = outcome
                    jobs[id]?.launching = launches
                }
                if launches { launch(outcome, job: id) }
            } catch let error as RPCError {
                lock.withLock { jobs[id]?.failure = error.message }
            } catch {
                lock.withLock { jobs[id]?.failure = String(describing: error) }
            }
        }
        return id
    }

    private func launch(_ outcome: AppBuilder.Outcome, job id: String) {
        let report: String
        let doing = outcome.platform.isMac ? "launch" : "install and launch"
        do {
            let connection = try HarnessConnection.open()
            if outcome.platform.isMac {
                report = Render.macRun(try AppBuilder.runOnMac(outcome, caller: connection))
            } else {
                guard let app = outcome.appPath, let bundle = outcome.bundleIdentifier, let device = outcome.device else {
                    throw RPCError(code: RPCErrorCode.failed, message: "the build didn't say which app it made or which simulator it was for.")
                }
                _ = try connection.call(SimulatorMethod.self, .init(action: .install, device: device.udid, path: app), timeout: 360)
                let launched = try connection.call(
                    SimulatorMethod.self, .init(action: .launch, device: device.udid, bundleIdentifier: bundle), timeout: 180
                )
                report = Render.simulator(launched)
            }
        } catch let error as RPCError {
            report = "Couldn't \(doing) it: \(error.message)"
        } catch {
            report = "Couldn't \(doing) it: \(error)"
        }
        lock.withLock {
            jobs[id]?.launching = false
            jobs[id]?.launch = report
        }
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
        if job.launching {
            return "\(id) built in \(outcome.seconds) s; \(outcome.platform.isMac ? "launching" : "installing and launching") it now."
        }
        var lines = [
            "\(id) succeeded in \(outcome.seconds) s (\(outcome.warnings) warnings), for \(outcome.platform.displayName).",
            "App: \(outcome.appPath ?? "?")",
        ]
        if let bundle = outcome.bundleIdentifier { lines.append("Bundle ID: \(bundle)") }
        if let launch = job.launch {
            lines.append(launch)
        } else if let device = outcome.device {
            lines.append("Built for \(device.name) (\(device.udid)); install it with simulator action install.")
        } else if outcome.platform.isMac {
            lines.append("Build with run=true to launch it in place of any running copy, or launch it by its path.")
        }
        return lines.joined(separator: "\n")
    }
}
