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

    /// Waits for the user to pause typing before a menu bar extra named `name` opens; throws if
    /// they keep at it.
    static func guardMenuOpening(_ name: String) async throws {
        guard await waitForTypingPause() else {
            throw RPCError(
                code: RPCErrorCode.failed,
                message: "The user is typing, so “\(name)” wasn't opened (its menu would take their keystrokes). Try again in a moment."
            )
        }
    }

    /// Whether the user pressed a key after `since`.
    static func typed(since: Date) -> Bool {
        secondsSinceTyping() < Date().timeIntervalSince(since)
    }

    /// A warning if the user typed after `since`, while an agent had moved focus.
    static func typedSince(_ since: Date, appName: String) -> Notice? {
        guard typed(since: since) else { return nil }
        return Notice(
            kind: "userTyped",
            message: "The user typed while \(appName) was in front; some keystrokes may have landed in it. Check before continuing."
        )
    }
}
