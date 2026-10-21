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
}
