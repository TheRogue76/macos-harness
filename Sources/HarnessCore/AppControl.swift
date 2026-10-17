import AppKit
import ApplicationServices
import Foundation
import HarnessProtocol

/// Menus, windows and app lifecycle.
public enum AppControl {
    /// Chooses a menu item, or one from a menu bar extra, as one turn with the mouse and keyboard.
    public static func menuSelect(_ params: MenuSelectMethod.Params, context: ActionContext = .unattended) async throws -> ActionResult {
        let turn = try await context.takeTurn()
        do {
            var result = params.extras == true ? try await MenuExtras.select(params) : try await chooseFromMenuBar(params, context: context)
            if let notice = turn.notice { result.notices.insert(notice, at: 0) }
            ActionEffect.judge(&result, step: .menu, checked: params.diff && result.settledMilliseconds > 0)
            await context.endTurn(turn.token)
            return result
        } catch {
            await context.endTurn(turn.token)
            throw error
        }
    }

    static func chooseFromMenuBar(_ params: MenuSelectMethod.Params, context: ActionContext) async throws -> ActionResult {
        guard !params.path.isEmpty else {
            throw RPCError(code: RPCErrorCode.invalidParams, message: "Give the menu path, e.g. File \"Export as PDF…\".")
        }
        let app = try await TargetResolver.app(Target(app: params.app))
        try OwnUI.refuse(app)
        try WindowService.requireAccessibility()
        let appElement = AX.application(app.pid)
        AX.setTimeout(appElement, seconds: 2)
        var notices: [Notice] = []
        try await ActionService.checkKeyWindow(of: app, context: context, sending: params.path.joined(separator: " › "))

        let focusTaken = Date()
        var tookFocus = false
        if params.activate, context.backgroundOnly, await frontmostPID() != app.pid {
            notices.append(Notice(
                kind: "backgroundOnly",
                message: "\(app.name) wasn't brought to the front, since agents work in the background only here; items that act on its windows may be disabled until it is."
            ))
        } else if params.activate, await frontmostPID() != app.pid {
            try await UserActivity.guardFocusChange(for: app.name)
            tookFocus = true
            _ = AX.set(appElement, "AXFrontmost", kCFBooleanTrue)
            try? await Task.sleep(for: .milliseconds(300))
            if await frontmostPID() == app.pid {
                notices.append(Notice(kind: "activated", message: "Brought \(app.name) to the front (menu items act on its key window)."))
            } else {
                notices.append(Notice(kind: "notFrontmost", message: "Couldn't bring \(app.name) to the front; a system dialog may be in the way."))
            }
        }

        let window = try? await TargetResolver.resolve(Target(app: params.app)).window
        if let window { try await context.claim(window, app: app) }
        let before = params.diff ? window.map { Settle.Capture.take(window: $0, app: app) } : nil

        guard let items = AX.element(appElement, "AXMenuBar").map(AX.children) else {
            throw RPCError(
                code: RPCErrorCode.failed,
                message: "\(app.name) has no menu bar. If it's a menu bar app, choose from its menu bar extras instead (`menu-select --extras`, or extras=true over MCP)."
            )
        }
        let item = try MenuService.item(at: params.path, from: items, in: app.name)
        let path = params.path.joined(separator: " › ")
        guard (AX.attribute(item, "AXEnabled") as? Bool) ?? true else {
            let frontmost = await frontmostPID() == app.pid
            throw RPCError(code: RPCErrorCode.disabled, message: MenuService.disabledMessage(params.path, appName: app.name, frontmost: frontmost))
        }
        try ActionService.check(AX.perform(item, "AXPress"), doing: "choose \(path)", notices: &notices)

        var result = ActionResult(app: app, window: window?.info, element: nil, performed: "chose \(path) in \(app.name)", via: "AX", notices: notices)
        if let before, let window {
            await Settle.finish(&result, before: before, window: window, app: app)
        }
        if tookFocus, let typed = UserActivity.typedSince(focusTaken, appName: app.name) {
            result.notices.append(typed)
        }
        return result
    }

