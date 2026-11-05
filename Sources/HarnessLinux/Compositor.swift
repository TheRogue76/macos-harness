#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import Synchronization
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
    /// The compositor's own name for the window, when it isn't a number (KWin's UUIDs).
    var key: String?
    /// The window with the title bar and borders the compositor draws round it, when it draws
    /// them; markers go round this.
    var outer: CGRect?
    var minimized = false
    var floating = false
}

/// A change to a window that only the compositor can make.
enum WindowChange: Equatable {
    /// Puts the window's top-left corner (the frame the harness reports) at a point.
    case move(CGPoint)
    /// Gives the window's frame a size.
    case resize(CGSize)
    case minimize, restore
    case fullscreen(Bool)
    /// Asks the window to close, as its close button does; it may ask to save first.
    case close
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
    /// Moves, resizes, minimizes, restores, full-screens or closes a window.
    func arrange(_ window: CompositorWindow, _ change: WindowChange) async throws
    /// Real input devices, until they're closed.
    func input() async throws -> any RealInput
    /// Puts one of the harness's own windows just below (or above) a point, such as where its
    /// tray icon was clicked, inside the work area; a point at the origin means the top right.
    func place(_ window: CompositorWindow, near point: CGPoint) async throws
    /// Whether the compositor draws window markers itself (`outline`); elsewhere the harness's
    /// marker app draws them in a window of its own, which `cover` puts in place.
    var drawsMarkers: Bool { get }
    /// Outlines a window an agent worked in for a moment, with a caption.
    func outline(_ window: CompositorWindow, caption: String) async throws
    /// Shows a ripple where an agent clicked or pressed in a window, just above that window.
    func ripple(_ window: CompositorWindow, at point: CGPoint) async throws
    /// Readies the compositor for the marker app's window, before it first shows.
    func prepareMarker(appID: String) async throws
    /// Puts the marker app's window round `target`, directly above it, without taking focus
    /// from `focused`.
    func cover(_ target: CompositorWindow, with marker: CompositorWindow, frame: CGRect, focused: CompositorWindow?) async throws
    /// Other apps' windows in front of `window` that a capture of it shows, where the compositor
    /// can't capture a window alone.
    func covering(_ window: CompositorWindow) async -> [CompositorWindow]
    /// Puts one of the harness's own windows (the driving panel) in the bottom right corner of
    /// the work area, above other windows where the compositor allows, giving focus back to
    /// `focused` if it took it.
    func placeInCorner(_ window: CompositorWindow, focused: CompositorWindow?) async throws
}

extension Compositor {
    var drawsMarkers: Bool { false }
    func outline(_ window: CompositorWindow, caption: String) async throws {}
    func ripple(_ window: CompositorWindow, at point: CGPoint) async throws {}
    func prepareMarker(appID: String) async throws {}
    func cover(_ target: CompositorWindow, with marker: CompositorWindow, frame: CGRect, focused: CompositorWindow?) async throws {}
    func placeInCorner(_ window: CompositorWindow, focused: CompositorWindow?) async throws {}
    func covering(_ window: CompositorWindow) async -> [CompositorWindow] { [] }

    /// Gives focus back to `focused` when the harness's `window` took it on appearing.
    func refocus(_ focused: CompositorWindow?, from window: CompositorWindow) async throws {
        guard let focused, try await windows().contains(where: { $0.id == window.id && $0.focused }) else { return }
        try await activate(focused)
    }
}

/// The compositor windows behind the windows agents work in, so their markers can be drawn
/// when the activity they're for is recorded.
public enum WindowMarks {
    private static let windows = Mutex<[UInt32: CompositorWindow]>([:])

    static func remember(_ id: UInt32, as window: CompositorWindow) {
        windows.withLock { known in
            if known.count > 200 { known.removeAll() }
            known[id] = window
        }
    }

    /// The harness's marker app, which draws markers where the compositor can't: its app ID,
    /// and how to hand it a marker.
    public struct Overlay: Sendable {
        public let appID: String
        public let send: @Sendable (TowerMarkMethod.Mark) async -> Void
        public let drive: @Sendable (TowerMarkMethod.Driving) async -> Void

        public init(
            appID: String, send: @escaping @Sendable (TowerMarkMethod.Mark) async -> Void,
            drive: @escaping @Sendable (TowerMarkMethod.Driving) async -> Void
        ) {
            self.appID = appID
            self.send = send
            self.drive = drive
        }
    }

