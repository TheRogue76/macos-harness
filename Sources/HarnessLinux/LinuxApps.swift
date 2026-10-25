import Foundation
import HarnessCore
import HarnessProtocol
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Launching and quitting Linux desktop apps.
public enum LinuxApps {
    /// How to start an app: the program and the arguments its desktop entry gives.
    struct Command: Equatable {
        var executable: String
        var arguments: [String]
    }

    public static func launch(_ params: LaunchMethod.Params) async throws -> LaunchMethod.Result {
        try refuseDevices(params.app, verb: "launch", android: "android launch", simulator: "sim launch")
        let started = Date()
        if params.newInstance != true, let running = try? await runningApp(params.app) {
            let windows = try await LinuxDesktop.windows(WindowsMethod.Params(app: String(running.pid))).windows
            return LaunchMethod.Result(app: running, windows: windows, alreadyRunning: true, milliseconds: milliseconds(since: started))
        }
        guard let command = command(for: params.app) else {
            throw RPCError(
                code: RPCErrorCode.failed,
                message: "Can't find an app called “\(params.app)”. Give the name its desktop entry shows, its desktop file ID, a command on PATH, or a path to the program."
            )
        }
        let pid: pid_t
        do {
            pid = try Spawn.app(
                command.executable, arguments: command.arguments + params.open + params.arguments,
                environment: ProcessInfo.processInfo.environment.merging(params.environment) { _, new in new }
            )
        } catch {
            throw RPCError(code: RPCErrorCode.failed, message: "Couldn't start \(command.executable): \(error.localizedDescription)")
        }
        let deadline = started.addingTimeInterval(params.timeout > 0 ? params.timeout : 10)
        while Date() < deadline {
            try await Task.sleep(for: .milliseconds(200))
            let query = isAlive(pid) ? String(pid) : params.app
            if let windows = try? await LinuxDesktop.windows(WindowsMethod.Params(app: query)).windows, let first = windows.first {
                return LaunchMethod.Result(app: first.app, windows: windows, alreadyRunning: false, milliseconds: milliseconds(since: started))
            }
        }
        let name = (command.executable as NSString).lastPathComponent
        return LaunchMethod.Result(
            app: AppRef(name: name, bundleIdentifier: nil, pid: pid), windows: [], alreadyRunning: false,
            milliseconds: milliseconds(since: started),
            notices: [Notice(kind: "noWindow", message: "\(name) started but showed no window with an accessibility tree in time.")]
        )
    }

