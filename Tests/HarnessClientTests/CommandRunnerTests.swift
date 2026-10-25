import Foundation
@testable import HarnessClient
import Testing

struct CommandRunnerTests {
    @Test func returnsWhatTheCommandPrinted() throws {
        #expect(try CommandRunner.run("/bin/echo", ["hello"]) == "hello\n")
    }

    @Test func failuresSayWhatTheCommandPrintedOrItsStatus() {
        do {
            try CommandRunner.run("/bin/sh", ["-c", "echo oops >&2; exit 3"])
            Issue.record("expected a failure")
        } catch {
            #expect("\(error)" == "oops")
        }
        do {
            try CommandRunner.run("/usr/bin/false", [])
            Issue.record("expected a failure")
        } catch {
            #expect("\(error)" == "it exited with status 1")
        }
    }

    @Test func aCommandThatWaitsForInputGetsNone() throws {
        let started = Date()
        #expect(try CommandRunner.run("/bin/cat", []) == "")
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func aCommandThatRunsTooLongIsStopped() {
        let started = Date()
        do {
            try CommandRunner.run("/bin/sleep", ["10"], timeout: 0.5)
            Issue.record("expected a timeout")
        } catch {
            #expect("\(error)".contains("didn't finish within"))
        }
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func aBackgroundProcessHoldingTheOutputDoesntKeepItWaiting() throws {
        let started = Date()
        #expect(try CommandRunner.run("/bin/sh", ["-c", "sleep 5 & echo started"]) == "started\n")
        #expect(Date().timeIntervalSince(started) < 3)
    }

    @Test func exitedProcessesReportTheirStatusFromProc() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        func write(pid: Int32, state: String, raw: Int) throws {
            let folder = root.appendingPathComponent("\(pid)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let rest = ([state] + Array(repeating: "0", count: 48) + ["\(raw)"]).joined(separator: " ")
            try "\(pid) (a (strange) name) \(rest)\n".write(to: folder.appendingPathComponent("stat"), atomically: true, encoding: .utf8)
        }
        try write(pid: 10, state: "Z", raw: 3 << 8)
        try write(pid: 11, state: "Z", raw: 15)
        try write(pid: 12, state: "S", raw: 0)
        #expect(CommandRunner.exitedStatus(pid: 10, procRoot: root.path) == 3)
        #expect(CommandRunner.exitedStatus(pid: 11, procRoot: root.path) == 15)
        #expect(CommandRunner.exitedStatus(pid: 12, procRoot: root.path) == nil)
        #expect(CommandRunner.exitedStatus(pid: 13, procRoot: root.path) == nil)
    }
}