    /// Shows the "is driving" panel through `overlay`, bottom right, on any compositor the
    /// harness can ask.
    public static func drive(_ driving: TowerMarkMethod.Driving, overlay: Overlay?) async {
        guard let overlay, let compositor = await Compositors.current() else { return }
        await MarkerWindow.shared.drive(driving, on: compositor, overlay: overlay)
    }

    /// Outlines the window with the harness's `id` for it when there's a caption, and shows a
    /// ripple at `ripple` (a point on screen) when there's one: drawn by the compositor where it
    /// can, by `overlay` elsewhere.
    public static func show(_ id: UInt32, caption: String?, ripple: Point?, overlay: Overlay?) async {
        guard caption != nil || ripple != nil, let window = windows.withLock({ $0[id] }),
              let compositor = await Compositors.current() else { return }
        let point = ripple.map { CGPoint(x: $0.x, y: $0.y) }
        if compositor.drawsMarkers {
            if let caption { try? await compositor.outline(window, caption: caption) }
            if let point { try? await compositor.ripple(window, at: point) }
        } else if let overlay {
            await MarkerWindow.shared.mark(window, caption: caption, ripple: point, on: compositor, overlay: overlay)
        }
    }

    /// The marker window's frame round a window's: the glow all round, and room for the tab
    /// above unless it goes inside.
    static func markerFrame(around frame: CGRect, tabInside: Bool) -> CGRect {
        let glow = TowerMarkMethod.glow, tab = tabInside ? 0 : TowerMarkMethod.tabHeight
        return CGRect(x: frame.minX - glow, y: frame.minY - glow - tab, width: frame.width + 2 * glow, height: frame.height + 2 * glow + tab)
    }

    /// Whether the tab must go inside the window, with no room above it on screen.
    static func tabInside(_ frame: CGRect, screenTop: Double = 0) -> Bool {
        frame.minY - TowerMarkMethod.glow - TowerMarkMethod.tabHeight < screenTop
    }
}

