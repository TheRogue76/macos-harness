import AppKit
import ApplicationServices
import Foundation
import HarnessProtocol

/// Menus, windows and app lifecycle.
public enum AppControl {
    public static func menuSelect(_ params: MenuSelectMethod.Params) async throws -> ActionResult {
        guard !params.path.isEmpty else {
            throw RPCError(code: RPCErrorCode.invalidParams, message: "Give the menu path, e.g. File \"Export as PDF…\".")
        }
        let app = try await MainActor.run { try AppResolver.resolve(params.app) }
        try WindowService.requireAccessibility()
        let appElement = AX.application(app.pid)
        AX.setTimeout(appElement, seconds: 2)
        var notices: [Notice] = []

        let focusTaken = Date()
        var tookFocus = false
        if params.activate, await frontmostPID() != app.pid {
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

        let window = try? WindowService.resolve(Target(app: params.app), app: app)
        let before = params.diff ? window.map { Settle.Capture.take(window: $0, app: app) } : nil

        guard var items = AX.element(appElement, "AXMenuBar").map(AX.children) else {
            throw RPCError(code: RPCErrorCode.failed, message: "\(app.name) has no menu bar.")
        }
        var item: AXUIElement?
        for (index, title) in params.path.enumerated() {
            guard let match = items.first(where: { MenuService.normalize(AX.string($0, "AXTitle")) == MenuService.normalize(title) }) else {
                let available = items.compactMap { AX.string($0, "AXTitle") }.filter { !$0.isEmpty }.joined(separator: ", ")
                throw RPCError(code: RPCErrorCode.failed, message: "No menu item “\(title)” in \(app.name). Available here: \(available)")
            }
            if index == params.path.count - 1 {
                item = match
            } else {
                guard let submenu = AX.children(match).first(where: { AX.role($0) == "AXMenu" }) else {
                    throw RPCError(code: RPCErrorCode.failed, message: "“\(title)” has no submenu.")
                }
                items = AX.children(submenu)
            }
        }
        let path = params.path.joined(separator: " › ")
        guard let item, (AX.attribute(item, "AXEnabled") as? Bool) ?? true else {
            throw RPCError(code: RPCErrorCode.failed, message: "\(path) is disabled in \(app.name) right now\(await frontmostPID() == app.pid ? "" : " (the app isn't frontmost)").")
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

    public static func window(_ params: WindowActionMethod.Params) async throws -> ActionResult {
        let app = try await MainActor.run { try AppResolver.resolve(params.target.app) }
        let window = try WindowService.resolve(params.target, app: app)
        let element = window.element
        AX.setTimeout(element, seconds: 2)
        var notices: [Notice] = []
        let name = "window \(window.info.id) “\(window.info.title)”"
        let performed: String

        switch params.action {
        case .activate:
            if await frontmostPID() != app.pid {
                try await UserActivity.guardFocusChange(for: app.name)
            }
            _ = AX.set(AX.application(app.pid), "AXFrontmost", kCFBooleanTrue)
            if window.info.minimized { _ = AX.set(element, "AXMinimized", kCFBooleanFalse) }
            try ActionService.check(AX.perform(element, "AXRaise"), doing: "raise \(name)", notices: &notices)
            _ = AX.set(element, "AXMain", kCFBooleanTrue)
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
        let started = Date()
        let files = params.open.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        let running = try? AppResolver.resolve(params.app)
        if let running, files.isEmpty, params.arguments.isEmpty, params.environment.isEmpty {
            if params.activate {
                NSRunningApplication(processIdentifier: running.pid)?.activate()
            }
            let windows = (try? WindowService.windows(of: running))?.map(\.info) ?? []
            return LaunchMethod.Result(app: running, windows: windows, alreadyRunning: true, milliseconds: 0)
        }

        guard let url = appURL(for: params.app) else {
            throw RPCError(code: RPCErrorCode.failed, message: "Can't find an app called “\(params.app)”. Give its name as shown in /Applications, its bundle ID, or a path to the .app.")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = params.activate
        configuration.arguments = params.arguments
        configuration.environment = params.environment
        configuration.addsToRecentItems = false

        let launched: NSRunningApplication
        do {
            launched = files.isEmpty
                ? try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
                : try await NSWorkspace.shared.open(files, withApplicationAt: url, configuration: configuration)
        } catch {
            throw RPCError(code: RPCErrorCode.failed, message: "Couldn't launch \(url.lastPathComponent): \(error.localizedDescription)")
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
            try? await Task.sleep(for: .milliseconds(200))
        }
        return LaunchMethod.Result(
            app: app, windows: windows, alreadyRunning: running != nil,
            milliseconds: Int(Date().timeIntervalSince(started) * 1000)
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
        let app = try AppResolver.resolve(params.app)
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
        guard !params.element.isEmpty else {
            throw RPCError(code: RPCErrorCode.invalidParams, message: "Say what to wait for: --text, --role, --id or a ref.")
        }
        let started = Date()
        let deadline = started.addingTimeInterval(params.timeout)
        var lastWindow: WindowInfo?
        repeat {
            if let app = try? await MainActor.run(body: { try AppResolver.resolve(params.target.app) }),
               let window = try? WindowService.resolve(params.target, app: app) {
                lastWindow = window.info
                let found = locate(params.element, in: window, app: app)
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

    static func locate(_ selector: ElementSelector, in window: WindowService.Window, app: AppRef) -> UINode? {
        let shaper = TreeShaper(window: window.info.frame.cgRect, maxNodes: 1, maxDepth: 0, ref: Snapshotter.registrar(for: app))
        if let ref = selector.ref {
            guard let element = try? Snapshotter.element(for: ref, app: app) else { return nil }
            let resolved = ElementResolver.single(element, clip: window.info.frame.cgRect)
            return shaper.makeNode(resolved.raw, visible: resolved.visible)
        }
        let raw = AXReader(maxNodes: 8000, maxDepth: 80, timeBudget: 2).read(window.element)
        guard let hit = ElementSearch.search(raw, for: selector, clip: window.info.frame.cgRect, limit: 1).first else { return nil }
        return shaper.makeNode(hit.raw, visible: hit.visible)
    }

    static func frontmostPID() async -> pid_t? {
        await MainActor.run { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    }
}
