#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import HarnessCore
import HarnessDBus
import HarnessImaging
import HarnessProtocol
import Synchronization

/// Calls to xdg-desktop-portal, whose methods answer later through a `Response` signal on a
/// request object.
enum Portal {
    static let destination = "org.freedesktop.portal.Desktop"
    static let path = "/org/freedesktop/portal/desktop"

    /// Calls a portal method whose last argument is an options dictionary, adding a request
    /// token, and returns the results of its response; throws when the user cancels or the
    /// portal fails. Some portals reply to the call itself only once the user has answered, so
    /// the call gets the whole timeout too.
    static func request(
        _ interface: String, _ method: String, _ arguments: [DBusValue], options: [String: DBusValue],
        on connection: DBusConnection, timeout: Duration = .seconds(60)
    ) async throws -> [String: DBusValue] {
        let token = "harness\(UInt32.random(in: 0...UInt32.max))"
        let sender = (connection.uniqueName ?? "").dropFirst().replacingOccurrences(of: ".", with: "_")
        let handle = "/org/freedesktop/portal/desktop/request/\(sender)/\(token)"
        let rule = "type='signal',interface='org.freedesktop.portal.Request',member='Response',path='\(handle)'"
        try await connection.addMatch(rule)
        let answer = Mutex<CheckedContinuation<[DBusValue], any Error>?>(nil)
        let handler = connection.onSignal { message in
            guard message.path == handle, message.member == "Response" else { return }
            answer.withLock { $0.take() }?.resume(returning: message.body)
        }
        var all = options
        all["handle_token"] = .string(token)
        let request = arguments + [.properties(all)]
        let reply = await Result { try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[DBusValue], any Error>) in
            answer.withLock { $0 = continuation }
            Task {
                do {
                    _ = try await connection.call(destination, path, interface, method, request, timeout: timeout)
                } catch {
                    answer.withLock { $0.take() }?.resume(throwing: error)
                    return
                }
                try? await Task.sleep(for: timeout)
                answer.withLock { $0.take() }?.resume(throwing: DBusError.timedOut)
            }
        } }
        connection.removeSignalHandler(handler)
        try? await connection.removeMatch(rule)
        let body = try reply.get()
        guard body.count == 2, let code = body[0].int else {
            throw RPCError(code: RPCErrorCode.failed, message: "The \(method) portal answered in a way the harness can't read.")
        }
        switch code {
        case 0: return body[1].dictionary ?? [:]
        case 1: throw RPCError(code: RPCErrorCode.permissionMissing, message: "The \(method) request was cancelled; allow it when the desktop asks.")
        default: throw RPCError(code: RPCErrorCode.failed, message: "The \(method) portal failed.")
        }
    }
}

/// GNOME: windows from the harness's Shell extension, the screen from the Screenshot portal, and
/// real input through the RemoteDesktop portal (`PortalInput`).
struct GnomeCompositor: Compositor {
    static let busName = "org.gnome.Shell.Extensions.MacosHarness"
    static let objectPath = "/org/gnome/Shell/Extensions/MacosHarness"
    static let interface = "org.gnome.Shell.Extensions.MacosHarness"

    var name: String { "GNOME" }

    /// Whether the extension is running on the session bus.
    static func available(on connection: DBusConnection) async -> Bool {
        let owner = try? await connection.call(
            "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "NameHasOwner", [.string(busName)]
        ).first?.bool
        return owner == true
    }

    func call(_ method: String, _ arguments: [DBusValue] = []) async throws -> [DBusValue] {
        let connection = try await SessionBus.shared.connection()
        return try await connection.call(Self.busName, Self.objectPath, Self.interface, method, arguments)
    }

    func json(_ method: String) async throws -> Any {
        guard let text = try await call(method).first?.string else {
            throw RPCError(code: RPCErrorCode.failed, message: "The macOS Harness Shell extension sent nothing for \(method).")
        }
        return try JSONSerialization.jsonObject(with: Data(text.utf8))
    }

    func windows() async throws -> [CompositorWindow] {
        Self.windows(from: try await json("List"))
    }