    public static func window(_ params: WindowActionMethod.Params, context: ActionContext = .unattended) async throws -> ActionResult {
        let (app, window) = try await TargetResolver.resolve(params.target)
        try OwnUI.refuse(app)
        try await context.claim(window, app: app)
        let element = window.element
        AX.setTimeout(element, seconds: 2)
        var notices: [Notice] = []
        let name = "window \(window.info.id) “\(window.info.title)”"
        let performed: String

        switch params.action {
        case .activate:
            let grant = try await RealInput.Lease.shared.acquire(owner: context.owner, name: context.ownerName)
            defer { Task { await RealInput.Lease.shared.release(grant.token) } }
            if let wait = grant.wait, wait.seconds >= 0.3 {
                notices.append(Notice(
                    kind: "waitedForInput",
                    message: String(format: "Waited %.1f s for %@ to finish with the mouse and keyboard.", wait.seconds, wait.behind)
                ))
            }
            if await frontmostPID() != app.pid {
                try await UserActivity.guardFocusChange(for: app.name)
            }
            _ = AX.set(AX.application(app.pid), "AXFrontmost", kCFBooleanTrue)
            if window.info.minimized { _ = AX.set(element, "AXMinimized", kCFBooleanFalse) }
            let raised = AX.perform(element, "AXRaise")
            _ = AX.set(element, "AXMain", kCFBooleanTrue)
            switch raiseOutcome(raised) {
            case .raised:
                break
            case .unconfirmed:
                try ActionService.check(raised, doing: "raise \(name)", notices: &notices)
            case .focusInstead:
                _ = AX.set(element, "AXFocused", kCFBooleanTrue)
                guard await isInFront(window.info.id, of: app) else {
                    try ActionService.check(raised, doing: "raise \(name)", notices: &notices)
                    break
                }
                notices.append(Notice(
                    kind: "raisedByFocus",
                    message: "\(app.name) doesn't support raising windows through accessibility (AX error \(raised.rawValue)), so the window was made main and focused instead."
                ))
            }
            performed = "brought \(app.name) \(name) to the front"
        case .move:
            guard let x = params.x, let y = params.y else {
                throw RPCError(code: RPCErrorCode.invalidParams, message: "move needs --x and --y (global points, top-left).")
            }
            var point = CGPoint(x: x, y: y)
            let value = AXValueCreate(.cgPoint, &point)!
            try ActionService.check(AX.set(element, "AXPosition", value), doing: "move \(name)", notices: &notices)
            performed = "moved \(name) to (\(Int(x)), \(Int(y)))"
        case .resize:
            guard let width = params.width, let height = params.height else {
                throw RPCError(code: RPCErrorCode.invalidParams, message: "resize needs --width and --height (points).")
            }
            var size = CGSize(width: width, height: height)
            let value = AXValueCreate(.cgSize, &size)!
            try ActionService.check(AX.set(element, "AXSize", value), doing: "resize \(name)", notices: &notices)
            performed = "resized \(name) to \(Int(width))x\(Int(height))"
        case .minimize, .restore:
            let minimize = params.action == .minimize
            try ActionService.check(AX.set(element, "AXMinimized", minimize ? kCFBooleanTrue : kCFBooleanFalse), doing: "\(params.action.rawValue) \(name)", notices: &notices)
            performed = "\(minimize ? "minimized" : "restored") \(name)"
        case .fullscreen, .exitFullscreen:
            let on = params.action == .fullscreen
            try ActionService.check(AX.set(element, "AXFullScreen", on ? kCFBooleanTrue : kCFBooleanFalse), doing: "\(params.action.rawValue) \(name)", notices: &notices)
            performed = on ? "made \(name) full screen" : "took \(name) out of full screen"
        case .close:
            guard let button = AX.element(element, "AXCloseButton") else {
                throw RPCError(code: RPCErrorCode.failed, message: "\(name) has no close button.")
            }
            try ActionService.check(AX.perform(button, "AXPress"), doing: "close \(name)", notices: &notices)
            performed = "closed \(name)"
        }

        try? await Task.sleep(for: .milliseconds(300))
        let now = (try? WindowService.windows(of: app))?.first { $0.info.id == window.info.id }?.info
        if params.action == .close, now != nil {
            notices.append(Notice(kind: "stillOpen", message: "The window is still open; it may be asking to save changes. Take a snapshot to see."))
        }
        return ActionResult(app: app, window: now ?? window.info, element: nil, performed: performed, via: "AX", notices: notices)
    }