    public static func quit(_ params: QuitMethod.Params) async throws -> QuitMethod.Result {
        try refuseDevices(params.app, verb: "stop an app on", android: "android terminate", simulator: "sim terminate")
        guard let app = try? await runningApp(params.app) else {
            return QuitMethod.Result(app: AppRef(name: params.app, bundleIdentifier: nil, pid: 0), quit: true, message: "\(params.app) wasn't running.")
        }
        guard app.pid > 0, isAlive(app.pid) else {
            return QuitMethod.Result(app: app, quit: true, message: "\(app.name) wasn't running.")
        }
        kill(app.pid, params.force ? SIGKILL : SIGTERM)
        let deadline = Date().addingTimeInterval(params.timeout)
        while Date() < deadline, isAlive(app.pid) {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if !isAlive(app.pid) {
            return QuitMethod.Result(app: app, quit: true, message: "\(app.name) quit.")
        }
        return QuitMethod.Result(
            app: app, quit: false,
            message: "\(app.name) is still running; it may be asking to save changes. Take a snapshot to see, or use --force (unsaved work is lost)."
        )
    }

    private static func refuseDevices(_ app: String, verb: String, android: String, simulator: String) throws {
        if let device = Target.androidDevice(in: app) {
            throw RPCError(code: RPCErrorCode.invalidParams, message: "To \(verb) Android, use `\(android) \(device) <package>`.")
        }
        if Target.simulatorDevice(in: app) != nil {
            throw RPCError(code: RPCErrorCode.invalidParams, message: "iOS Simulators need macOS.")
        }
    }

    /// The running app a name or pid means, as a reference.
    static func runningApp(_ query: String) async throws -> AppRef {
        let connection = try await ATSPIBus.shared.connection()
        let app = try LinuxDesktop.pick(query, from: try await ATSPI.apps(on: connection))
        return AppRef(name: LinuxDesktop.displayName(app), bundleIdentifier: LinuxDesktop.appID(app), pid: app.pid ?? -1)
    }

    /// Whether a process exists and hasn't exited.
    static func isAlive(_ pid: pid_t) -> Bool {
        guard kill(pid, 0) == 0 else { return false }
        guard let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
              let close = stat.lastIndex(of: ")") else { return true }
        let state = stat[stat.index(after: close)...].split(separator: " ").first
        return state != "Z" && state != "X"
    }

    private static func milliseconds(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }

    /// The command that starts the app a name means: a path, a desktop entry, or a program
    /// named like the app next to the helper or on PATH.
    static func command(
        for name: String, environment: [String: String] = ProcessInfo.processInfo.environment,
        helperDirectory: String = (CommandLine.arguments.first.map { ($0 as NSString).deletingLastPathComponent }) ?? ""
    ) -> Command? {
        let files = FileManager.default
        if name.contains("/") {
            return files.isExecutableFile(atPath: name) ? Command(executable: name, arguments: []) : nil
        }
        for directory in applicationDirectories(environment) {
            guard let entries = try? files.contentsOfDirectory(atPath: directory) else { continue }
            for entry in entries.sorted() where entry.hasSuffix(".desktop") {
                guard let text = try? String(contentsOfFile: "\(directory)/\(entry)", encoding: .utf8),
                      let desktop = DesktopEntry(text), !desktop.hidden else { continue }
                let id = String(entry.dropLast(".desktop".count))
                let names = [desktop.name, id, String(id.split(separator: ".").last ?? "")].compactMap { $0 }
                guard names.contains(where: { matches(name, $0) }), let exec = desktop.exec else { continue }
                let words = execWords(exec)
                guard let program = words.first, let path = resolve(program, environment: environment) else { continue }
                return Command(executable: path, arguments: Array(words.dropFirst()))
            }
        }
        let programs = Set([name.lowercased().replacingOccurrences(of: " ", with: "-"), name.replacingOccurrences(of: " ", with: ""), name])
        for program in programs.sorted() {
            let beside = "\(helperDirectory)/\(program)"
            if !helperDirectory.isEmpty, files.isExecutableFile(atPath: beside) { return Command(executable: beside, arguments: []) }
        }
        for program in programs.sorted() {
            if let path = resolve(program, environment: environment) { return Command(executable: path, arguments: []) }
        }
        return nil
    }

    /// Whether two app names are the same ignoring case, spaces, dashes and underscores.
    static func matches(_ a: String, _ b: String) -> Bool {
        let normalize = { (text: String) in text.lowercased().filter { !" -_".contains($0) } }
        return !a.isEmpty && normalize(a) == normalize(b)
    }

    /// Where desktop entries live, most personal first.
    static func applicationDirectories(_ environment: [String: String]) -> [String] {
        let home = environment["HOME"] ?? NSHomeDirectory()
        let dataHome = environment["XDG_DATA_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? "\(home)/.local/share"
        let dataDirs = (environment["XDG_DATA_DIRS"].flatMap { $0.isEmpty ? nil : $0 } ?? "/usr/local/share:/usr/share").split(separator: ":").map(String.init)
        let flatpak = ["\(dataHome)/flatpak/exports/share", "/var/lib/flatpak/exports/share"]
        var seen: Set<String> = []
        return ([dataHome] + dataDirs + flatpak).map { "\($0)/applications" }.filter { seen.insert($0).inserted }
    }

    /// A program name as a path, searching PATH.
    static func resolve(_ program: String, environment: [String: String]) -> String? {
        if program.hasPrefix("/") { return FileManager.default.isExecutableFile(atPath: program) ? program : nil }
        let path = environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin"
        return path.split(separator: ":").map { "\($0)/\(program)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// A desktop entry's Exec line as words, without its field codes.
    static func execWords(_ exec: String) -> [String] {
        var words: [String] = []
        var current = ""
        var quoted = false
        var escaped = false
        var started = false
        for character in exec {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                quoted.toggle()
                started = true
            } else if character == " ", !quoted {
                if started { words.append(current) }
                current = ""
                started = false
            } else {
                current.append(character)
                started = true
            }
        }
        if started { words.append(current) }
        let codes: Set<String> = ["%f", "%F", "%u", "%U", "%i", "%c", "%k", "%d", "%D", "%n", "%N", "%v", "%m"]
        return words.filter { !codes.contains($0) }.map { $0.replacingOccurrences(of: "%%", with: "%") }
    }

    /// The parts of a desktop entry's main group that launching needs.
    struct DesktopEntry {
        var name: String?
        var exec: String?
        var hidden = false

        init?(_ text: String) {
            var inMain = false
            for line in text.split(whereSeparator: \.isNewline) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("[") {
                    inMain = trimmed == "[Desktop Entry]"
                    continue
                }
                guard inMain, let equals = trimmed.firstIndex(of: "=") else { continue }
                let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
                let value = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
                switch key {
                case "Name": name = value
                case "Exec": exec = value
                case "Type": if value != "Application" { hidden = true }
                case "Hidden": if value == "true" { hidden = true }
                default: break
                }
            }
            guard name != nil || exec != nil else { return nil }
        }
    }
}