    static func windows(from list: Any) -> [CompositorWindow] {
        (list as? [[String: Any]] ?? []).map { window in
            func number(_ key: String) -> Double { (window[key] as? NSNumber)?.doubleValue ?? 0 }
            return CompositorWindow(
                id: (window["id"] as? NSNumber)?.intValue ?? 0, pid: (window["pid"] as? NSNumber).map { Int32(truncating: $0) },
                title: window["title"] as? String ?? "", appID: window["appId"] as? String,
                frame: CGRect(x: number("x"), y: number("y"), width: number("width"), height: number("height")),
                focused: window["focused"] as? Bool ?? false, visible: !(window["minimized"] as? Bool ?? false),
                output: (window["monitor"] as? NSNumber).map { "\($0.intValue)" }
            )
        }
    }

    func activate(_ window: CompositorWindow) async throws {
        guard try await call("Activate", [.uint64(UInt64(window.id))]).first?.bool == true else {
            throw RPCError(code: RPCErrorCode.failed, message: "GNOME didn't bring the window to the front.")
        }
        try await Task.sleep(for: .milliseconds(120))
    }

    func capture(_ window: CompositorWindow) async throws -> (png: Data, scale: Double) {
        let layout = try await json("Layout") as? [String: Any] ?? [:]
        let stageWidth = (layout["width"] as? NSNumber)?.doubleValue ?? 0
        let connection = try await SessionBus.shared.connection()
        let data: Data
        do {
            data = try await Self.screenshot(on: connection)
        } catch let error as RPCError where error.code == RPCErrorCode.permissionMissing {
            throw await LinuxPermissions.missing(
                "screenshots", "GNOME didn't allow the screenshot. Run `macos-harness permissions grant screenshots` and choose Allow."
            )
        }
        return try Self.crop(data, to: window, stageWidth: stageWidth)
    }

    /// The part of a whole-screen PNG a window covers, given the screen's width in points.
    static func crop(_ data: Data, to window: CompositorWindow, stageWidth: Double) throws -> (png: Data, scale: Double) {
        let image = try PNG.decode(data)
        let scale = stageWidth > 0 ? Double(image.width) / stageWidth : 1
        guard let cropped = image.cropped(
            x: Int((window.frame.minX * scale).rounded()), y: Int((window.frame.minY * scale).rounded()),
            width: Int((window.frame.width * scale).rounded()), height: Int((window.frame.height * scale).rounded())
        ) else {
            throw RPCError(code: RPCErrorCode.failed, message: "The window is off the screen, so there's nothing to capture.")
        }
        return (PNG.encode(cropped), scale)
    }

    func place(_ window: CompositorWindow, near point: CGPoint) async throws {
        var anchor = point
        if anchor == .zero, let layout = try? await json("Layout") as? [String: Any] {
            anchor = CGPoint(x: (layout["width"] as? NSNumber)?.doubleValue ?? 0, y: 0)
        }
        _ = try await call("PlaceNear", [.uint64(UInt64(window.id)), .int32(Int32(anchor.x)), .int32(Int32(anchor.y))])
    }

    func input() async throws -> any RealInput {
        do {
            return try await PortalInputSessions.shared.input()
        } catch let error as RPCError where error.code == RPCErrorCode.permissionMissing {
            throw await LinuxPermissions.missing(
                "input",
                "GNOME didn't allow the mouse and keyboard. Run `macos-harness permissions grant input`, turn on Allow Remote Interaction and choose Share."
            )
        }
    }

    /// The whole screen as a PNG, from the Screenshot portal, which asks the user the first time.
    static func screenshot(on connection: DBusConnection, timeout: Duration = .seconds(60)) async throws -> Data {
        let results = try await Portal.request(
            "org.freedesktop.portal.Screenshot", "Screenshot", [.string("")], options: ["interactive": .boolean(false)], on: connection,
            timeout: timeout
        )
        guard let uri = results["uri"]?.string, let url = URL(string: uri), url.isFileURL else {
            throw RPCError(code: RPCErrorCode.failed, message: "The Screenshot portal gave no picture.")
        }
        let data = try Data(contentsOf: url)
        try? FileManager.default.removeItem(at: url)
        return data
    }
}
