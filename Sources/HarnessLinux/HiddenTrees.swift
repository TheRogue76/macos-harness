import Foundation
import HarnessCore
import HarnessDBus
import HarnessProtocol
import Synchronization

/// Chromium, Chrome and Electron apps build their accessibility tree only when asked. On Linux
/// there's no per-app request, as macOS's `AXManualAccessibility` is: `launch` passes
/// `--force-renderer-accessibility`, and for an app already running without a tree, the helper
/// either says how to relaunch it or, when the user allowed it, turns AT-SPI's screen reader
/// flag on for a moment, which makes it build one that stays.
enum HiddenTrees {
    static let flag = "--force-renderer-accessibility"
    /// Set to 1 in the helper's environment to let it turn the screen reader flag on for a moment.
    static let allowGlobalVariable = "MACOS_HARNESS_GLOBAL_ACCESSIBILITY"
    /// Fewer elements than this in a Chromium window means its tree is off.
    static let threshold = 10

    private static let tried = Mutex<Set<Int32>>([])

    /// Whether a program is Chromium or Electron: a binary beside Chromium's resource files, or a
    /// launcher script that starts one.
    static func isChromium(executable: String) -> Bool {
        let path = (try? FileManager.default.destinationOfSymbolicLink(atPath: executable)).map { link in
            link.hasPrefix("/") ? link : ((executable as NSString).deletingLastPathComponent as NSString).appendingPathComponent(link)
        } ?? executable
        let directory = (path as NSString).deletingLastPathComponent
        let files = Set((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [])
        if files.contains("icudtl.dat"), files.contains("v8_context_snapshot.bin") || files.contains("snapshot_blob.bin") {
            return true
        }
        guard let handle = FileHandle(forReadingAtPath: path), let head = try? handle.read(upToCount: 65_536) else { return false }
        try? handle.close()
        guard head.starts(with: Array("#!".utf8)) else { return false }
        let text = String(decoding: head, as: UTF8.self).lowercased()
        return ["electron", "/chrome", "chromium"].contains { text.contains($0) }
    }

    /// Whether a running process is Chromium or Electron.
    static func isChromium(pid: Int32) -> Bool {
        guard let path = try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/\(pid)/exe") else { return false }
        return isChromium(executable: path)
    }

    /// The arguments a launch adds for an app, and the notice that says so.
    static func launchArguments(for executable: String, given: [String]) -> ([String], Notice?) {
        guard isChromium(executable: executable), !given.contains(flag) else { return ([], nil) }
        return ([flag], Notice(kind: "treeEnabled", message: "Started with \(flag), so its accessibility tree is on."))
    }

    /// Makes sure a Chromium app's window has its tree before it's read, returning the app's items
    /// read again when the tree came on, and a notice for the agent.
    static func prepare(
        _ app: ATSPIApp, window: ATSPIItem, items: [ATSPIItem], on connection: DBusConnection,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async -> (items: [ATSPIItem]?, notice: Notice?) {
        guard let pid = app.pid, ATSPITree.select(items, from: window.path, limit: threshold).count < threshold,
              isChromium(pid: pid) else { return (nil, nil) }
        let name = LinuxDesktop.displayName(app)
        let first = tried.withLock { $0.insert(pid).inserted }
        guard environment[allowGlobalVariable] == "1" else {
            return (nil, Notice(
                kind: "treeHidden",
                message: "\(name) builds its accessibility tree only when asked, and on Linux that's at launch: quit it and start it with `launch`, which adds \(flag). Or let the harness switch it on for apps already running by setting \(allowGlobalVariable)=1 for the helper; GNOME then announces \"Screen reader on\" and \"off\" each time."
            ))
        }
        guard first, let grown = await pulse(app, window: window, on: connection) else {
            return (nil, Notice(kind: "treeHidden", message: "\(name)'s accessibility tree didn't come on; quit it and start it with `launch`, which adds \(flag)."))
        }
        return (grown, Notice(
            kind: "treeEnabled",
            message: "Switched on \(name)'s accessibility tree by turning AT-SPI's screen reader flag on for a moment (GNOME announces it); it's off again."
        ))
    }

    /// Turns the screen reader flag on, waits up to 3 s for the window's tree to grow, and turns
    /// it off again unless it was already on. The tree stays once built.
    static func pulse(_ app: ATSPIApp, window: ATSPIItem, on connection: DBusConnection) async -> [ATSPIItem]? {
        guard let session = try? await SessionBus.shared.connection() else { return nil }
        let status = ("org.a11y.Bus", "/org/a11y/bus", "org.a11y.Status")
        let wasOn = (try? await session.property(status.0, status.1, status.2, "ScreenReaderEnabled"))?.bool ?? false
        func set(_ on: Bool) async {
            _ = try? await session.call(
                status.0, status.1, "org.freedesktop.DBus.Properties", "Set",
                [.string(status.2), .string("ScreenReaderEnabled"), .variant(.boolean(on))]
            )
        }
        if !wasOn { await set(true) }
        var grown: [ATSPIItem]?
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, grown == nil {
            try? await Task.sleep(for: .milliseconds(300))
            if let items = try? await ATSPI.items(of: app.bus, on: connection),
               ATSPITree.select(items, from: window.path, limit: threshold).count >= threshold {
                grown = items
            }
        }
        if !wasOn { await set(false) }
        return grown
    }
}
