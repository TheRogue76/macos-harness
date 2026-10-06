import CoreGraphics
import Foundation
import HarnessProtocol

/// The user's own keyboard and mouse use.
public enum UserActivity {
    /// Seconds since a physical key press (synthetic events don't count).
    public static func secondsSinceTyping() -> Double {
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown)
    }

    /// Waits until the user has paused typing for `quiet` seconds. Returns false if they
    /// were still typing when `timeout` ran out.
    public static func waitForTypingPause(quiet: Double = 1.5, timeout: Double = 8) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while secondsSinceTyping() < quiet {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return true
    }

    /// Takes focus for `app` only once the user isn't typing; throws if they keep at it.
    static func guardFocusChange(for appName: String) async throws {
        guard await waitForTypingPause() else {
            throw RPCError(
                code: RPCErrorCode.failed,
                message: "The user is typing, so \(appName) wasn't brought to the front (their keystrokes would land in it). Try again in a moment."
            )
        }
    }

    /// A warning if the user typed after `since`, while an agent had moved focus.
    static func typedSince(_ since: Date, appName: String) -> Notice? {
        let elapsed = Date().timeIntervalSince(since)
        guard secondsSinceTyping() < elapsed else { return nil }
        return Notice(
            kind: "userTyped",
            message: "The user typed while \(appName) was in front; some keystrokes may have landed in it. Check before continuing."
        )
    }
}
