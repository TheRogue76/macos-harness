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
                frame: [w.frameGeometry.x, w.frameGeometry.y, w.frameGeometry.width, w.frameGeometry.height],
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
            let client = CGRect(x: number("x"), y: number("y"), width: number("width"), height: number("height"))
            let outer = (window["frame"] as? [NSNumber]).flatMap { values -> CGRect? in
                guard values.count == 4 else { return nil }
                let frame = CGRect(x: values[0].doubleValue, y: values[1].doubleValue, width: values[2].doubleValue, height: values[3].doubleValue)
                return frame == client ? nil : frame
            }
            return CompositorWindow(
                id: id(for: key), pid: (window["pid"] as? NSNumber).map { Int32(truncating: $0) }, title: window["title"] as? String ?? "",
                appID: window["appId"] as? String,
                frame: client,
                focused: window["focused"] as? Bool ?? false, visible: !(window["minimized"] as? Bool ?? false),
                output: window["output"] as? String, key: key, outer: outer, minimized: window["minimized"] as? Bool ?? false
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

    func arrange(_ window: CompositorWindow, _ change: WindowChange) async throws {
        let key = (window.key ?? "").replacingOccurrences(of: "\"", with: "")
        let body: String
        switch change {
        case .move(let point):
            body = """
                const frame = window.frameGeometry, client = window.clientGeometry;
                window.frameGeometry = {x: \(point.x) - (client.x - frame.x), y: \(point.y) - (client.y - frame.y), width: frame.width, height: frame.height};
                """
        case .resize(let size):
            body = """
                const frame = window.frameGeometry, client = window.clientGeometry;
                window.frameGeometry = {x: frame.x, y: frame.y, width: \(size.width) + frame.width - client.width, height: \(size.height) + frame.height - client.height};
                """
        case .minimize: body = "window.minimized = true;"
        case .restore: body = "window.minimized = false; workspace.activeWindow = window;"
        case .fullscreen(let on): body = "window.fullScreen = \(on);"
        case .close: body = "window.closeWindow();"
        }
        let source = """
            const window = workspace.windowList().find(w => w.internalId.toString() === "\(key)");
            if (window) {
                \(body)
            }
            reply(Boolean(window));
            """
        guard try await KWinScripts.shared.run(source) == "true" else {
            throw RPCError(code: RPCErrorCode.failed, message: "KWin no longer has that window.")
        }
    }

    func place(_ window: CompositorWindow, near point: CGPoint) async throws {
        let key = (window.key ?? "").replacingOccurrences(of: "\"", with: "")
        let source = """
            const window = workspace.windowList().find(w => w.internalId.toString() === "\(key)");
            if (window) {
                const area = workspace.clientArea(KWin.PlacementArea, window);
                const frame = window.frameGeometry;
                const anchorX = \(Int(point.x)) > 0 ? \(Int(point.x)) : area.x + area.width;
                const anchorY = \(Int(point.y));
                const x = Math.min(Math.max(anchorX - frame.width / 2, area.x + 8), area.x + area.width - frame.width - 8);
                const y = anchorY > area.y + area.height / 2 ? area.y + area.height - frame.height - 6 : area.y + 6;
                window.frameGeometry = {x: x, y: y, width: frame.width, height: frame.height};
            }
            reply(Boolean(window));
            """
        _ = try await KWinScripts.shared.run(source)
    }

    /// The script that keeps focus off the marker app's windows: loaded once, it stays in KWin
    /// and gives focus straight back to the window that had it whenever one of them takes it.
    static func focusGuard(appID: String) -> String {
        let quoted = appID.replacingOccurrences(of: "\"", with: "")
        return """
            const isMarker = w => w && (w.desktopFileName === "\(quoted)" || w.resourceClass === "\(quoted)");
            let last = isMarker(workspace.activeWindow) ? null : workspace.activeWindow;
            workspace.windowActivated.connect(w => {
                if (!w) { return; }
                if (isMarker(w)) {
                    if (last && last !== w && workspace.windowList().includes(last)) { workspace.activeWindow = last; }
                } else {
                    last = w;
                }
            });
            workspace.windowAdded.connect(w => {
                if (isMarker(w)) { w.skipTaskbar = true; w.skipSwitcher = true; w.skipPager = true; }
            });
            """
    }

    func prepareMarker(appID: String) async throws {
        try await KWinScripts.shared.keep(Self.focusGuard(appID: appID), name: "macos-harness-focus-guard-\(KWinCompositor.id(for: appID))")
    }

    /// Puts the marker round the target and directly above it in the stacking order: raised to
    /// the top, then every window that was above the target raised again in turn. The window
    /// that had focus gets it back, in case the marker took it when it appeared.
    func cover(_ target: CompositorWindow, with marker: CompositorWindow, frame: CGRect, focused: CompositorWindow?) async throws {
        func key(_ window: CompositorWindow?) -> String { (window?.key ?? "").replacingOccurrences(of: "\"", with: "") }
        let source = """
            const find = key => workspace.windowList().find(w => w.internalId.toString() === key);
            const marker = find("\(key(marker))"), target = find("\(key(target))"), focused = find("\(key(focused))");
            if (marker && target) {
                marker.skipTaskbar = true;
                marker.skipSwitcher = true;
                marker.skipPager = true;
                marker.desktops = target.desktops;
                marker.frameGeometry = {x: \(Int(frame.minX.rounded())), y: \(Int(frame.minY.rounded())), width: \(Int(frame.width.rounded())), height: \(Int(frame.height.rounded()))};
                const order = workspace.stackingOrder;
                const above = order.slice(order.indexOf(target) + 1).filter(w => w !== marker);
                workspace.raiseWindow(marker);
                for (const window of above) { workspace.raiseWindow(window); }
                if (focused && workspace.activeWindow === marker) { workspace.activeWindow = focused; }
            }
            reply(Boolean(marker && target));
            """
        guard try await KWinScripts.shared.run(source) == "true" else {
            throw RPCError(code: RPCErrorCode.failed, message: "KWin didn't put the marker in place.")
        }
    }

    func placeInCorner(_ window: CompositorWindow, focused: CompositorWindow?) async throws {
        func key(_ window: CompositorWindow?) -> String { (window?.key ?? "").replacingOccurrences(of: "\"", with: "") }
        let source = """
            const find = key => workspace.windowList().find(w => w.internalId.toString() === key);
            const panel = find("\(key(window))"), focused = find("\(key(focused))");
            if (panel) {
                const area = workspace.clientArea(KWin.PlacementArea, focused || panel);
                const frame = panel.frameGeometry;
                panel.skipTaskbar = true;
                panel.skipSwitcher = true;
                panel.skipPager = true;
                panel.onAllDesktops = true;
                panel.keepAbove = true;
                panel.frameGeometry = {x: area.x + area.width - frame.width - 24, y: area.y + area.height - frame.height - 24, width: frame.width, height: frame.height};
                if (focused && workspace.activeWindow === panel) { workspace.activeWindow = focused; }
            }
            reply(Boolean(panel));
            """
        _ = try await KWinScripts.shared.run(source)
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
        } catch let error as RPCError where error.code == RPCErrorCode.failed {
            throw RPCError(
                code: RPCErrorCode.failed,
                message: "KDE couldn't take the screenshot (\(error.message)). KWin takes screenshots only while it composites with OpenGL, so in a session it paints in software, such as a virtual machine without 3D acceleration, it can't."
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

    /// Loads a script that stays in KWin, unless one of that name is already loaded.
    func keep(_ source: String, name: String) async throws {
        let connection = try await SessionBus.shared.connection()
        let kwin = (name: "org.kde.KWin", scripting: "org.kde.kwin.Scripting")
        if try await connection.call(kwin.name, "/Scripting", kwin.scripting, "isScriptLoaded", [.string(name)]).first?.bool == true { return }
        let file = try write(source, named: name)
        defer { try? FileManager.default.removeItem(atPath: file) }
        guard let id = try await connection.call(kwin.name, "/Scripting", kwin.scripting, "loadScript", [.string(file), .string(name)]).first?.int,
              id >= 0 else {
            throw RPCError(code: RPCErrorCode.failed, message: "KWin didn't load the harness's script.")
        }
        _ = try await connection.call(kwin.name, "/Scripting/Script\(id)", "org.kde.kwin.Script", "run")
    }

    /// Writes a script where KWin can read it, in the harness's own runtime folder.
    private func write(_ source: String, named name: String) throws -> String {
        let runtime = ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"].flatMap { $0.isEmpty ? nil : $0 } ?? NSTemporaryDirectory()
        let folder = "\(runtime)/macos-harness/kwin-scripts"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = "\(folder)/\(name).js"
        try Data(source.utf8).write(to: URL(fileURLWithPath: file))
        return file
    }

    /// Runs a script and returns what it replied. Once in a while KWin's reply never comes, so a
    /// script that doesn't answer in half the time runs once more; every script the helper runs
    /// can safely run twice.
    func run(_ body: String, timeout: Duration = .seconds(5)) async throws -> String {
        do {
            return try await attempt(body, timeout: timeout / 2)
        } catch let error as RPCError where error.message == Self.silent {
            return try await attempt(body, timeout: timeout)
        }
    }

    static let silent = "KWin's script didn't answer."

    private func attempt(_ body: String, timeout: Duration) async throws -> String {
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
        let file = try write(source, named: token)
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
                    do {
                        _ = try await connection.call(kwin.name, "/Scripting", kwin.scripting, "start")
                    } catch {
                        waiting.take(token)?.resume(throwing: error)
                        return
                    }
                }
                try? await Task.sleep(for: timeout)
                waiting.take(token)?.resume(throwing: RPCError(code: RPCErrorCode.failed, message: Self.silent))
            }
        }
    }
}
