import Foundation
import HarnessProtocol

/// The `android` method: lifecycle, apps, buttons and settings of Android emulators and phones.
public enum AndroidControl {
    public static func run(_ params: AndroidMethod.Params) async throws -> AndroidMethod.Result {
        if params.action == .list {
            let devices = try await ADB.devices()
            let running = devices.filter(\.isRunning).count
            return .init(performed: "\(devices.count) Android devices and emulators, \(running) running", devices: devices)
        }
        let device = try await ADB.device(params.device ?? "booted")
        switch params.action {
        case .list:
            return .init(performed: "")
        case .boot:
            return try await boot(device, headless: params.headless ?? false)
        case .shutdown:
            return try await shutdown(device)
        default:
            break
        }
        guard device.isRunning else {
            throw RPCError(code: RPCErrorCode.failed, message: "\(device.name) isn't running. Start it with `macos-harness android boot \"\(device.name)\"`.")
        }
        let serial = device.serial
        switch params.action {
        case .list, .boot, .shutdown:
            return .init(performed: "")
        case .install:
            let path = (try required(params.path, "install needs the .apk to install") as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: path) else {
                throw RPCError(code: RPCErrorCode.invalidParams, message: "No app at \(path).")
            }
            try await ADB.run(["install", "-r", "-t", path], serial: serial, timeout: 300)
            return .init(performed: "installed \((path as NSString).lastPathComponent) on \(device.name)", device: device)
        case .uninstall:
            let package = try required(params.package, "uninstall needs the package name")
            try await ADB.run(["uninstall", package], serial: serial, timeout: 120)
            return .init(performed: "uninstalled \(package) from \(device.name)", device: device)
        case .launch:
            let package = try required(params.package, "launch needs the package name")
            let resolved = try await ADB.shell(serial, "cmd package resolve-activity --brief -c android.intent.category.LAUNCHER \(quote(package))")
            guard let component = resolved.split(whereSeparator: \.isNewline).last.map(String.init), component.contains("/") else {
                throw RPCError(code: RPCErrorCode.failed, message: "\(package) has no launcher activity on \(device.name); is it installed?")
            }
            let output = try await ADB.shell(serial, "am start -S -W -n \(quote(component))", timeout: 120)
            if output.contains("Error") { throw RPCError(code: RPCErrorCode.failed, message: output.trimmingCharacters(in: .whitespacesAndNewlines)) }
            return .init(performed: "launched \(package) on \(device.name)", device: device)
        case .terminate:
            let package = try required(params.package, "terminate needs the package name")
            try await ADB.shell(serial, "am force-stop \(quote(package))")
            return .init(performed: "stopped \(package) on \(device.name)", device: device)
        case .openURL:
            let url = try required(params.url, "open-url needs a URL")
            let target = params.package.map { " -p \(quote($0))" } ?? ""
            let output = try await ADB.shell(serial, "am start -W -a android.intent.action.VIEW -d \(quote(url))\(target)", timeout: 60)
            if output.contains("Error") { throw RPCError(code: RPCErrorCode.failed, message: output.trimmingCharacters(in: .whitespacesAndNewlines)) }
            return .init(performed: "opened \(url) on \(device.name)", device: device)
        case .button:
            let button = try required(params.button, "button needs which: \(AndroidButton.allCases.map(\.rawValue).joined(separator: ", "))")
            try await ADB.shell(serial, command(for: button))
            return .init(performed: "pressed \(button.rawValue) on \(device.name)", device: device)
        case .permission:
            return try await permission(params, device: device)
        case .location:
            guard device.isEmulator else {
                throw RPCError(code: RPCErrorCode.failed, message: "A phone's location can't be set through adb; only an emulator's.")
            }
            guard let latitude = params.latitude, let longitude = params.longitude else {
                throw RPCError(code: RPCErrorCode.invalidParams, message: "location needs a latitude and longitude.")
            }
            try await ADB.run(["emu", "geo", "fix", "\(longitude)", "\(latitude)"], serial: serial)
            return .init(performed: "set \(device.name)'s location to \(latitude), \(longitude)", device: device)
        case .appearance:
            let appearance = try required(params.appearance, "appearance needs light or dark").lowercased()
            guard ["light", "dark"].contains(appearance) else {
                throw RPCError(code: RPCErrorCode.invalidParams, message: "appearance is light or dark.")
            }
            try await ADB.shell(serial, "cmd uimode night \(appearance == "dark" ? "yes" : "no")")
            return .init(performed: "switched \(device.name) to \(appearance) mode", device: device)
        case .rotate:
            let orientation = try required(params.orientation, "rotate needs portrait, landscape, reverse-portrait, reverse-landscape or auto")
            let rotations = ["portrait": 0, "landscape": 1, "reverse-portrait": 2, "reverse-landscape": 3]
            if orientation == "auto" {
                try await ADB.shell(serial, "settings put system accelerometer_rotation 1")
            } else if let rotation = rotations[orientation] {
                try await ADB.shell(serial, "settings put system accelerometer_rotation 0; settings put system user_rotation \(rotation)")
            } else {
                throw RPCError(code: RPCErrorCode.invalidParams, message: "rotate takes portrait, landscape, reverse-portrait, reverse-landscape or auto.")
            }
            ADB.forget(serial)
            return .init(performed: "turned \(device.name) to \(orientation)", device: device)
        case .statusBar:
            return try await statusBar(params, device: device)
        }
    }

