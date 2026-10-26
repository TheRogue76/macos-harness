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
    /// The compositor's own ID for the window.
    var id: Int = 0
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
    /// Brings the window to the front and gives it focus.
    func activate(_ window: CompositorWindow) async throws
    /// Real input devices, until they're closed.
    func input() async throws -> any RealInput
}

/// The real mouse and keyboard, as virtual devices the compositor treats like the user's.
/// Positions are in layout points.
protocol RealInput: Sendable {
    func move(to point: CGPoint) async throws
    func button(_ button: UInt32, pressed: Bool) async throws
    func scroll(dx: Double, dy: Double) async throws
    /// Holds modifiers (XKB's masks) until set to 0.
    func hold(_ modifiers: UInt32) async throws
    func type(_ text: String) async throws
    /// Taps a key by XKB keysym name, holding modifiers.
    func tap(_ key: String, modifiers: UInt32) async throws
    /// Waits until the compositor has handled everything sent; events still in flight when the
    /// connection closes are lost.
    func flush() async throws
    /// Hands the devices back after a step. They stay a while, as a real pointer stays where it
    /// was left, so a hover holds and the next step needn't wait for new devices.
    func release() async
}

enum Compositors {
    /// The compositor this session runs, when the harness knows how to ask it.
    static func current(environment: [String: String] = ProcessInfo.processInfo.environment) async -> (any Compositor)? {
        if let socket = SwayIPC.socketPath(environment: environment), FileManager.default.fileExists(atPath: socket) {
            return SwayCompositor(socket: socket)
        }
        if let session = try? await SessionBus.shared.connection(), await GnomeCompositor.available(on: session) {
            return GnomeCompositor()
        }
        return nil
    }

    /// The compositor, or why the harness can't ask it for windows, pixels or input.
    static func required(for command: String) async throws -> any Compositor {
        if let compositor = await current() { return compositor }
        if LinuxPermissions.Desktop.current() == .gnome {
            throw await LinuxPermissions.missing(
                "windows",
                "`\(command)` on GNOME needs the macOS Harness extension, which isn't running. Run `macos-harness permissions grant windows`."
            )
        }
        throw RPCError(
            code: RPCErrorCode.failed,
            message: "`\(command)` needs a compositor the harness can ask for windows, pixels and input; so far that's GNOME, Sway and other wlroots compositors."
        )
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
                id: window.id, pid: window.pid, title: window.title, appID: window.appID,
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

    func activate(_ window: CompositorWindow) async throws {
        let reply = try SwayIPC.request(SwayIPC.command, "[con_id=\(window.id)] focus", socket: socket)
        guard let results = reply as? [[String: Any]], results.allSatisfy({ $0["success"] as? Bool ?? false }) else {
            throw RPCError(code: RPCErrorCode.failed, message: "Sway didn't bring the window to the front.")
        }
        try await Task.sleep(for: .milliseconds(80))
    }

    func input() async throws -> any RealInput {
        try await InputDevices.shared.input(socket: socket)
    }
}

/// The virtual devices kept between steps, closed after a while unused.
actor InputDevices {
    static let shared = InputDevices()
    static let idle = Duration.seconds(30)

    private var current: WlrootsInput?
    private var generation = 0

    func input(socket: String) async throws -> WlrootsInput {
        generation += 1
        let mine = generation
        defer { scheduleClose(after: mine) }
        if let current, !current.connection.isClosed { return current }
        let connection = try WaylandConnection.connect()
        do {
            let devices = try await WaylandInput.make(on: connection)
            let input = WlrootsInput(connection: connection, devices: devices, outputs: try SwayIPC.outputs(socket: socket))
            try input.prepare()
            try await connection.roundtrip()
            try await Task.sleep(for: .milliseconds(150))
            current = input
            return input
        } catch {
            connection.close()
            if case WaylandError.missingGlobal(let name) = error {
                throw RPCError(code: RPCErrorCode.failed, message: "The compositor doesn't offer \(name), which real input needs on wlroots.")
            }
            throw error
        }
    }

    private func scheduleClose(after use: Int) {
        Task {
            try? await Task.sleep(for: Self.idle)
            closeIfUnused(since: use)
        }
    }

    private func closeIfUnused(since use: Int) {
        guard use == generation, let current else { return }
        current.close()
        self.current = nil
    }
}

/// Real input through wlroots' virtual pointer and virtual keyboard, with a pointer per
/// output so positions map onto the output under them.
final class WlrootsInput: RealInput, @unchecked Sendable {
    let connection: WaylandConnection
    let devices: WaylandInput
    let outputs: [SwayOutput]
    private var pointers: [String: WaylandPointer] = [:]
    private var current: WaylandPointer?
    private var modifierKeyboard: WaylandKeyboard?

