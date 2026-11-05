import AppKit
import ApplicationServices
import Foundation
import HarnessCore
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

    /// How long a window the helper opened for a simulator is used again rather than another opened.
    static let reuseOpened: TimeInterval = 60

    private let lock = NSLock()
    private var windowsByDevice: [String: CGWindowID] = [:]
    private var opened: [String: (window: CGWindowID, date: Date)] = [:]
    private var holders: [String: CGWindowID] = [:]
    private var opening: [String: Task<CGWindowID, any Error>] = [:]

    /// The window and screen of a booted simulator, as a target for the usual commands.
    public func resolve(device query: String, window requested: UInt32?) async throws -> (app: AppRef, window: WindowService.Window) {
        let device = try await Simctl.device(query)
        guard device.isBooted else {
            throw RPCError(
                code: RPCErrorCode.failed,
                message: "\(device.name) (\(device.runtime)) isn't booted. Boot it with `\(HarnessProduct.commandName) sim boot \"\(device.name)\"`."
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
        guard let hub = await MainActor.run(body: { runningHub() }) else { return true }
        let terminated = await MainActor.run { NSRunningApplication(processIdentifier: hub.pid)?.terminate() ?? false }
        if !terminated { kill(hub.pid, SIGTERM) }
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if kill(hub.pid, 0) != 0 { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return false
    }

    /// The executable that runs Device Hub's windows (its bundle's main executable only starts it).
    static let deviceHubExecutable = "/DeviceHub.app/Contents/MacOS/DeviceHub"

    /// The running Device Hub. LaunchServices can list it without a process ID while the process is
    /// up, so the process is also looked for by its executable.
    @MainActor
    static func runningHub() -> AppRef? {
        let listed = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == deviceHubBundleID }
        if let app = listed.first(where: { $0.processIdentifier > 0 }) {
            return AppRef(name: app.localizedName ?? "Device Hub", bundleIdentifier: deviceHubBundleID, pid: app.processIdentifier)
        }
        guard let pid = ProcessInspector.pids(withExecutableEnding: deviceHubExecutable).first else { return nil }
        return AppRef(name: "Device Hub", bundleIdentifier: deviceHubBundleID, pid: pid)
    }

    /// The Device Hub window showing the device whose screen holds its elements: one already
    /// showing it, one the helper opened for it in the last minute, or a new one, also when the
    /// window that last held them has closed and left the others empty.
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
        let holds = candidates.map(Self.hold)
        if let index = Self.choose(holds) {
            let window = candidates[index]
            if holds[index] == .empty, holderClosed(device, among: windows.map(\.info.id)) {
                return try await openOnce(for: device, in: hub)
            }
            if holds[index] != .empty { noteHolder(window.info.id, for: device) }
            remember(window, for: device)
            return window
        } else if let recent = recentlyOpened(device), let window = candidates.first(where: { $0.info.id == recent }) {
            return window
        }
        return try await openOnce(for: device, in: hub)
    }

    /// What a window's screen says about the simulator's elements, which report positions in the
    /// newest view showing the simulator.
    enum Hold: Equatable {
        /// This many of the elements read sit on this window's screen.
        case holds(Int)
        /// The screen lists no elements: they're loading, or a newer window holds them.
        case empty
        /// The elements sit where the screen would be at the display's origin, as they do once the
        /// newest window showing the simulator has closed, until a new window takes them over.
        case stale
        /// The window doesn't show the simulator's screen.
        case noScreen
    }

    /// What the window's screen says about the simulator's elements.
    static func hold(_ window: WindowService.Window) -> Hold {
        guard let group = screenGroup(in: window.element), let screen = AX.frame(group) else { return .noScreen }
        return hold(screen: screen, elements: AX.children(group).prefix(24).compactMap(AX.frame))
    }

    /// Whether elements with these frames sit on `screen` or where it would be at the display's
    /// origin, both in global points. Elements scrolled out of view sit on neither.
    static func hold(screen: CGRect, elements: [CGRect]) -> Hold {
        let sized = elements.filter { $0.width >= 1 && $0.height >= 1 }
        guard !sized.isEmpty else { return .empty }
        let origin = CGRect(origin: .zero, size: screen.size)
        let onScreen = sized.filter { screen.contains(CGPoint(x: $0.midX, y: $0.midY)) }.count
        let atOrigin = sized.filter { origin.contains(CGPoint(x: $0.midX, y: $0.midY)) }.count
        return atOrigin > onScreen ? .stale : .holds(onScreen)
    }

    /// Which window to use, by what each candidate's screen says: the one with the most elements
    /// on its screen, the first on a tie, else the first whose screen is empty; nil when every
    /// candidate is stale or shows no screen, so a new window is needed.
    static func choose(_ holds: [Hold]) -> Int? {
        var best: (index: Int, onScreen: Int)?
        for (index, hold) in holds.enumerated() {
            if case .holds(let onScreen) = hold, onScreen > (best?.onScreen ?? -1) {
                best = (index, onScreen)
            }
        }
        return best?.index ?? holds.firstIndex(of: .empty)
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

    /// Notes that the helper opened `window` for the device at `date`, which takes its elements over.
    func markOpened(_ window: CGWindowID, for device: SimulatorInfo, at date: Date = Date()) {
        lock.withLock {
            opened[device.udid] = (window, date)
            holders[device.udid] = window
        }
    }

    /// Notes that `window` holds the device's elements.
    func noteHolder(_ window: CGWindowID, for device: SimulatorInfo) {
        lock.withLock { holders[device.udid] = window }
    }

    /// Whether the window that last held the device's elements is no longer among `windows`.
    func holderClosed(_ device: SimulatorInfo, among windows: [CGWindowID]) -> Bool {
        lock.withLock { holders[device.udid].map { !windows.contains($0) } ?? false }
    }

    /// The window the helper opened for the device in the last minute, if it did.
    func recentlyOpened(_ device: SimulatorInfo, now: Date = Date()) -> CGWindowID? {
        lock.withLock {
            guard let entry = opened[device.udid], now.timeIntervalSince(entry.date) < Self.reuseOpened else { return nil }
            return entry.window
        }
    }

    /// Opens a window for the device, or waits for the one another call is already opening.
    func openOnce(for device: SimulatorInfo, in hub: AppRef) async throws -> WindowService.Window {
        let task = lock.withLock {
            if let running = opening[device.udid] { return running }
            let task = Task { try await self.openWindow(for: device, in: hub).info.id }
            opening[device.udid] = task
            return task
        }
        let result = await task.result
        lock.withLock {
            if opening[device.udid] == task { opening[device.udid] = nil }
        }
        let id = try result.get()
        guard let window = try WindowService.windows(of: hub).first(where: { $0.info.id == id }) else {
            throw RPCError(code: RPCErrorCode.failed, message: "Device Hub closed the window it opened for \(device.name).")
        }
        return window
    }

    /// Opens a main window without bringing Device Hub forward and shows the device in it, then
    /// moves the device into a window of its own where Device Hub offers that. The user's own main
    /// window is left as it was.
    func openWindow(for device: SimulatorInfo, in hub: AppRef) async throws -> WindowService.Window {
        let existing = try WindowService.windows(of: hub)
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
        var window = try WindowService.windows(of: hub).first { $0.info.id == main.info.id } ?? main
        if let popOut = Self.button(named: "Open in New Window", in: main.element), AX.perform(popOut, "AXPress") == .success,
           let own = try? await waitForWindow(of: hub, excluding: before, timeout: 5, where: Self.isDeviceWindow) {
            window = own
        }
        remember(window, for: device)
        markOpened(window.info.id, for: device)
        return window
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
