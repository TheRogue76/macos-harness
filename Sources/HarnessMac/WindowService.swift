import AppKit
import ApplicationServices
import HarnessCore
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
            if match == nil, let hub = SimulatorScreens.runningHub(), hub.pid == pid { return hub }
        } else {
            match = apps.first { $0.bundleIdentifier?.lowercased() == needle }
                ?? apps.first { $0.localizedName?.lowercased() == needle }
        }
        if let app = match, app.processIdentifier <= 0, app.bundleIdentifier == SimulatorScreens.deviceHubBundleID,
           let hub = SimulatorScreens.runningHub() {
            return hub
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

/// Turns a target into the app and window (or simulator screen) it names.
public enum TargetResolver {
    /// The app and window a target names. A `sim:` target resolves to the Device Hub window
    /// showing that simulator, with the simulator's screen as its content.
    public static func resolve(_ target: Target) async throws -> (app: AppRef, window: WindowService.Window) {
        if target.androidDevice != nil {
            throw RPCError(code: RPCErrorCode.invalidParams, message: "Android devices have no menus or Mac windows; use the android commands for buttons and settings.")
        }
        if let device = target.simulatorDevice {
            return try await SimulatorScreens.shared.resolve(device: device, window: target.window)
        }
        let app = try await MainActor.run { try AppResolver.resolve(target.app) }
        return (app, try WindowService.resolve(target, app: app))
    }

    /// The target, aimed at the window holding `ref` when it names no window of its own.
    public static func target(_ target: Target, holding ref: String?) async -> Target {
        guard let ref, target.window == nil, target.simulatorDevice == nil, target.androidDevice == nil,
              let app = try? await MainActor.run(body: { try AppResolver.resolve(target.app) }) else {
            return target
        }
        return aimed(
            target,
            refWindow: {
                ElementRegistry.shared.element(for: ref, pid: app.pid)
                    .flatMap { AX.element($0, "AXWindow") }
                    .flatMap(WindowService.windowID(of:))
            },
            windows: {
                let listed = (try? WindowService.windows(of: app).map(\.info.id)) ?? []
                return listed + WindowService.onOtherSpaces(of: app, besides: Set(listed)).map(\.id)
            }
        )
    }

    /// `target` with its window set to the ref's, when it names no window, isn't a device, and the
    /// ref's window is one of the app's windows.
    static func aimed(_ target: Target, refWindow: () -> UInt32?, windows: () -> [UInt32]) -> Target {
        guard target.window == nil, target.simulatorDevice == nil, target.androidDevice == nil,
              let id = refWindow(), windows().contains(id) else {
            return target
        }
        var aimed = target
        aimed.window = id
        return aimed
    }

    /// The app a target names, without looking for a window.
    public static func app(_ target: Target) async throws -> AppRef {
        if target.simulatorDevice != nil || target.androidDevice != nil { return try await resolve(target).app }
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
                try ScreenLock.check()
                if let away = onOtherSpaces(of: app, besides: Set(all.map(\.info.id))).first(where: { $0.id == id }) {
                    if let reached = reach(away, app: app) { return reached }
                    throw RPCError(code: RPCErrorCode.failed, message: otherSpaceMessage(away))
                }
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
            try ScreenLock.check()
            let away = onOtherSpaces(of: app, besides: [])
            if let reached = away.lazy.compactMap({ reach($0, app: app) }).first { return reached }
            if let first = away.first {
                throw RPCError(code: RPCErrorCode.failed, message: otherSpaceMessage(first))
            }
            if NSRunningApplication(processIdentifier: app.pid)?.isHidden == true {
                throw RPCError(code: RPCErrorCode.failed, message: "\(app.name) is hidden (⌘H), so it shows no windows. `launch \"\(app.name)\" --activate` shows it.")
            }
            throw RPCError(code: RPCErrorCode.failed, message: "\(app.name) has no windows. It may be closed, or a menu bar app.")
        }
        return window
    }

    /// The app's windows on a Space (desktop) that isn't showing, which accessibility doesn't
    /// list: titled windows the window server has off screen that are on some Space.
    public static func onOtherSpaces(of app: AppRef, besides listed: Set<UInt32>) -> [WindowInfo] {
        let all = (CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        return all.compactMap { entry -> WindowInfo? in
            guard (entry[kCGWindowOwnerPID as String] as? pid_t) == app.pid,
                  (entry[kCGWindowLayer as String] as? Int ?? 0) == 0,
                  (entry[kCGWindowIsOnscreen as String] as? Bool ?? false) == false,
                  let id = entry[kCGWindowNumber as String] as? UInt32, !listed.contains(id),
                  let title = entry[kCGWindowName as String] as? String, !title.isEmpty,
                  let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat],
                  (bounds["Width"] ?? 0) >= 100, (bounds["Height"] ?? 0) >= 60,
                  SkyLight.spaces(ofWindow: id).map({ !$0.isEmpty }) ?? false else { return nil }
            var info = WindowInfo(
                id: id, app: app, title: title,
                frame: Rect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0),
                onScreen: false, minimized: false, focused: false, main: false, subrole: nil, hasSheet: false
            )
            info.otherSpace = true
            return info
        }
    }

    /// The titles of `windows` by window ID, with the app's windows on Spaces that aren't showing
    /// added when `otherSpaces`, since accessibility doesn't list those.
    static func titles(of windows: [Window], app: AppRef, otherSpaces: Bool) -> [UInt32: String] {
        var titles = Dictionary(uniqueKeysWithValues: windows.map { ($0.info.id, $0.info.title) })
        guard otherSpaces else { return titles }
        for away in onOtherSpaces(of: app, besides: Set(titles.keys)) { titles[away.id] = away.title }
        return titles
    }

    /// A window on a Space that isn't showing, which `AXWindows` leaves out, through its app's main
    /// or focused window when it's that one, or else a remote-element lookup, which finds it once
    /// the app has handed out its element; nil when neither reaches it.
    static func reach(_ away: WindowInfo, app: AppRef) -> Window? {
        let appElement = AX.application(app.pid)
        AX.setTimeout(appElement, seconds: 1.5)
        let main = AX.element(appElement, "AXMainWindow")
        let focused = AX.element(appElement, "AXFocusedWindow")
        guard let element = [main, focused].compactMap({ $0 }).first(where: { windowID(of: $0) == away.id })
            ?? RemoteElements.window(pid: app.pid, id: away.id),
            let frame = AX.frame(element) else { return nil }
        var info = away
        info.title = AX.string(element, "AXTitle") ?? away.title
        info.frame = Rect(frame)
        info.main = main.map { CFEqual($0, element) } ?? false
        info.focused = focused.map { CFEqual($0, element) } ?? false
        info.subrole = AX.string(element, "AXSubrole")
        info.hasSheet = AX.children(element).contains { AX.role($0) == "AXSheet" }
        return Window(info: info, element: element)
    }

    /// Where the window server draws a window right now, in global points; nil when it isn't listed.
    static func drawnFrame(of id: CGWindowID) -> CGRect? {
        guard let entry = (CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]])?.first,
              let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }
        return CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
    }

    /// Whether the window server draws the window at its own frame rather than shrunk, as Stage
    /// Manager does with windows in its strip.
    static func isDrawnFull(_ window: WindowInfo) -> Bool {
        guard let drawn = drawnFrame(of: window.id) else { return true }
        return matches(drawn: drawn, frame: window.frame.cgRect)
    }

    /// Whether a drawn frame is the window's own frame, give or take 2 points.
    static func matches(drawn: CGRect, frame: CGRect) -> Bool {
        abs(drawn.minX - frame.minX) <= 2 && abs(drawn.minY - frame.minY) <= 2
            && abs(drawn.width - frame.width) <= 2 && abs(drawn.height - frame.height) <= 2
    }

    static func otherSpaceMessage(_ window: WindowInfo) -> String {
        "\(window.app.name)'s window \(window.id) “\(window.title)” is on another Space (desktop) that isn't showing, and macOS Harness can't reach it there: only an app's main or focused window, or a window read before it moved, can be. Switch to that desktop, or bring the app forward with `launch \"\(window.app.name)\" --activate` (which switches to it), then try again."
    }

    /// Why a step that needs the real mouse or keyboard can't be done in a window on a Space that
    /// isn't showing.
    static func otherSpaceRealInputMessage(_ window: WindowInfo) -> String {
        "\(window.app.name)'s window \(window.id) “\(window.title)” is on another Space (desktop) that isn't showing, where the real mouse and keyboard can't reach it, and this step needs them. Accessibility actions and clicks, scrolls and keys in the background work there; for the rest, switch to that desktop, or bring the app forward with `launch \"\(window.app.name)\" --activate` (which switches to it)."
    }

    /// The window server ID of the app's focused window, where background keys land.
    static func focusedWindowID(of app: AppRef) -> CGWindowID? {
        let appElement = AX.application(app.pid)
        AX.setTimeout(appElement, seconds: 1)
        return AX.element(appElement, "AXFocusedWindow").flatMap(windowID(of:))
    }

    /// The window server ID of an AX window, or nil when it has none.
    static func windowID(of element: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        guard _AXUIElementGetWindow(element, &id) == .success, id != 0 else { return nil }
        return id
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
    /// What works in a window on a Space that isn't showing.
    static let otherSpaceNotice = "The window is on another Space (desktop) that isn't showing. Reading, accessibility actions and clicks, scrolls and keys in the background reach it there; the real mouse and keyboard don't."

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
            return (AppControl.processID(of: app), app.localizedName ?? "?", app.bundleIdentifier)
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
        if window.otherSpace == true {
            notices.append(Notice(kind: "otherSpace", message: Self.otherSpaceNotice))
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

/// The helper's own interface, which agents may read but never operate.
public enum OwnUI {
    /// Throws when the app is this helper: its controls (pause, stop, resume, pairing) belong to
    /// the user, and pressing them through accessibility from inside the helper would run their
    /// handlers off the main thread.
    public static func refuse(_ app: AppRef) throws {
        guard app.pid == getpid() else { return }
        throw RPCError(
            code: RPCErrorCode.failed,
            message: "\(app.name) is macOS Harness itself; its controls are for the user, so agents can't press or click them."
        )
    }
}
