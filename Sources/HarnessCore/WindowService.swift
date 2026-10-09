import AppKit
import ApplicationServices
import HarnessProtocol

/// The CGWindowID of an AX window.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

public enum AppResolver {
    /// Finds a running app by pid, bundle ID or name (case-insensitive).
    @MainActor
    public static func resolve(_ query: String) throws -> AppRef {
        let apps = NSWorkspace.shared.runningApplications
        let needle = query.lowercased()
        let match: NSRunningApplication?
        if let pid = Int32(query) {
            match = apps.first { $0.processIdentifier == pid }
        } else {
            match = apps.first { $0.bundleIdentifier?.lowercased() == needle }
                ?? apps.first { $0.localizedName?.lowercased() == needle }
        }
        guard let app = match else {
            let suggestions = apps
                .filter { $0.activationPolicy == .regular }
                .compactMap(\.localizedName)
                .filter { $0.lowercased().contains(needle) || needle.contains($0.lowercased()) }
            let hint = suggestions.isEmpty ? "Run `macos-harness apps` to see what's running." : "Did you mean \(suggestions.joined(separator: ", "))?"
            throw RPCError(code: RPCErrorCode.failed, message: "No running app matches \"\(query)\". \(hint)")
        }
        return AppRef(
            name: app.localizedName ?? app.bundleIdentifier ?? "pid \(app.processIdentifier)",
            bundleIdentifier: app.bundleIdentifier,
            pid: app.processIdentifier
        )
    }
}

/// How a target's coordinates map to the screen: the global rectangle they start from, and how
/// many target points one screen point is (1 for Mac windows, the zoom factor for a simulator).
public struct CoordinateSpace: Sendable, Equatable {
    public var frame: CGRect
    public var scale: CGFloat

    public init(frame: CGRect, scale: CGFloat = 1) {
        self.frame = frame
        self.scale = scale
    }

    /// The space's size in target points.
    public var size: CGSize { CGSize(width: frame.width * scale, height: frame.height * scale) }

    /// A global rectangle in target points.
    public func local(_ rect: CGRect) -> Rect {
        Rect(
            x: ((rect.minX - frame.minX) * scale).rounded(), y: ((rect.minY - frame.minY) * scale).rounded(),
            width: (rect.width * scale).rounded(), height: (rect.height * scale).rounded()
        )
    }

    /// A global point in target points.
    public func local(_ point: CGPoint) -> Point {
        Point(x: ((point.x - frame.minX) * scale).rounded(), y: ((point.y - frame.minY) * scale).rounded())
    }

    /// A point in target points as a global point.
    public func global(_ point: Point) -> CGPoint {
        CGPoint(x: frame.minX + point.x / scale, y: frame.minY + point.y / scale)
    }

    /// Whether a point in target points lies inside the space.
    public func contains(_ point: Point) -> Bool {
        point.x >= 0 && point.y >= 0 && point.x <= size.width.rounded() && point.y <= size.height.rounded()
    }
}

/// Turns a target into the app and window (or simulator screen) it names.
public enum TargetResolver {
    /// The app and window a target names. A `sim:` target resolves to the Device Hub window
    /// showing that simulator, with the simulator's screen as its content.
    public static func resolve(_ target: Target) async throws -> (app: AppRef, window: WindowService.Window) {
        if let device = target.simulatorDevice {
            return try await SimulatorScreens.shared.resolve(device: device, window: target.window)
        }
        let app = try await MainActor.run { try AppResolver.resolve(target.app) }
        return (app, try WindowService.resolve(target, app: app))
    }

    /// The app a target names, without looking for a window.
    public static func app(_ target: Target) async throws -> AppRef {
        if target.simulatorDevice != nil { return try await resolve(target).app }
        return try await MainActor.run { try AppResolver.resolve(target.app) }
    }
}

public enum WindowService {
    public struct Window {
        public var info: WindowInfo
        public var element: AXUIElement
        /// The element whose subtree is the target: the window itself, or a simulator's screen.
        public var content: AXUIElement
        /// Where the target's coordinates come from.
        public var space: CoordinateSpace

        public init(info: WindowInfo, element: AXUIElement, content: AXUIElement? = nil, space: CoordinateSpace? = nil) {
            self.info = info
            self.element = element
            self.content = content ?? element
            self.space = space ?? CoordinateSpace(frame: info.frame.cgRect)
        }

        /// Whether the target is an iOS Simulator's screen.
        public var isSimulator: Bool { info.simulator != nil }
    }