    @MainActor
    public static func launch(_ params: LaunchMethod.Params) async throws -> LaunchMethod.Result {
        if let device = Target.simulatorDevice(in: params.app) {
            throw RPCError(
                code: RPCErrorCode.invalidParams,
                message: "To start an app on a simulator, use `sim launch \(device) <bundle-id>` (MCP: simulator with action launch)."
            )
        }
        if let device = Target.androidDevice(in: params.app) {
            throw RPCError(
                code: RPCErrorCode.invalidParams,
                message: "To start an app on Android, use `android launch \(device) <package>` (MCP: android with action launch)."
            )
        }
        let started = Date()
        let files = params.open.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        let newInstance = params.newInstance == true
        let running = newInstance ? nil : try? AppResolver.resolve(params.app)
        let presets = try LaunchArguments.presets(params)
        var notices: [Notice] = []
        if let running, !params.arguments.isEmpty || !params.environment.isEmpty || !presets.isEmpty {
            notices.append(Notice(
                kind: "launchArgumentsIgnored",
                message: "\(running.name) was already running, so its launch arguments, environment, appearance and language weren't applied. Quit it first, or add --new-instance."
            ))
        }
        if let running, files.isEmpty {
            var windows: [WindowInfo] = []
            if params.activate {
                NSRunningApplication(processIdentifier: running.pid)?.activate()
                let switching = !WindowService.onOtherSpaces(of: running, besides: []).isEmpty
                let deadline = Date().addingTimeInterval(switching ? 2 : 0)
                repeat {
                    windows = (try? WindowService.windows(of: running))?.map(\.info) ?? []
                    if !windows.isEmpty || Date() >= deadline { break }
                    try? await Task.sleep(for: .milliseconds(100))
                } while true
            } else {
                windows = (try? WindowService.windows(of: running))?.map(\.info) ?? []
            }
            return LaunchMethod.Result(
                app: running, windows: windows, alreadyRunning: true, milliseconds: Int(Date().timeIntervalSince(started) * 1000),
                notices: notices.isEmpty ? nil : notices
            )
        }

        guard let url = appURL(for: params.app) else {
            throw RPCError(code: RPCErrorCode.failed, message: "Can't find an app called “\(params.app)”. Give its name as shown in /Applications, its bundle ID, or a path to the .app.")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = params.activate
        configuration.arguments = try LaunchArguments.all(params, engine: HiddenTrees.detect(bundle: url))
        configuration.environment = params.environment
        configuration.addsToRecentItems = false
        configuration.createsNewApplicationInstance = newInstance

        let limit = params.timeout + 15
        var launchedApp: NSRunningApplication?
        for attempt in 0..<3 where launchedApp == nil {
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(500)) }
            let outcome = LaunchOutcome()
            Task { @MainActor in
                do {
                    let app = files.isEmpty
                        ? try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
                        : try await NSWorkspace.shared.open(files, withApplicationAt: url, configuration: configuration)
                    outcome.finish(.success(app.processIdentifier))
                } catch {
                    outcome.finish(.failure(error))
                }
            }
            let waitUntil = Date().addingTimeInterval(limit)
            while outcome.result == nil, Date() < waitUntil {
                try? await Task.sleep(for: .milliseconds(100))
            }
            switch outcome.result {
            case .success(let pid)?:
                if let running = NSRunningApplication(processIdentifier: pid), !running.isTerminated { launchedApp = running }
            case .failure(let error)?:
                throw RPCError(code: RPCErrorCode.failed, message: "Couldn't launch \(url.lastPathComponent): \(error.localizedDescription)")
            case nil:
                throw RPCError(code: RPCErrorCode.failed, message: "\(url.deletingPathExtension().lastPathComponent) didn't finish launching within \(Int(limit)) s.")
            }
        }
        guard let launched = launchedApp else {
            throw RPCError(code: RPCErrorCode.failed, message: "\(url.deletingPathExtension().lastPathComponent) quit right after launching, three times.")
        }
        let app = AppRef(
            name: launched.localizedName ?? url.deletingPathExtension().lastPathComponent,
            bundleIdentifier: launched.bundleIdentifier, pid: launched.processIdentifier
        )