/// Puts the marker app's window round the windows agents act in, one marker at a time; a newer
/// marker takes over from one still being placed.
actor MarkerWindow {
    static let shared = MarkerWindow()

    private var generation = 0
    private var drivings = 0
    private var prepared: String?

    func mark(_ window: CompositorWindow, caption: String?, ripple: CGPoint?, on compositor: any Compositor, overlay: WindowMarks.Overlay) async {
        generation += 1
        let id = generation
        if prepared != overlay.appID {
            try? await compositor.prepareMarker(appID: overlay.appID)
            prepared = overlay.appID
        }
        let listed = (try? await compositor.windows()) ?? []
        guard let target = listed.first(where: { $0.id == window.id }) ?? listed.first(where: { $0.pid == window.pid && $0.title == window.title }),
              target.visible else { return }
        let focused = listed.first { $0.focused && $0.appID != overlay.appID }
        let around = target.outer ?? target.frame
        let tabInside = WindowMarks.tabInside(around)
        let frame = WindowMarks.markerFrame(around: around, tabInside: tabInside)
        let spot = ripple.map { Point(x: $0.x - frame.minX, y: $0.y - frame.minY) }
        await overlay.send(TowerMarkMethod.Mark(id: id, caption: caption, tabInside: tabInside, placed: false, ripple: spot))
        guard let marker = await shown(overlay.appID, TowerMarkMethod.markerTitle, on: compositor), id == generation else { return }
        guard (try? await compositor.cover(target, with: marker, frame: frame, focused: focused)) != nil, id == generation else { return }
        await overlay.send(TowerMarkMethod.Mark(id: id, caption: caption, tabInside: tabInside, placed: true, ripple: spot))
        await follow(target, with: marker, from: frame, tabInside: tabInside, mark: id, on: compositor)
    }

    /// Keeps the marker round its window while it shows, as the Mac's does: every 100 ms for the
    /// 1.6 s it lasts, it reads the window again and, when it moved or changed size, puts the
    /// marker round it again; a newer marker takes over.
    private func follow(
        _ target: CompositorWindow, with marker: CompositorWindow, from frame: CGRect, tabInside: Bool, mark id: Int, on compositor: any Compositor
    ) async {
        var last = frame
        for _ in 0..<16 {
            try? await Task.sleep(for: .milliseconds(100))
            guard id == generation, let now = try? await compositor.windows().first(where: { $0.id == target.id }), now.visible else { return }
            let moved = WindowMarks.markerFrame(around: now.outer ?? now.frame, tabInside: tabInside)
            guard moved != last else { continue }
            last = moved
            try? await compositor.cover(now, with: marker, frame: moved, focused: nil)
        }
    }

    /// Lays out the driving panel, puts it in the corner once the compositor shows it, and again a
    /// moment later (compositors place a new window themselves just after it maps), then shows it.
    func drive(_ driving: TowerMarkMethod.Driving, on compositor: any Compositor, overlay: WindowMarks.Overlay) async {
        drivings += 1
        let id = drivings
        if prepared != overlay.appID {
            try? await compositor.prepareMarker(appID: overlay.appID)
            prepared = overlay.appID
        }
        let focused = (try? await compositor.windows())?.first { $0.focused && $0.appID != overlay.appID }
        var step = driving
        step.id = id
        step.placed = false
        await overlay.drive(step)
        guard await shown(overlay.appID, TowerMarkMethod.drivingTitle, on: compositor) != nil, id == drivings else { return }
        try? await Task.sleep(for: .milliseconds(60))
        guard let panel = await shown(overlay.appID, TowerMarkMethod.drivingTitle, on: compositor), id == drivings else { return }
        try? await compositor.placeInCorner(panel, focused: focused)
        try? await Task.sleep(for: .milliseconds(200))
        guard id == drivings else { return }
        let settled = await shown(overlay.appID, TowerMarkMethod.drivingTitle, on: compositor) ?? panel
        try? await compositor.placeInCorner(settled, focused: focused)
        step.placed = true
        await overlay.drive(step)
    }

    /// The marker app's window with `title` once the compositor shows it.
    private func shown(_ appID: String, _ title: String, on compositor: any Compositor, timeout: Duration = .seconds(2)) async -> CompositorWindow? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let window = try? await compositor.windows().first(where: { $0.appID == appID && $0.title == title }) { return window }
            try? await Task.sleep(for: .milliseconds(30))
        }
        return nil
    }
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
        guard let session = try? await SessionBus.shared.connection() else { return nil }
        if await GnomeCompositor.available(on: session) { return GnomeCompositor() }
        if LinuxPermissions.Desktop.current(environment) == .kde, await KWinCompositor.available(on: session) { return KWinCompositor() }
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
            message: "`\(command)` needs a compositor the harness can ask for windows, pixels and input; so far that's GNOME, KDE, Sway and other wlroots compositors."
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
                focused: window.focused, visible: window.visible, output: window.output,
                outer: window.container.map { CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) }, minimized: window.inScratchpad,
                floating: window.floating
            )
        }
    }

    /// The window's part of its output: Sway captures whole outputs only, so the harness's own
    /// windows in front of it are made clear for the moment of the capture.
    func capture(_ window: CompositorWindow) async throws -> (png: Data, scale: Double) {
        let area = window.outer ?? window.frame
        let own = ((try? await windows()) ?? []).filter {
            ($0.appID ?? "").hasPrefix("io.github.therogue76.MacosHarness") && $0.visible && $0.frame.intersects(area)
        }
        for shown in own { _ = try? SwayIPC.request(SwayIPC.command, "[con_id=\(shown.id)] opacity 0", socket: socket) }
        defer { for shown in own { _ = try? SwayIPC.request(SwayIPC.command, "[con_id=\(shown.id)] opacity 1", socket: socket) } }
        if !own.isEmpty { try? await Task.sleep(for: .milliseconds(50)) }
        return try await captureOutput(window)
    }

    /// Floating windows of other apps listed after `window`, so drawn above it, that overlap it.
    func covering(_ window: CompositorWindow) async -> [CompositorWindow] {
        let listed = (try? await windows()) ?? []
        guard let index = listed.firstIndex(where: { $0.id == window.id }) else { return [] }
        let area = window.outer ?? window.frame
        return listed[(index + 1)...].filter { other in
            other.floating && other.visible && !other.minimized && other.output == window.output
                && !(other.appID ?? "").hasPrefix("io.github.therogue76.MacosHarness") && (other.outer ?? other.frame).intersects(area)
        }
    }

    private func captureOutput(_ window: CompositorWindow) async throws -> (png: Data, scale: Double) {
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

    /// Sway has no minimizing, so a minimized window goes to the scratchpad, and comes back
    /// tiled; a tiled window floats to be moved or resized.
    func arrange(_ window: CompositorWindow, _ change: WindowChange) async throws {
        let outer = window.outer ?? window.frame
        let command: String
        switch change {
        case .move(let point):
            command = "floating enable, move absolute position \(Int((point.x - (window.frame.minX - outer.minX)).rounded())) \(Int((point.y - (window.frame.minY - outer.minY)).rounded()))"
        case .resize(let size):
            let width = size.width + outer.width - window.frame.width, height = size.height + outer.height - window.frame.height
            command = "floating enable, resize set width \(Int(width.rounded())) px height \(Int(height.rounded())) px, move absolute position \(Int(outer.minX.rounded())) \(Int(outer.minY.rounded()))"
        case .minimize:
            command = "move scratchpad"
        case .restore:
            command = "scratchpad show, floating disable"
        case .fullscreen(let on):
            command = "fullscreen \(on ? "enable" : "disable")"
        case .close:
            command = "kill"
        }
        let reply = try SwayIPC.request(SwayIPC.command, "[con_id=\(window.id)] \(command)", socket: socket)
        guard let results = reply as? [[String: Any]], results.allSatisfy({ $0["success"] as? Bool ?? false }) else {
            let error = (reply as? [[String: Any]])?.compactMap { $0["error"] as? String }.first
            throw RPCError(code: RPCErrorCode.failed, message: "Sway didn't do that\(error.map { ": \($0)" } ?? ".")")
        }
    }

    func place(_ window: CompositorWindow, near point: CGPoint) async throws {
        let outputs = try SwayIPC.outputs(socket: socket)
        let containing = outputs.first { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height).contains(point) } ?? outputs.first
        guard let output = containing else { return }
        let anchor = point == .zero ? CGPoint(x: output.x + output.width, y: output.y) : point
        let x = min(max(anchor.x - window.frame.width / 2, output.x + 8), output.x + output.width - window.frame.width - 8)
        let below = anchor.y < output.y + output.height / 2
        let y = below ? anchor.y + 16 : anchor.y - window.frame.height - 16
        _ = try SwayIPC.request(
            SwayIPC.command, "[con_id=\(window.id)] floating enable, move absolute position \(Int(x)) \(Int(max(y, output.y)))", socket: socket
        )
    }

    func prepareMarker(appID: String) async throws {
        let pattern = "^" + appID.replacingOccurrences(of: ".", with: "\\.") + "$"
        _ = try SwayIPC.request(SwayIPC.command, "no_focus [app_id=\"\(pattern)\"]", socket: socket)
        _ = try SwayIPC.request(SwayIPC.command, "for_window [app_id=\"\(pattern)\"] floating enable", socket: socket)
    }

    func cover(_ target: CompositorWindow, with marker: CompositorWindow, frame: CGRect, focused: CompositorWindow?) async throws {
        let reply = try SwayIPC.request(
            SwayIPC.command,
            "[con_id=\(marker.id)] floating enable, border none, resize set \(Int(frame.width.rounded())) \(Int(frame.height.rounded())), move absolute position \(Int(frame.minX.rounded())) \(Int(frame.minY.rounded()))",
            socket: socket
        )
        guard let results = reply as? [[String: Any]], results.allSatisfy({ $0["success"] as? Bool ?? false }) else {
            throw RPCError(code: RPCErrorCode.failed, message: "Sway didn't put the marker in place.")
        }
        try await refocus(focused, from: marker)
    }

    func placeInCorner(_ window: CompositorWindow, focused: CompositorWindow?) async throws {
        let outputs = try SwayIPC.outputs(socket: socket)
        let center = focused.map { CGPoint(x: $0.frame.midX, y: $0.frame.midY) }
        guard let output = outputs.first(where: { output in
            center.map { CGRect(x: output.x, y: output.y, width: output.width, height: output.height).contains($0) } ?? false
        }) ?? outputs.first else { return }
        let x = output.x + output.width - window.frame.width - 24, y = output.y + output.height - window.frame.height - 24
        _ = try SwayIPC.request(
            SwayIPC.command, "[con_id=\(window.id)] floating enable, border none, move absolute position \(Int(x)) \(Int(y))", socket: socket
        )
        try await refocus(focused, from: window)
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

