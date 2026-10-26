#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import HarnessCore
import HarnessDBus
import HarnessProtocol
import Synchronization

/// KDE: windows from KWin scripts, which report back over D-Bus; the screen from the Screenshot
/// portal and real input through the RemoteDesktop portal, as on GNOME.
struct KWinCompositor: Compositor {
    var name: String { "KDE" }

    /// Whether KWin is running on the session bus.
    static func available(on connection: DBusConnection) async -> Bool {
        let owner = try? await connection.call(
            "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "NameHasOwner", [.string("org.kde.KWin")]
        ).first?.bool
        return owner == true
    }

    /// The script that lists windows and the screen's size.
    static let listing = """
        const shown = workspace.windowList().filter(w => w.normalWindow || w.dialog || w.utility);
        const screen = workspace.virtualScreenGeometry;
        reply({
            width: screen.width, height: screen.height,
            windows: shown.map(w => ({
                id: w.internalId.toString(), pid: w.pid, title: w.caption, appId: w.desktopFileName || w.resourceClass,
                x: w.clientGeometry.x, y: w.clientGeometry.y, width: w.clientGeometry.width, height: w.clientGeometry.height,
                focused: w.active, minimized: w.minimized, output: w.output ? w.output.name : null,
            })),
        });
        """

    func layout() async throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(try await KWinScripts.shared.run(Self.listing).utf8)) as? [String: Any] ?? [:]
    }

    func windows() async throws -> [CompositorWindow] {
        Self.windows(from: try await layout())
    }

    static func windows(from layout: [String: Any]) -> [CompositorWindow] {
        (layout["windows"] as? [[String: Any]] ?? []).map { window in
            func number(_ key: String) -> Double { (window[key] as? NSNumber)?.doubleValue ?? 0 }
            let key = window["id"] as? String ?? ""
            return CompositorWindow(
                id: id(for: key), pid: (window["pid"] as? NSNumber).map { Int32(truncating: $0) }, title: window["title"] as? String ?? "",
                appID: window["appId"] as? String,
                frame: CGRect(x: number("x"), y: number("y"), width: number("width"), height: number("height")),
                focused: window["focused"] as? Bool ?? false, visible: !(window["minimized"] as? Bool ?? false),
                output: window["output"] as? String, key: key
            )
        }
    }

    /// A number for KWin's window UUID that stays the same while the window lives.
    static func id(for key: String) -> Int {
        var hash: UInt32 = 2_166_136_261
        for byte in key.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return Int(hash & 0x7FFF_FFFF)
    }

    func activate(_ window: CompositorWindow) async throws {
        let key = (window.key ?? "").replacingOccurrences(of: "\"", with: "")
        let source = """
            const window = workspace.windowList().find(w => w.internalId.toString() === "\(key)");
            if (window) { workspace.activeWindow = window; }
            reply(Boolean(window));
            """
        guard try await KWinScripts.shared.run(source) == "true" else {
            throw RPCError(code: RPCErrorCode.failed, message: "KWin didn't bring the window to the front.")
        }
        try await Task.sleep(for: .milliseconds(120))
    }

    func capture(_ window: CompositorWindow) async throws -> (png: Data, scale: Double) {
        let stageWidth = (try await layout()["width"] as? NSNumber)?.doubleValue ?? 0
        let connection = try await SessionBus.shared.connection()
        let data: Data
        do {
            data = try await GnomeCompositor.screenshot(on: connection)
        } catch let error as RPCError where error.code == RPCErrorCode.permissionMissing {
            throw await LinuxPermissions.missing(
                "screenshots", "KDE didn't allow the screenshot. Run `macos-harness permissions grant screenshots` and allow it."
            )
        }
        return try GnomeCompositor.crop(data, to: window, stageWidth: stageWidth)
    }

    func input() async throws -> any RealInput {
        do {
            return try await PortalInputSessions.shared.input()
        } catch let error as RPCError where error.code == RPCErrorCode.permissionMissing {
            throw await LinuxPermissions.missing(
                "input", "KDE didn't allow remote control. Run `macos-harness permissions grant input` and allow it."
            )
        }
    }
}

/// Runs short scripts in KWin. A script can't return a value, so each one calls back into the
/// helper over D-Bus with `reply(value)`, which arrives as JSON.
actor KWinScripts {
    static let shared = KWinScripts()
    static let path = "/io/github/therogue76/MacosHarness/KWin"
    static let interface = "io.github.therogue76.MacosHarness.KWin"

    /// Scripts waiting for their reply, by token.
    final class Waiting: Sendable {
        let byToken = Mutex<[String: CheckedContinuation<String, any Error>]>([:])

        func take(_ token: String) -> CheckedContinuation<String, any Error>? {
            byToken.withLock { $0.removeValue(forKey: token) }
        }
    }

    private let waiting = Waiting()
    private var exported: DBusConnection?

    func run(_ body: String, timeout: Duration = .seconds(5)) async throws -> String {
        let connection = try await SessionBus.shared.connection()
        if exported !== connection {
            let waiting = waiting
            connection.export(Self.path) { message in
                guard message.member == "Reply", message.body.count == 2, let token = message.body[0].string, let value = message.body[1].string else {
                    return nil
                }
                waiting.take(token)?.resume(returning: value)
                return []
            }
            exported = connection
        }
        guard let unique = connection.uniqueName else { throw DBusError.closed }
        let token = "harness\(UInt32.random(in: 0...UInt32.max))"
        let source = """
            function reply(value) {
                callDBus("\(unique)", "\(Self.path)", "\(Self.interface)", "Reply", "\(token)", JSON.stringify(value));
            }
            \(body)
            """
        let runtime = ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"].flatMap { $0.isEmpty ? nil : $0 } ?? NSTemporaryDirectory()
        let folder = "\(runtime)/macos-harness/kwin-scripts"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = "\(folder)/\(token).js"
        try Data(source.utf8).write(to: URL(fileURLWithPath: file))
        defer { try? FileManager.default.removeItem(atPath: file) }
        let kwin = (name: "org.kde.KWin", scripting: "org.kde.kwin.Scripting")
        guard let id = try await connection.call(kwin.name, "/Scripting", kwin.scripting, "loadScript", [.string(file), .string(token)]).first?.int,
              id >= 0 else {
            throw RPCError(code: RPCErrorCode.failed, message: "KWin didn't load the harness's script.")
        }
        defer { Task { _ = try? await connection.call(kwin.name, "/Scripting", kwin.scripting, "unloadScript", [.string(token)]) } }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, any Error>) in
            waiting.byToken.withLock { $0[token] = continuation }
            let waiting = waiting
            Task {
                do {
                    _ = try await connection.call(kwin.name, "/Scripting/Script\(id)", "org.kde.kwin.Script", "run")
                } catch {
                    waiting.take(token)?.resume(throwing: error)
                    return
                }
                try? await Task.sleep(for: timeout)
                waiting.take(token)?.resume(
                    throwing: RPCError(code: RPCErrorCode.failed, message: "KWin's script didn't answer.")
                )
            }
        }
    }
}
