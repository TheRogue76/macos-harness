import AppKit
import ApplicationServices
import Foundation
import HarnessProtocol

/// Finds the Device Hub window showing a simulator, opening one when none does, and the
/// simulator's screen inside it.
public final class SimulatorScreens: @unchecked Sendable {
    public static let shared = SimulatorScreens()

    /// Device Hub's bundle ID (Xcode 27 and later).
    public static let deviceHubBundleID = "com.apple.dt.Devices"
    static let screenSubrole = "iOSContentGroup"
    static let mainWindowMarker = "DeviceManagementWindow"
    static let deviceWindowMarker = "deviceWindow"

    private let lock = NSLock()
    private var windowsByDevice: [String: CGWindowID] = [:]

    /// The window and screen of a booted simulator, as a target for the usual commands.
    public func resolve(device query: String, window requested: UInt32?) async throws -> (app: AppRef, window: WindowService.Window) {
        let device = try await Simctl.device(query)
        guard device.isBooted else {
            throw RPCError(
                code: RPCErrorCode.failed,
                message: "\(device.name) (\(device.runtime)) isn't booted. Boot it with `macos-harness sim boot \"\(device.name)\"`."
            )
        }
        let hub = try await deviceHub()
        let window = try await window(showing: device, in: hub, requested: requested)
        return (hub, try await screen(of: window, device: device))
    }