    /// The app's windows, with their window server IDs and on-screen state.
    public static func windows(of app: AppRef) throws -> [Window] {
        try requireAccessibility()
        let appElement = AX.application(app.pid)
        AX.setTimeout(appElement, seconds: 1.5)
        let focused = AX.element(appElement, "AXFocusedWindow")
        let onScreen = onScreenWindowIDs()

        return AX.elements(appElement, "AXWindows").compactMap { element in
            guard let frame = AX.frame(element) else { return nil }
            var id: CGWindowID = 0
            guard _AXUIElementGetWindow(element, &id) == .success, id != 0 else { return nil }
            let children = AX.children(element)
            let info = WindowInfo(
                id: id,
                app: app,
                title: AX.string(element, "AXTitle") ?? "",
                frame: Rect(frame),
                onScreen: onScreen.contains(id),
                minimized: (AX.attribute(element, "AXMinimized") as? Bool) ?? false,
                focused: focused.map { CFEqual($0, element) } ?? false,
                main: (AX.attribute(element, "AXMain") as? Bool) ?? false,
                subrole: AX.string(element, "AXSubrole"),
                hasSheet: children.contains { AX.role($0) == "AXSheet" }
            )
            return Window(info: info, element: element)
        }
    }

    /// The requested window, or the focused one, then the main one, then the first visible one.
    public static func resolve(_ target: Target, app: AppRef) throws -> Window {
        let all = try windows(of: app)
        if let id = target.window {
            guard let match = all.first(where: { $0.info.id == id }) else {
                let ids = all.map { "\($0.info.id)" }.joined(separator: ", ")
                throw RPCError(code: RPCErrorCode.failed, message: "\(app.name) has no window \(id). Its windows: \(ids.isEmpty ? "none" : ids)")
            }
            return match
        }
        let window = all.first { $0.info.focused && !$0.info.minimized }
            ?? all.first { $0.info.main && !$0.info.minimized }
            ?? all.first { !$0.info.minimized }
            ?? all.first
        guard let window else {
            throw RPCError(code: RPCErrorCode.failed, message: "\(app.name) has no windows. It may be hidden, closed, or a menu bar app.")
        }
        return window
    }

    static func onScreenWindowIDs() -> Set<CGWindowID> {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return [] }
        return Set(list.compactMap { $0[kCGWindowNumber as String] as? CGWindowID })
    }

    static func requireAccessibility() throws {
        guard AXIsProcessTrusted() else {
            throw RPCError(
                code: RPCErrorCode.permissionMissing,
                message: "macOS Harness doesn't have Accessibility permission. Run `macos-harness doctor`."
            )
        }
    }
}

public enum Notices {
    /// Processes that put up system-wide dialogs which block other apps.
    static let systemDialogOwners: Set<String> = [
        "com.apple.UserNotificationCenter", "com.apple.SecurityAgent", "com.apple.coreservices.uiagent",
        "com.apple.CoreServicesUIAgent", "com.apple.universalaccessAuthWarn", "com.apple.accessibility.universalAccessAuthWarn",
    ]

    /// Things outside the target window an agent should know before acting.
    public static func collect(for window: WindowInfo) async -> [Notice] {
        var notices: [Notice] = []
        let frontmost = await MainActor.run { () -> (pid_t, String, String?)? in
            guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
            return (app.processIdentifier, app.localizedName ?? "?", app.bundleIdentifier)
        }
        if let (pid, name, bundle) = frontmost, pid != window.app.pid {
            if let bundle, systemDialogOwners.contains(bundle), let dialog = systemDialog(pid: pid) {
                notices.append(Notice(kind: "systemDialog", message: "A system dialog from \(name) is in front: \(dialog)"))
            } else if window.simulator == nil {
                notices.append(Notice(kind: "notFrontmost", message: "\(window.app.name) isn't frontmost (\(name) is). Reading works; menu commands and real input need it in front."))
            }
        }
        guard window.simulator == nil else { return notices }
        if window.hasSheet {
            notices.append(Notice(kind: "sheet", message: "A sheet is open on this window; it's part of the tree below."))
        }
        if window.minimized {
            notices.append(Notice(kind: "minimized", message: "The window is minimized."))
        }
        if Permissions.secureInputEnabled {
            notices.append(Notice(kind: "secureInput", message: "Secure Input is on (a password field has focus somewhere); typed keys will be blocked."))
        }
        return notices
    }

    /// The text and buttons of a system dialog, e.g. `"Allow “X” to access…" [Don’t Allow] [Allow]`.
    static func systemDialog(pid: pid_t) -> String? {
        let app = AX.application(pid)
        AX.setTimeout(app, seconds: 0.5)
        guard let window = AX.elements(app, "AXWindows").first else { return nil }
        var texts: [String] = []
        var buttons: [String] = []
        func walk(_ element: AXUIElement, _ depth: Int) {
            let role = AX.role(element)
            if role == "AXStaticText", let value = AX.value(element), !value.isEmpty { texts.append(value) }
            if role == "AXButton", let label = AX.label(element) { buttons.append("[\(label)]") }
            guard depth < 6 else { return }
            AX.children(element).forEach { walk($0, depth + 1) }
        }
        walk(window, 0)
        guard !texts.isEmpty || !buttons.isEmpty else { return nil }
        return "\"\(texts.joined(separator: " "))\" \(buttons.joined(separator: " "))"
    }
}

extension Rect {
    init(_ rect: CGRect) {
        self.init(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
    }

    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}
