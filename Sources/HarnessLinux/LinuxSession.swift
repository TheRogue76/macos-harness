import Foundation
import HarnessCore
import HarnessDBus
import HarnessProtocol
import HarnessWayland

/// The user's session on Linux: whether it's locked, and whether the user is using the mouse
/// and keyboard, so agents don't take focus from under them.
public actor LinuxSession {
    public static let shared = LinuxSession()

    /// How long the user must leave the input alone before an agent takes focus.
    static let quiet = Duration.milliseconds(1500)
    /// How soon after the harness's own input the desktop counts it as activity.
    static let ownInputWindow = Duration.milliseconds(500)

    private var idle: WaylandIdle?
    private var lastOwnInput: ContinuousClock.Instant?

    /// Notes that the harness is sending input, so the activity it causes isn't taken for the
    /// user's.
    public func noteOwnInput() {
        lastOwnInput = .now
    }

    /// Whether the session is locked: logind's hint, or the desktop's screensaver.
    public static func isLocked() async -> Bool {
        if let system = try? await DBusConnection.system() {
            defer { system.close() }
            let hint = try? await system.property(
                "org.freedesktop.login1", "/org/freedesktop/login1/session/auto", "org.freedesktop.login1.Session", "LockedHint"
            ).bool
            if hint == true { return true }
        }
        guard let session = try? await SessionBus.shared.connection() else { return false }
        for (name, path, interface) in [
            ("org.gnome.ScreenSaver", "/org/gnome/ScreenSaver", "org.gnome.ScreenSaver"),
            ("org.freedesktop.ScreenSaver", "/ScreenSaver", "org.freedesktop.ScreenSaver"),
        ] {
            if (try? await session.call(name, path, interface, "GetActive", timeout: .seconds(1)).first?.bool) == true { return true }
        }
        return false
    }

    static let lockedMessage = "The screen is locked, so apps take no input; unlock it to go on."

    /// Throws when the session is locked.
    public static func checkUnlocked() async throws {
        if await isLocked() { throw RPCError(code: RPCErrorCode.failed, message: lockedMessage) }
    }

    /// Whether the user has left the mouse and keyboard alone for `quiet`; nil when the desktop
    /// doesn't say.
    func userQuiet() async -> Bool? {
        if LinuxPermissions.Desktop.current() == .gnome {
            guard let session = try? await SessionBus.shared.connection(),
                  let milliseconds = try? await session.call(
                      "org.gnome.Mutter.IdleMonitor", "/org/gnome/Mutter/IdleMonitor/Core", "org.gnome.Mutter.IdleMonitor", "GetIdletime"
                  ).first?.int else { return nil }
            let idle = Duration.milliseconds(milliseconds)
            if idle >= Self.quiet { return true }
            guard let own = lastOwnInput else { return false }
            return idle + Self.ownInputWindow >= ContinuousClock.now - own
        }
        guard let watcher = await idleWatcher() else { return nil }
        let (isIdle, resumed) = watcher.status
        if isIdle { return true }
        guard let resumed, let own = lastOwnInput else { return false }
        return resumed >= own && resumed - own <= Self.ownInputWindow
    }

    private func idleWatcher() async -> WaylandIdle? {
        if let idle, !idle.isClosed { return idle }
        guard let connection = try? WaylandConnection.connect() else { return nil }
        let made = try? await WaylandIdle.make(on: connection, timeout: Self.quiet)
        if made == nil { connection.close() }
        idle = made
        return made
    }

    /// Waits until the user leaves the mouse and keyboard alone; false if they were still using
    /// them when `timeout` ran out. True at once when the desktop doesn't say.
    func waitForPause(timeout: Duration = .seconds(8)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while let quiet = await userQuiet(), !quiet {
            if ContinuousClock.now > deadline { return false }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return true
    }

    /// Takes focus for `appName` only once the user has paused; throws if they keep going.
    public func guardFocusChange(for appName: String) async throws {
        guard await waitForPause() else {
            throw RPCError(
                code: RPCErrorCode.failed,
                message: "The user is using the mouse or keyboard, so \(appName) wasn't brought to the front (their input would land in it). Try again in a moment."
            )
        }
    }
}
