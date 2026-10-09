import Foundation
import HarnessProtocol

/// Runs `xcrun simctl` and reads what it reports about simulators.
public enum Simctl {
    /// What a finished command printed.
    public struct Output: Sendable {
        public var status: Int32
        public var stdout: Data
        public var stderr: String

        public var text: String { String(decoding: stdout, as: UTF8.self) }
    }

    /// Runs `xcrun simctl <arguments>` and returns what it printed, failing with simctl's own
    /// message when it exits with an error.
    @discardableResult
    public static func run(
        _ arguments: [String], input: Data? = nil, environment: [String: String] = [:], timeout: TimeInterval = 120
    ) async throws -> String {
        try await runData(arguments, input: input, environment: environment, timeout: timeout).text
    }

    /// Like `run`, returning the raw output.
    public static func runData(
        _ arguments: [String], input: Data? = nil, environment: [String: String] = [:], timeout: TimeInterval = 120
    ) async throws -> Output {
        let output = try await xcrun(["simctl"] + arguments, input: input, environment: environment, timeout: timeout)
        guard output.status == 0 else {
            let message = (output.stderr.isEmpty ? output.text : output.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            throw RPCError(code: RPCErrorCode.failed, message: "simctl \(arguments.first ?? "") failed: \(message)")
        }
        return output
    }

    /// Runs `xcrun` with the arguments, ending it after `timeout` seconds.
    public static func xcrun(
        _ arguments: [String], input: Data? = nil, environment: [String: String] = [:], timeout: TimeInterval
    ) async throws -> Output {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
                process.arguments = arguments
                if !environment.isEmpty {
                    process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
                }
                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr
                let stdin = input.map { _ in Pipe() }
                if let stdin { process.standardInput = stdin } else { process.standardInput = FileHandle.nullDevice }
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: RPCError(code: RPCErrorCode.failed, message: "Couldn't run xcrun: \(error.localizedDescription). Is Xcode installed?"))
                    return
                }
                if let stdin, let input {
                    stdin.fileHandleForWriting.write(input)
                    try? stdin.fileHandleForWriting.close()
                }
                let reads = DispatchGroup()
                var outData = Data()
                var errData = Data()
                reads.enter()
                DispatchQueue.global().async {
                    outData = stdout.fileHandleForReading.readDataToEndOfFile()
                    reads.leave()
                }
                reads.enter()
                DispatchQueue.global().async {
                    errData = stderr.fileHandleForReading.readDataToEndOfFile()
                    reads.leave()
                }
                let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
                process.waitUntilExit()
                timer.cancel()
                reads.wait()
                if process.terminationReason == .uncaughtSignal, process.terminationStatus == SIGTERM {
                    continuation.resume(throwing: RPCError(
                        code: RPCErrorCode.failed,
                        message: "xcrun \(arguments.prefix(2).joined(separator: " ")) didn't finish within \(Int(timeout)) s."
                    ))
                    return
                }
                continuation.resume(returning: Output(
                    status: process.terminationStatus, stdout: outData, stderr: String(decoding: errData, as: UTF8.self)
                ))
            }
        }
    }

    /// Every available simulator, booted ones first, then by OS version (newest first) and name.
    public static func devices() async throws -> [SimulatorInfo] {
        let data = try await runData(["list", "devices", "available", "--json"]).stdout
        let types = (try? await deviceTypes()) ?? [:]
        return try SimulatorCatalog.parseDevices(data, deviceTypeNames: types.mapValues(\.name))
    }

    /// The simulator a query names: a UDID, a device name, or `booted` for the only booted one.
    public static func device(_ query: String) async throws -> SimulatorInfo {
        let all = try await devices()
        var device = try SimulatorCatalog.pick(query, from: all)
        if let identifier = device.deviceType, let type = (try? await deviceTypes())?.values.first(where: { $0.name == identifier }) {
            if let screen = screen(ofDeviceTypeAt: type.bundlePath) {
                device.screen = Size(width: screen.width, height: screen.height)
                device.screenScale = screen.scale
            }
        }
        return device
    }

    /// A simulator device type: its name and where its profile lives.
    public struct DeviceType: Sendable {
        public var name: String
        public var bundlePath: String
    }

    nonisolated(unsafe) private static var cachedTypes: [String: DeviceType]?
    private static let cacheLock = NSLock()

    /// Device types by identifier.
    static func deviceTypes() async throws -> [String: DeviceType] {
        if let cached = cacheLock.withLock({ cachedTypes }) { return cached }
        struct Listing: Decodable {
            struct DeviceType: Decodable {
                var identifier: String
                var name: String
                var bundlePath: String
            }
            var devicetypes: [DeviceType]
        }
        let data = try await runData(["list", "devicetypes", "--json"]).stdout
        let listing = try JSONDecoder().decode(Listing.self, from: data)
        let types = Dictionary(listing.devicetypes.map { ($0.identifier, DeviceType(name: $0.name, bundlePath: $0.bundlePath)) }, uniquingKeysWith: { a, _ in a })
        cacheLock.withLock { cachedTypes = types }
        return types
    }

    /// The main screen of a device type in points, from its profile's capabilities.
    static func screen(ofDeviceTypeAt bundlePath: String) -> (width: Double, height: Double, scale: Double)? {
        let url = URL(fileURLWithPath: bundlePath).appendingPathComponent("Contents/Resources/capabilities.plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let capabilities = plist["capabilities"] as? [String: Any],
              let dimensions = capabilities["ScreenDimensionsCapability"] as? [String: Any],
              let width = (dimensions["main-screen-width"] as? NSNumber)?.doubleValue,
              let height = (dimensions["main-screen-height"] as? NSNumber)?.doubleValue,
              let scale = (dimensions["main-screen-scale"] as? NSNumber)?.doubleValue, scale > 0
        else { return nil }
        return (width / scale, height / scale, scale)
    }
}
