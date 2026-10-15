import CoreGraphics
import Foundation
import HarnessProtocol

/// Whether the user's session is locked, when macOS shows no app windows and takes no input.
public enum ScreenLock {
    /// Whether the screen is locked or the session isn't the one on the console.
    public static var isLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return isLocked(session)
    }

    /// Whether a session dictionary, as `CGSessionCopyCurrentDictionary` gives it, is locked.
    static func isLocked(_ session: [String: Any]) -> Bool {
        if (session["CGSSessionScreenIsLocked"] as? Bool) == true { return true }
        return (session[kCGSessionOnConsoleKey as String] as? Bool) == false
    }

    static let message = "The screen is locked, so macOS shows no app windows and takes no input; unlock it to go on."

    /// Throws when the screen is locked.
    static func check() throws {
        if isLocked { throw RPCError(code: RPCErrorCode.failed, message: message) }
    }
}
