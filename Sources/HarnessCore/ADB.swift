import Foundation
import HarnessProtocol

/// Runs adb and the Android emulator, and reads what they report about devices.
public enum ADB {
    /// The Android SDK: `ANDROID_HOME`, `ANDROID_SDK_ROOT`, or Android Studio's default place.
    static func sdkRoot() -> String? {
        let environment = ProcessInfo.processInfo.environment
        let candidates = [environment["ANDROID_HOME"], environment["ANDROID_SDK_ROOT"], NSHomeDirectory() + "/Library/Android/sdk"]
        return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0 + "/platform-tools") }
    }

    /// The adb executable: the SDK's, then one on a usual path.
    static func adbPath() throws -> String {
        let candidates = [sdkRoot().map { $0 + "/platform-tools/adb" }, "/opt/homebrew/bin/adb", "/usr/local/bin/adb"]
        guard let path = candidates.compactMap({ $0 }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw RPCError(
                code: RPCErrorCode.failed,
                message: "adb isn't installed. Install Android Studio (or the SDK platform tools) and set ANDROID_HOME if the SDK isn't in ~/Library/Android/sdk."
            )
        }
        return path
    }

    /// The emulator executable in the SDK.
    static func emulatorPath() throws -> String {
        guard let root = sdkRoot(), FileManager.default.isExecutableFile(atPath: root + "/emulator/emulator") else {
            throw RPCError(code: RPCErrorCode.failed, message: "The Android emulator isn't installed in the SDK; install it with Android Studio's SDK Manager.")
        }
        return root + "/emulator/emulator"
    }

    /// Runs adb (for one device when `serial` is given) and returns what it printed, failing with
    /// adb's own message when it exits with an error.
    @discardableResult
    public static func run(_ arguments: [String], serial: String? = nil, input: Data? = nil, timeout: TimeInterval = 60) async throws -> ToolRunner.Output {
        let full = (serial.map { ["-s", $0] } ?? []) + arguments
        let output = try await ToolRunner.run(try adbPath(), full, input: input, timeout: timeout, missing: "Is the Android SDK installed?")
        guard output.status == 0 else {
            let message = (output.stderr.isEmpty ? output.text : output.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            throw RPCError(code: RPCErrorCode.failed, message: "adb \(arguments.prefix(2).joined(separator: " ")) failed: \(message)")
        }
        return output
    }

    /// Runs a shell command on the device and returns its output.
    @discardableResult
    public static func shell(_ serial: String, _ command: String, timeout: TimeInterval = 60) async throws -> String {
        try await run(["shell", command], serial: serial, timeout: timeout).text
    }

    /// Every device adb sees, plus (unless `includeStopped` is false) the emulators that aren't running.
    public static func devices(includeStopped: Bool = true) async throws -> [AndroidDeviceInfo] {
        let listed = AndroidCatalog.parseDevices(try await run(["devices", "-l"], timeout: 30).text)
        var devices: [AndroidDeviceInfo] = []
        for var device in listed {
            if device.isRunning {
                let names = try? await shell(device.serial, "getprop ro.boot.qemu.avd_name; getprop ro.product.model", timeout: 15)
                let lines = (names ?? "").split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
                if device.isEmulator, let avd = lines.first, !avd.isEmpty {
                    device.name = avd
                } else if let model = lines.last, !model.isEmpty {
                    device.name = model
                }
            }
            devices.append(device)
        }
        if includeStopped, let emulator = try? emulatorPath(), let output = try? await ToolRunner.run(emulator, ["-list-avds"], timeout: 30) {
            let running = Set(devices.filter(\.isEmulator).map(\.name))
            for name in output.text.split(whereSeparator: \.isNewline).map(String.init)
            where !name.isEmpty && !name.hasPrefix("INFO") && !running.contains(name) {
                devices.append(AndroidDeviceInfo(serial: "", name: name, kind: "emulator", state: "stopped"))
            }
        }
        return devices.sorted { a, b in
            if a.isRunning != b.isRunning { return a.isRunning }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var known: [String: (device: AndroidDeviceInfo, read: Date)] = [:]

    /// The device a query names, with its Android version and screen. `includeStopped` also
    /// looks among emulators that aren't running.
    public static func device(_ query: String, includeStopped: Bool = true) async throws -> AndroidDeviceInfo {
        var device = try AndroidCatalog.pick(query, from: try await devices(includeStopped: includeStopped))
        guard device.isRunning else { return device }
        if let cached = cacheLock.withLock({ known[device.serial] }), Date().timeIntervalSince(cached.read) < 8,
           cached.device.name == device.name {
            return cached.device
        }
        let details = try await shell(
            device.serial, "getprop ro.build.version.release; getprop ro.build.version.sdk; wm size; wm density; dumpsys window displays | grep -m1 ' cur='",
            timeout: 20
        )
        let lines = details.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        if lines.count >= 2 {
            device.androidVersion = lines[0]
            device.apiLevel = Int(lines[1])
        }
        if let size = (lines.first { $0.hasPrefix("Override size:") } ?? lines.first { $0.hasPrefix("Physical size:") })?
            .split(separator: ":").last?.trimmingCharacters(in: .whitespaces).split(separator: "x"),
           size.count == 2, let width = Double(size[0]), let height = Double(size[1]) {
            device.screen = Size(width: width, height: height)
        }
        if let density = (lines.first { $0.hasPrefix("Override density:") } ?? lines.first { $0.hasPrefix("Physical density:") })?
            .split(separator: ":").last.flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }) {
            device.density = density
        }
        if let current = lines.joined(separator: " ").split(separator: " ").first(where: { $0.hasPrefix("cur=") })?
            .dropFirst(4).split(separator: "x"), current.count == 2, let width = Double(current[0]), let height = Double(current[1]) {
            device.screen = Size(width: width, height: height)
        }
        let read = device
        let now = Date()
        cacheLock.withLock { known[read.serial] = (device: read, read: now) }
        return device
    }

    /// Forgets what's known about a device's screen, after it turns.
    static func forget(_ serial: String) {
        _ = cacheLock.withLock { known.removeValue(forKey: serial) }
    }

    /// The running device a query names, failing when it isn't running.
    public static func runningDevice(_ query: String) async throws -> AndroidDeviceInfo {
        let device = try await device(query, includeStopped: false)
        guard device.isRunning else {
            let hint = device.state == "stopped"
                ? "Start it with `macos-harness android boot \"\(device.name)\"`."
                : device.state == "unauthorized" ? "Allow USB debugging on the phone." : "Reconnect it."
            throw RPCError(code: RPCErrorCode.failed, message: "\(device.name) isn't running (\(device.state)). \(hint)")
        }
        return device
    }
}
