#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import HarnessCore
import HarnessImaging
import HarnessProtocol
import HarnessWayland

/// A window as the compositor places it, in layout points.
struct CompositorWindow: Sendable, Equatable {
    var pid: Int32?
    var title: String
    var appID: String?
    var frame: CGRect
    var focused: Bool
    var visible: Bool
    var output: String?
}

/// What a Wayland compositor tells the harness that apps can't: where windows are, and their
/// pixels. One implementation per compositor family.
protocol Compositor: Sendable {
    var name: String { get }
    func windows() async throws -> [CompositorWindow]
    /// The window's pixels as a PNG, and how many pixels make a point.
    func capture(_ window: CompositorWindow) async throws -> (png: Data, scale: Double)
}

enum Compositors {
    /// The compositor this session runs, when the harness knows how to ask it.
    static func current(environment: [String: String] = ProcessInfo.processInfo.environment) -> (any Compositor)? {
        if let socket = SwayIPC.socketPath(environment: environment), FileManager.default.fileExists(atPath: socket) {
            return SwayCompositor(socket: socket)
        }
        return nil
    }

    /// The compositor window an AT-SPI window is: the app's only window, or the one with its
    /// title.
    static func match(_ windows: [CompositorWindow], pid: Int32?, title: String) -> CompositorWindow? {
        let mine = windows.filter { pid != nil && $0.pid == pid }
        if mine.count == 1 { return mine[0] }
        return mine.first { $0.title == title } ?? mine.first { $0.focused }
    }
}

/// Sway and other wlroots compositors that speak its IPC: windows from the IPC tree, pixels
/// through wlr-screencopy.
struct SwayCompositor: Compositor {
    let socket: String

    var name: String { "Sway" }

    func windows() async throws -> [CompositorWindow] {
        try SwayIPC.windows(socket: socket).map { window in
            CompositorWindow(
                pid: window.pid, title: window.title, appID: window.appID,
                frame: CGRect(x: window.x, y: window.y, width: window.width, height: window.height),
                focused: window.focused, visible: window.visible, output: window.output
            )
        }
    }

    func capture(_ window: CompositorWindow) async throws -> (png: Data, scale: Double) {
        let outputs = try SwayIPC.outputs(socket: socket)
        guard let layout = outputs.first(where: { $0.name == window.output }) ?? outputs.first(where: { output in
            CGRect(x: output.x, y: output.y, width: output.width, height: output.height).contains(CGPoint(x: window.frame.midX, y: window.frame.midY))
        }) else {
            throw RPCError(code: RPCErrorCode.failed, message: "Sway shows the window on no output it lists.")
        }
        let connection = try WaylandConnection.connect()
        defer { connection.close() }
        let capture = try await WaylandCapture.make(on: connection)
        guard let output = capture.outputs.first(where: { $0.name == layout.name }) ?? capture.outputs.first else {
            throw RPCError(code: RPCErrorCode.failed, message: "The compositor offers no output to capture.")
        }
        let image = try await capture.capture(output)
        let scale = Double(image.width) / max(layout.width, 1)
        let bitmap = Bitmap(width: image.width, height: image.height, pixels: image.rgba)
        let x = Int(((window.frame.minX - layout.x) * scale).rounded()), y = Int(((window.frame.minY - layout.y) * scale).rounded())
        guard let cropped = bitmap.cropped(
            x: x, y: y, width: Int((window.frame.width * scale).rounded()), height: Int((window.frame.height * scale).rounded())
        ) else {
            throw RPCError(code: RPCErrorCode.failed, message: "The window is outside its output, so there's nothing to capture.")
        }
        return (PNG.encode(cropped), scale)
    }
}