    init(connection: WaylandConnection, devices: WaylandInput, outputs: [SwayOutput]) {
        self.connection = connection
        self.devices = devices
        self.outputs = outputs
    }

    /// Makes a pointer on every output, so the compositor has them before the first move; on a
    /// seat with no other pointer, apps bind theirs only after it appears.
    func prepare() throws {
        for output in outputs { pointers[output.name] = try devices.pointer(on: output.name) }
    }

    func flush() async throws {
        try await connection.roundtrip()
    }

    func move(to point: CGPoint) async throws {
        guard let output = outputs.first(where: { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height).contains(point) }) ?? outputs.first else {
            throw RPCError(code: RPCErrorCode.failed, message: "The compositor lists no outputs to move the pointer on.")
        }
        let pointer = try pointers[output.name] ?? devices.pointer(on: output.name)
        pointers[output.name] = pointer
        current = pointer
        try pointer.move(x: point.x - output.x, y: point.y - output.y, width: output.width, height: output.height)
    }

    func button(_ button: UInt32, pressed: Bool) async throws {
        guard let current else { throw RPCError(code: RPCErrorCode.failed, message: "The pointer hasn't moved anywhere yet.") }
        try current.button(button, pressed: pressed)
    }

    func scroll(dx: Double, dy: Double) async throws {
        guard let current else { throw RPCError(code: RPCErrorCode.failed, message: "The pointer hasn't moved anywhere yet.") }
        try current.scroll(dx: dx, dy: dy)
    }

    func hold(_ modifiers: UInt32) async throws {
        let keyboard = try modifierKeyboard ?? devices.keyboard(keys: [])
        modifierKeyboard = keyboard
        try keyboard.setModifiers(modifiers)
    }

    func type(_ text: String) async throws {
        try await withKeyboard(keys: text.map(XKBKeymap.keysym(for:))) { try $0.type(text) }
    }

    func tap(_ key: String, modifiers: UInt32) async throws {
        try await withKeyboard(keys: [key]) { try $0.tap(key, modifiers: modifiers) }
    }

    /// A keyboard with its own keymap for one burst of keys. Apps notice a new keyboard only
    /// once the compositor has told them about it, which on a seat with no other keyboard (a
    /// headless session) means binding one and getting focus, so the keys wait a moment for
    /// that, and the keyboard stays a moment after for the last ones to be handled.
    private func withKeyboard(keys: [String], _ body: (WaylandKeyboard) throws -> Void) async throws {
        let keyboard = try devices.keyboard(keys: keys)
        defer { keyboard.close() }
        try await connection.roundtrip()
        try await Task.sleep(for: .milliseconds(150))
        try body(keyboard)
        try await connection.roundtrip()
        try await Task.sleep(for: .milliseconds(100))
    }

    func release() async {
        try? modifierKeyboard?.setModifiers(0)
    }

    func close() {
        try? modifierKeyboard?.setModifiers(0)
        modifierKeyboard?.close()
        for pointer in pointers.values { pointer.close() }
        connection.close()
    }
}