    /// Starts an emulator (with a window unless `headless`) and waits until Android has booted.
    static func boot(_ device: AndroidDeviceInfo, headless: Bool) async throws -> AndroidMethod.Result {
        if device.isRunning { return .init(performed: "\(device.name) was already running", device: device) }
        guard device.isEmulator, device.state == "stopped" else {
            throw RPCError(code: RPCErrorCode.failed, message: "\(device.name) is a phone; turn it on and connect it instead.")
        }
        let emulator = try ADB.emulatorPath()
        let options = (headless ? ["-no-window", "-no-audio"] : []) + ["-no-boot-anim"]
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "nohup \"$0\" -avd \"$1\" \(options.joined(separator: " ")) >/dev/null 2>&1 &", emulator, device.name]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        let deadline = Date().addingTimeInterval(300)
        var started: AndroidDeviceInfo?
        while Date() < deadline {
            try await Task.sleep(for: .seconds(2))
            if let found = try? await ADB.devices().first(where: { $0.isEmulator && $0.isRunning && $0.name == device.name }) {
                started = found
                let booted = try? await ADB.shell(found.serial, "getprop sys.boot_completed", timeout: 10)
                if booted?.trimmingCharacters(in: .whitespacesAndNewlines) == "1" { break }
            }
        }
        guard let started, Date() < deadline else {
            throw RPCError(code: RPCErrorCode.failed, message: "\(device.name) didn't finish booting within 5 minutes.")
        }
        return .init(performed: "booted \(device.name)\(headless ? " without a window" : "")", device: try await ADB.device(started.serial))
    }

    static func shutdown(_ device: AndroidDeviceInfo) async throws -> AndroidMethod.Result {
        guard device.isRunning else { return .init(performed: "\(device.name) wasn't running", device: device) }
        guard device.isEmulator else {
            throw RPCError(code: RPCErrorCode.failed, message: "\(device.name) is a phone; macOS Harness only shuts down emulators.")
        }
        try await ADB.run(["emu", "kill"], serial: device.serial, timeout: 30)
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            try await Task.sleep(for: .seconds(1))
            let devices = (try? await ADB.devices()) ?? []
            if !devices.contains(where: { $0.serial == device.serial && $0.isRunning }) { break }
        }
        return .init(performed: "shut down \(device.name)")
    }

    static func command(for button: AndroidButton) -> String {
        switch button {
        case .home: "input keyevent KEYCODE_HOME"
        case .back: "input keyevent KEYCODE_BACK"
        case .appSwitcher: "input keyevent KEYCODE_APP_SWITCH"
        case .power: "input keyevent KEYCODE_POWER"
        case .volumeUp: "input keyevent KEYCODE_VOLUME_UP"
        case .volumeDown: "input keyevent KEYCODE_VOLUME_DOWN"
        case .menu: "input keyevent KEYCODE_MENU"
        case .notifications: "cmd statusbar expand-notifications"
        }
    }

    static func permission(_ params: AndroidMethod.Params, device: AndroidDeviceInfo) async throws -> AndroidMethod.Result {
        let operation = try required(params.operation, "permission needs grant, revoke or reset")
        let package = try required(params.package, "permission needs the package name")
        switch operation {
        case "grant", "revoke":
            let name = try required(params.permission, "permission \(operation) needs a permission, e.g. camera or android.permission.CAMERA")
            let permission = name.contains(".") ? name : "android.permission.\(name.uppercased().replacingOccurrences(of: "-", with: "_"))"
            try await ADB.shell(device.serial, "pm \(operation) \(quote(package)) \(quote(permission))")
            return .init(performed: "\(operation == "grant" ? "granted" : "revoked") \(permission) for \(package) on \(device.name)", device: device)
        case "reset":
            let granted = grantedRuntimePermissions(try await ADB.shell(device.serial, "dumpsys package \(quote(package))", timeout: 30))
            for permission in granted {
                try? await ADB.shell(device.serial, "pm revoke \(quote(package)) \(quote(permission))")
            }
            return .init(performed: "revoked \(granted.count) permission\(granted.count == 1 ? "" : "s") of \(package) on \(device.name)", device: device)
        default:
            throw RPCError(code: RPCErrorCode.invalidParams, message: "permission takes grant, revoke or reset.")
        }
    }

    /// The runtime permissions `dumpsys package` lists as granted.
    static func grantedRuntimePermissions(_ dump: String) -> [String] {
        var inRuntime = false
        var granted: [String] = []
        for line in dump.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("runtime permissions:") {
                inRuntime = true
                continue
            }
            guard inRuntime else { continue }
            guard trimmed.contains(": granted=") else {
                if trimmed.hasSuffix(":") { inRuntime = false }
                continue
            }
            if trimmed.contains("granted=true"), let name = trimmed.split(separator: ":").first.map(String.init), !granted.contains(name) {
                granted.append(name)
            }
        }
        return granted
    }

    static func statusBar(_ params: AndroidMethod.Params, device: AndroidDeviceInfo) async throws -> AndroidMethod.Result {
        let demo = "am broadcast -a com.android.systemui.demo"
        if params.operation == "clear" {
            try await ADB.shell(device.serial, "\(demo) -e command exit")
            return .init(performed: "cleared \(device.name)'s status bar", device: device)
        }
        let overrides = params.statusBar ?? StatusBarOverrides()
        let time = (overrides.time ?? "9:41").replacingOccurrences(of: ":", with: "")
        let hhmm = time.count == 3 ? "0" + time : time
        let commands = [
            "settings put global sysui_demo_allowed 1",
            "\(demo) -e command enter",
            "\(demo) -e command clock -e hhmm \(hhmm)",
            "\(demo) -e command battery -e level \(overrides.batteryLevel ?? 100) -e plugged \(overrides.batteryState == "charging" ? "true" : "false")",
            "\(demo) -e command network -e wifi show -e level \(min(overrides.wifiBars ?? 4, 4))",
            "\(demo) -e command network -e mobile show -e datatype none -e level \(min(overrides.cellularBars ?? 4, 4))",
            "\(demo) -e command notifications -e visible false",
        ]
        try await ADB.shell(device.serial, commands.joined(separator: " >/dev/null; ") + " >/dev/null")
        return .init(performed: "set \(device.name)'s status bar to a clean \(overrides.time ?? "9:41")", device: device)
    }

    /// A single-quoted shell word.
    static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func required<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw RPCError(code: RPCErrorCode.invalidParams, message: message) }
        return value
    }
}
