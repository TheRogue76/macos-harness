import Foundation

/// Runs another program to completion and hands back what it printed, for `setup`'s steps.
public enum CommandRunner {
    /// Why a command failed: what it printed, or that it ran too long.
    public struct Failure: Error, CustomStringConvertible {
        public var description: String
    }

    /// Runs `program` with no terminal to read from and returns its output, stdout and stderr
    /// together; throws when it exits with an error or runs longer than `timeout` seconds, in
    /// which case it's stopped.
    @discardableResult
    public static func run(_ program: String, _ arguments: [String], timeout: TimeInterval = 60) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: program)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let collected = Collected()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                collected.append(data)
            }
        }
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        guard let status = exitStatus(of: process, finished: finished, timeout: timeout) else {
            process.terminate()
            pipe.fileHandleForReading.readabilityHandler = nil
            throw Failure(description: "it didn't finish within \(Int(timeout)) s, so it was stopped; run the command yourself in a terminal")
        }
        Thread.sleep(forTimeInterval: 0.1)
        pipe.fileHandleForReading.readabilityHandler = nil
        let text = collected.text
        guard status == 0 else {
            let printed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure(description: printed.isEmpty ? "it exited with status \(status)" : printed)
        }
        return text
    }

    /// Waits up to `timeout` seconds for `process` itself to exit and returns its status, or nil if
    /// it is still running, without waiting for programs it left running in the background.
    static func exitStatus(of process: Process, finished: DispatchSemaphore, timeout: TimeInterval) -> Int32? {
        #if os(Linux)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if finished.wait(timeout: .now()) == .success { return process.terminationStatus }
            if let status = exitedStatus(pid: process.processIdentifier) { return status }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return nil
        #else
        guard finished.wait(timeout: .now() + timeout) == .success else { return nil }
        return process.terminationStatus
        #endif
    }

    /// The exit code, or the signal that ended it, of a process that has exited but not been reaped,
    /// read from `/proc/<pid>/stat`; nil while it runs or once it's gone.
    static func exitedStatus(pid: Int32, procRoot: String = "/proc") -> Int32? {
        guard let stat = try? String(contentsOfFile: "\(procRoot)/\(pid)/stat", encoding: .utf8),
              let commandEnd = stat.lastIndex(of: ")") else { return nil }
        let fields = stat[stat.index(after: commandEnd)...].split(whereSeparator: \.isWhitespace)
        guard fields.count > 49, fields[0] == "Z", let raw = Int32(fields[49]) else { return nil }
        let signal = raw & 0x7F
        return signal == 0 ? (raw >> 8) & 0xFF : signal
    }

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ more: Data) {
            lock.withLock { data.append(more) }
        }

        var text: String {
            lock.withLock { String(decoding: data, as: UTF8.self) }
        }
    }
}