        var windows: [WindowInfo] = []
        let deadline = Date().addingTimeInterval(params.timeout)
        while Date() < deadline {
            windows = (try? WindowService.windows(of: app))?.map(\.info) ?? []
            if !windows.isEmpty { break }
            if ScreenLock.isLocked {
                notices.append(Notice(kind: "screenLocked", message: "The screen is locked, so \(app.name)'s windows won't show until it's unlocked."))
                break
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return LaunchMethod.Result(
            app: app, windows: windows, alreadyRunning: running != nil,
            milliseconds: Int(Date().timeIntervalSince(started) * 1000), notices: notices.isEmpty ? nil : notices
        )
    }

    /// An app by path, bundle ID, or name in the usual folders.
    @MainActor
    static func appURL(for query: String) -> URL? {
        let expanded = (query as NSString).expandingTildeInPath
        if expanded.hasSuffix(".app"), FileManager.default.fileExists(atPath: expanded) {
            return URL(fileURLWithPath: expanded)
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: query) {
            return url
        }
        let name = query.hasSuffix(".app") ? query : query + ".app"
        let folders = [
            "/Applications", "/System/Applications", "/System/Applications/Utilities", "/Applications/Utilities",
            "\(HarnessPaths.homeDirectory)/Applications", "/System/Library/CoreServices",
        ]
        for folder in folders {
            let path = "\(folder)/\(name)"
            if FileManager.default.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
        }
        for folder in folders {
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
            if let entry = entries.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                return URL(fileURLWithPath: "\(folder)/\(entry)")
            }
        }
        return nil
    }

    @MainActor
    public static func quit(_ params: QuitMethod.Params) async throws -> QuitMethod.Result {
        if let device = Target.simulatorDevice(in: params.app) {
            throw RPCError(
                code: RPCErrorCode.invalidParams,
                message: "To stop an app on a simulator, use `sim terminate \(device) <bundle-id>` (MCP: simulator with action terminate)."
            )
        }
        if let device = Target.androidDevice(in: params.app) {
            throw RPCError(
                code: RPCErrorCode.invalidParams,
                message: "To stop an app on Android, use `android terminate \(device) <package>` (MCP: android with action terminate)."
            )
        }
        guard let app = try? AppResolver.resolve(params.app) else {
            return QuitMethod.Result(app: AppRef(name: params.app, bundleIdentifier: nil, pid: 0), quit: true, message: "\(params.app) wasn't running.")
        }
        guard let running = NSRunningApplication(processIdentifier: app.pid) else {
            return QuitMethod.Result(app: app, quit: true, message: "\(app.name) wasn't running.")
        }
        _ = params.force ? running.forceTerminate() : running.terminate()
        let deadline = Date().addingTimeInterval(params.timeout)
        while Date() < deadline, !running.isTerminated {
            try? await Task.sleep(for: .milliseconds(150))
        }
        if running.isTerminated {
            return QuitMethod.Result(app: app, quit: true, message: "\(app.name) quit.")
        }
        return QuitMethod.Result(
            app: app, quit: false,
            message: "\(app.name) is still running; it may be asking to save changes. Take a snapshot to see, or use --force (unsaved work is lost)."
        )
    }

    public static func wait(_ params: WaitMethod.Params) async throws -> WaitMethod.Result {
        try checkRecognizable(params.element)
        if params.target.androidDevice != nil { return try await AndroidService.wait(params) }
        guard !params.element.isEmpty else {
            throw RPCError(code: RPCErrorCode.invalidParams, message: "Say what to wait for: --text, --role, --id or a ref.")
        }
        let started = Date()
        let deadline = started.addingTimeInterval(params.timeout)
        var lastWindow: WindowInfo?
        let target = await TargetResolver.target(params.target, holding: params.element.ref)
        let simulator = params.target.simulatorDevice == nil ? nil : try await TargetResolver.resolve(params.target)
        repeat {
            var app = simulator?.app
            if app == nil { app = try? await MainActor.run(body: { try AppResolver.resolve(params.target.app) }) }
            if let app, simulator == nil { _ = await HiddenTrees.shared.prepare(app) }
            if let app, let window = try? simulator?.window ?? WindowService.resolve(target, app: app) {
                lastWindow = window.info
                let found = params.element.ocr == true
                    ? try await recognized(params.element, in: window, app: app)
                    : locate(params.element, in: window, app: app)
                if params.gone ? found == nil : found != nil {
                    return WaitMethod.Result(
                        satisfied: true, node: found, window: window.info,
                        milliseconds: Int(Date().timeIntervalSince(started) * 1000)
                    )
                }
            } else if params.gone {
                return WaitMethod.Result(satisfied: true, node: nil, window: nil, milliseconds: Int(Date().timeIntervalSince(started) * 1000))
            }
            try? await Task.sleep(for: .milliseconds(200))
        } while Date() < deadline
        return WaitMethod.Result(satisfied: false, node: nil, window: lastWindow, milliseconds: Int(Date().timeIntervalSince(started) * 1000))
    }

