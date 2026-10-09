import Foundation
import HarnessProtocol

/// Runs a command-line tool to the end and collects what it printed.
public enum ToolRunner {
    /// What a finished command printed.
    public struct Output: Sendable {
        public var status: Int32
        public var stdout: Data
        public var stderr: String

        public var text: String { String(decoding: stdout, as: UTF8.self) }
    }

    /// Runs `executable` with the arguments, ending it after `timeout` seconds. `missing` is added
    /// to the error when the tool can't be started.
    public static func run(
        _ executable: String, _ arguments: [String], input: Data? = nil, environment: [String: String] = [:],
        timeout: TimeInterval, missing: String = ""
    ) async throws -> Output {
        let name = (executable as NSString).lastPathComponent
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
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
                    continuation.resume(throwing: RPCError(code: RPCErrorCode.failed, message: "Couldn't run \(name): \(error.localizedDescription). \(missing)"))
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
                        message: "\(name) \(arguments.prefix(2).joined(separator: " ")) didn't finish within \(Int(timeout)) s."
                    ))
                    return
                }
                continuation.resume(returning: Output(
                    status: process.terminationStatus, stdout: outData, stderr: String(decoding: errData, as: UTF8.self)
                ))
            }
        }
    }
}
