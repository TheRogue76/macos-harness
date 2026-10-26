import Foundation
import HarnessProtocol

/// Records an Android screen with `screenrecord` on the device, which stops by itself after
/// three minutes; the file is copied back when the recording finishes.
public final class AndroidRecording: @unchecked Sendable {
    let process: Process
    let remote: String
    let serial: String
    public let deviceName: String
    /// How long it runs at most, in seconds.
    public let seconds: Int

    init(process: Process, remote: String, serial: String, deviceName: String, seconds: Int) {
        self.process = process
        self.remote = remote
        self.serial = serial
        self.deviceName = deviceName
        self.seconds = seconds
    }

    public var pid: Int32 { process.processIdentifier }

    /// Starts recording a device to `path`, which is replaced.
    public static func start(_ query: String, path: String, maxSeconds: Double) async throws -> AndroidRecording {
        let device = try await ADB.runningDevice(query)
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let remote = "/sdcard/macos-harness-\(UUID().uuidString.prefix(8)).mp4"
        let seconds = Int(min(max(maxSeconds, 1), 180))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try ADB.adbPath())
        process.arguments = ["-s", device.serial, "shell", "screenrecord", "--time-limit", "\(seconds)", remote]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        try await Task.sleep(for: .milliseconds(500))
        guard process.isRunning else {
            throw RPCError(code: RPCErrorCode.failed, message: "screenrecord couldn't start on \(device.name).")
        }
        return AndroidRecording(process: process, remote: remote, serial: device.serial, deviceName: device.name, seconds: seconds)
    }

    /// Stops recording and copies the file back to `path`.
    public func finish(to path: String) async {
        if process.isRunning { _ = try? await ADB.shell(serial, "pkill -INT screenrecord", timeout: 10) }
        let deadline = Date().addingTimeInterval(15)
        while process.isRunning, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(200))
        }
        if process.isRunning { process.terminate() }
        try? await Task.sleep(for: .milliseconds(500))
        _ = try? await ADB.run(["pull", remote, path], serial: serial, timeout: 120)
        _ = try? await ADB.shell(serial, "rm -f \(remote)", timeout: 10)
    }
}