    /// Device Hub, launched in the background when it isn't running.
    func deviceHub() async throws -> AppRef {
        if let running = await MainActor.run(body: { Self.runningHub() }), Self.isReady(running) { return running }
        guard let url = await MainActor.run(body: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.deviceHubBundleID) }) else {
            throw RPCError(
                code: RPCErrorCode.failed,
                message: "Device Hub isn't installed. Simulator targets need Xcode 27 or later; check `xcode-select -p`."
            )
        }
        for activates in [false, false, true] {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = activates
            configuration.addsToRecentItems = false
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline {
                if let hub = await MainActor.run(body: { Self.runningHub() }), Self.isReady(hub) { return hub }
                try await Task.sleep(for: .milliseconds(250))
            }
        }
        throw RPCError(code: RPCErrorCode.failed, message: "Device Hub didn't open a window within a minute.")
    }

    /// Whether Device Hub has finished starting: it has a menu bar and a window.
    static func isReady(_ hub: AppRef) -> Bool {
        let app = AX.application(hub.pid)
        AX.setTimeout(app, seconds: 1)
        guard AX.element(app, "AXMenuBar") != nil else { return false }
        return !((try? WindowService.windows(of: hub)) ?? []).isEmpty
    }

    /// Device Hub's version, or nil when it isn't installed.
    @MainActor
    public static func deviceHubVersion() -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: deviceHubBundleID) else { return nil }
        return Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "installed"
    }

    /// Quits Device Hub and waits for it to go. Quitting it shuts down every simulator it shows,
    /// so callers only do this when none is running.
    static func quitDeviceHub() async -> Bool {
        guard let app = await MainActor.run(body: {
            NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == deviceHubBundleID }
        }) else { return true }
        _ = await MainActor.run { app.terminate() }
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if await MainActor.run(body: { app.isTerminated }) { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return false
    }

    @MainActor
    static func runningHub() -> AppRef? {
        NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == deviceHubBundleID }.map {
            AppRef(name: $0.localizedName ?? "Device Hub", bundleIdentifier: deviceHubBundleID, pid: $0.processIdentifier)
        }
    }

    /// The Device Hub window showing the device whose screen holds its elements: one already
    /// showing it, or a new one.
    func window(showing device: SimulatorInfo, in hub: AppRef, requested: UInt32?) async throws -> WindowService.Window {
        let windows = try WindowService.windows(of: hub)
        if let requested {
            guard let window = windows.first(where: { $0.info.id == requested }) else {
                throw RPCError(code: RPCErrorCode.failed, message: "Device Hub has no window \(requested).")
            }
            guard shows(window, device: device) else {
                throw RPCError(code: RPCErrorCode.failed, message: "Window \(requested) doesn't show \(device.name).")
            }
            return window
        }
        var candidates: [WindowService.Window] = []
        if let remembered = lock.withLock({ windowsByDevice[device.udid] }),
           let window = windows.first(where: { $0.info.id == remembered }), Self.title(window.info.title, names: device) {
            candidates.append(window)
        }
        let unique = try await isOnlyDeviceNamed(device)
        candidates += windows.filter { window in
            Self.isDeviceWindow(window) && unique && Self.title(window.info.title, names: device)
                && !candidates.contains { $0.info.id == window.info.id }
        }
        candidates += windows.filter { Self.isMainWindow($0) && Self.selectedDevice(in: $0.element) == device.udid }
        if let window = candidates.first(where: Self.holdsElements) {
            remember(window, for: device)
            return window
        }
        return try await openWindow(for: device, in: hub, existing: windows)
    }

    /// Whether the window's screen holds the simulator's elements. The elements report positions in
    /// the newest view showing the simulator, and in none once that view's window has closed; a new
    /// window takes them over.
    static func holdsElements(_ window: WindowService.Window) -> Bool {
        guard let group = screenGroup(in: window.element), let frame = AX.frame(group) else { return false }
        let frames = AX.children(group).prefix(8).compactMap(AX.frame).filter { $0.width >= 1 && $0.height >= 1 }
        guard !frames.isEmpty else { return true }
        let inside = frames.filter { frame.contains(CGPoint(x: $0.midX, y: $0.midY)) }.count
        return inside * 2 >= frames.count
    }

    /// Whether the window shows the device right now.
    func shows(_ window: WindowService.Window, device: SimulatorInfo) -> Bool {
        if Self.isMainWindow(window) { return Self.selectedDevice(in: window.element) == device.udid }
        return Self.title(window.info.title, names: device)
    }

    func isOnlyDeviceNamed(_ device: SimulatorInfo) async throws -> Bool {
        let all = try await Simctl.devices()
        return all.filter { $0.name == device.name && $0.runtime == device.runtime }.count == 1
    }

    func remember(_ window: WindowService.Window, for device: SimulatorInfo) {
        lock.withLock { windowsByDevice[device.udid] = window.info.id }
    }

    /// Opens a main window without bringing Device Hub forward, shows the device in it, then moves
    /// the device into a window of its own. The user's own main window is left as it was.
    func openWindow(for device: SimulatorInfo, in hub: AppRef, existing: [WindowService.Window]) async throws -> WindowService.Window {
        let main: WindowService.Window
        if existing.count == 1, Self.isMainWindow(existing[0]), await Self.launchedRecently(hub) {
            main = existing[0]
        } else {
            _ = try await AppControl.menuSelect(.init(app: "\(hub.pid)", path: ["File", "New Window"], activate: false, diff: false))
            main = try await waitForWindow(of: hub, excluding: Set(existing.map(\.info.id))) { Self.isMainWindow($0) }
        }
        guard let row = Self.sidebarRow(for: device.udid, in: main.element) else {
            throw RPCError(code: RPCErrorCode.failed, message: "Device Hub's sidebar doesn't list \(device.name) (\(device.udid)).")
        }
        if AX.set(row, "AXSelected", kCFBooleanTrue) != .success {
            _ = AX.perform(row, "AXPress")
        }
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline, Self.selectedDevice(in: main.element) != device.udid || Self.screenGroup(in: main.element) == nil {
            try await Task.sleep(for: .milliseconds(200))
        }
        guard Self.selectedDevice(in: main.element) == device.udid else {
            throw RPCError(code: RPCErrorCode.failed, message: "Device Hub didn't switch to \(device.name).")
        }
        let before = Set(try WindowService.windows(of: hub).map(\.info.id))
        if let popOut = Self.button(named: "Open in New Window", in: main.element), AX.perform(popOut, "AXPress") == .success,
           let own = try? await waitForWindow(of: hub, excluding: before, timeout: 5, where: Self.isDeviceWindow) {
            remember(own, for: device)
            return own
        }
        let refreshed = try WindowService.windows(of: hub).first { $0.info.id == main.info.id } ?? main
        return refreshed
    }

    @MainActor
    static func launchedRecently(_ hub: AppRef) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: hub.pid), let launched = app.launchDate else { return false }
        return Date().timeIntervalSince(launched) < 30
    }

    func waitForWindow(
        of hub: AppRef, excluding: Set<CGWindowID>, timeout: TimeInterval = 8, where matches: (WindowService.Window) -> Bool
    ) async throws -> WindowService.Window {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let window = try WindowService.windows(of: hub).first(where: { !excluding.contains($0.info.id) && matches($0) }) {
                return window
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw RPCError(code: RPCErrorCode.failed, message: "Device Hub didn't open a window within \(Int(timeout)) s.")
    }

    /// The window as a target: its content is the simulator's screen, in the device's points.
    func screen(of window: WindowService.Window, device: SimulatorInfo) async throws -> WindowService.Window {
        var group = Self.screenGroup(in: window.element)
        let deadline = Date().addingTimeInterval(5)
        while group == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(200))
            group = Self.screenGroup(in: window.element)
        }
        guard let group, let frame = AX.frame(group), frame.width >= 1, frame.height >= 1 else {
            throw RPCError(code: RPCErrorCode.failed, message: "Device Hub's window \(window.info.id) doesn't show \(device.name)'s screen.")
        }
        let longSide = max(device.screen?.width ?? 0, device.screen?.height ?? 0)
        let scale = longSide > 0 ? longSide / max(frame.width, frame.height) : 1
        var info = window.info
        info.simulator = device
        info.title = "\(device.name) – \(device.runtime)"
        var target = WindowService.Window(info: info, element: window.element, content: group, space: CoordinateSpace(frame: frame, scale: scale))
        target.info.frame = Rect(frame)
        return target
    }

    /// Waits up to `timeout` for the simulator's screen to list elements; the bridged tree lags
    /// behind the screen after every change. Returns whether it has any.
    public static func waitForContent(_ window: WindowService.Window, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if !AX.children(window.content).isEmpty { return true }
            guard Date() < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    static func isMainWindow(_ window: WindowService.Window) -> Bool {
        (AX.string(window.element, "AXIdentifier") ?? "").contains(mainWindowMarker)
    }

    static func isDeviceWindow(_ window: WindowService.Window) -> Bool {
        (AX.string(window.element, "AXIdentifier") ?? "").hasPrefix(deviceWindowMarker)
    }

    /// Whether a Device Hub window title (`<name> – <runtime>`) names the device.
    static func title(_ title: String, names device: SimulatorInfo) -> Bool {
        title == "\(device.name) – \(device.runtime)"
    }

    /// The UDID of the device selected in a main window's sidebar.
    static func selectedDevice(in window: AXUIElement) -> String? {
        var found: String?
        visit(window, maxDepth: 12) { element in
            guard AX.role(element) == "AXRow" else { return AX.string(element, "AXSubrole") == screenSubrole ? .skip : .descend }
            guard (AX.attribute(element, "AXSelected") as? Bool) == true else { return .skip }
            found = deviceID(under: element)
            return .stop
        }
        return found
    }

    /// The sidebar row of a device.
    static func sidebarRow(for udid: String, in window: AXUIElement) -> AXUIElement? {
        var found: AXUIElement?
        visit(window, maxDepth: 12) { element in
            guard AX.role(element) == "AXRow" else { return AX.string(element, "AXSubrole") == screenSubrole ? .skip : .descend }
            guard deviceID(under: element) == udid else { return .skip }
            found = element
            return .stop
        }
        return found
    }

    /// The UDID in a sidebar row's `TableRow.Device.<UDID>` identifiers.
    static func deviceID(under row: AXUIElement) -> String? {
        let prefix = "TableRow.Device."
        var found: String?
        visit(row, maxDepth: 4) { element in
            guard let identifier = AX.string(element, "AXIdentifier"), identifier.hasPrefix(prefix) else { return .descend }
            found = String(identifier.dropFirst(prefix.count))
            return .stop
        }
        return found
    }

    /// The simulator's screen in a Device Hub window.
    static func screenGroup(in window: AXUIElement) -> AXUIElement? {
        var found: AXUIElement?
        visit(window, maxDepth: 10) { element in
            if AX.string(element, "AXSubrole") == screenSubrole {
                found = element
                return .stop
            }
            return ["AXOutline", "AXToolbar", "AXScrollArea"].contains(AX.role(element)) ? .skip : .descend
        }
        return found
    }

    /// A button by its label.
    static func button(named name: String, in window: AXUIElement) -> AXUIElement? {
        var found: AXUIElement?
        visit(window, maxDepth: 8) { element in
            if AX.role(element) == "AXButton", AX.label(element) == name {
                found = element
                return .stop
            }
            return AX.role(element) == "AXOutline" || AX.string(element, "AXSubrole") == screenSubrole ? .skip : .descend
        }
        return found
    }

    /// What to do after looking at an element while walking a tree.
    enum Visit {
        case descend
        case skip
        case stop
    }

    /// Calls `body` on the element and its descendants, depth first, until it says stop.
    static func visit(_ element: AXUIElement, maxDepth: Int, _ body: (AXUIElement) -> Visit) {
        var stopped = false
        func walk(_ element: AXUIElement, _ depth: Int) {
            guard !stopped else { return }
            switch body(element) {
            case .stop:
                stopped = true
            case .skip:
                return
            case .descend:
                guard depth < maxDepth else { return }
                for child in AX.children(element) where !stopped {
                    walk(child, depth + 1)
                }
            }
        }
        walk(element, 0)
    }
}