    /// Throws when a selector asks for text recognition without text to look for.
    static func checkRecognizable(_ selector: ElementSelector) throws {
        guard selector.ocr == true, selector.text?.isEmpty ?? true else { return }
        throw RPCError(code: RPCErrorCode.invalidParams, message: "Text recognition needs the text to look for (--text).")
    }

    /// The first place text recognition finds the selector's text in the window, as a node.
    static func recognized(_ selector: ElementSelector, in window: WindowService.Window, app: AppRef) async throws -> UINode? {
        try await OCRService.find(selector.text, exact: selector.exact, in: window, app: app).first.map { OCRService.node($0, index: 1) }
    }

    static func locate(_ selector: ElementSelector, in window: WindowService.Window, app: AppRef) -> UINode? {
        let shaper = TreeShaper(space: window.space, maxNodes: 1, maxDepth: 0, ref: Snapshotter.registrar(for: app))
        if let ref = selector.ref {
            guard let element = try? Snapshotter.element(for: ref, app: app) else { return nil }
            let resolved = ElementResolver.single(element, clip: window.space.frame)
            return shaper.makeNode(resolved.raw, visible: resolved.visible)
        }
        let raw = AXReader(maxNodes: 8000, maxDepth: 80, timeBudget: 2).read(window.content)
        guard let hit = ElementSearch.search(raw, for: selector, clip: window.space.frame, limit: 1).first else { return nil }
        return shaper.makeNode(hit.raw, visible: hit.visible)
    }

    /// What to do after asking a window to raise: nothing more, report it unconfirmed, or fall
    /// back to focusing it and checking it came to the front.
    enum RaiseOutcome: Equatable {
        case raised, unconfirmed, focusInstead
    }

    static func raiseOutcome(_ error: AXError) -> RaiseOutcome {
        switch error {
        case .success: .raised
        case .cannotComplete: .unconfirmed
        default: .focusInstead
        }
    }

    /// Whether the app is frontmost with this window as its focused window, waiting briefly for
    /// the change to land.
    static func isInFront(_ id: CGWindowID, of app: AppRef, timeout: Double = 0.5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if await frontmostPID() == app.pid, WindowService.focusedWindowID(of: app) == id { return true }
            try? await Task.sleep(for: .milliseconds(50))
        } while Date() < deadline
        return false
    }

    static func frontmostPID() async -> pid_t? {
        await MainActor.run { frontmostProcessID() }
    }

    /// The frontmost app's process ID, with Device Hub looked up by its executable when
    /// LaunchServices lists it without one.
    @MainActor
    static func frontmostProcessID() -> pid_t? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return processID(of: app)
    }

    /// An app's process ID, with Device Hub looked up by its executable when LaunchServices lists
    /// it without one.
    @MainActor
    static func processID(of app: NSRunningApplication) -> pid_t {
        guard app.processIdentifier <= 0, app.bundleIdentifier == SimulatorScreens.deviceHubBundleID,
              let hub = SimulatorScreens.runningHub() else { return app.processIdentifier }
        return hub.pid
    }
}

/// The result of a launch that's still in progress.
final class LaunchOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<pid_t, Error>?

    var result: Result<pid_t, Error>? { lock.withLock { value } }

    func finish(_ result: Result<pid_t, Error>) {
        lock.withLock { value = result }
    }
}
