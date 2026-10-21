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
        guard finished.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            pipe.fileHandleForReading.readabilityHandler = nil
            throw Failure(description: "it didn't finish within \(Int(timeout)) s, so it was stopped; run the command yourself in a terminal")
        }
        Thread.sleep(forTimeInterval: 0.1)
        pipe.fileHandleForReading.readabilityHandler = nil
        let text = collected.text
        guard process.terminationStatus == 0 else {
            let printed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure(description: printed.isEmpty ? "it exited with status \(process.terminationStatus)" : printed)
        }
        return text
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
