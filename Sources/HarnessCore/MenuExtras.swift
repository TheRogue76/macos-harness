import AppKit
import ApplicationServices
import Foundation
import HarnessProtocol

/// What accessibility says about one menu bar extra: a status item on the right of the menu bar.
struct MenuExtraInfo: Equatable, Sendable {
    var title: String?
    /// The accessibility description, e.g. "Wi‑Fi".
    var details: String?
    var help: String?
    var identifier: String?
    var enabled: Bool

    init(title: String? = nil, details: String? = nil, help: String? = nil, identifier: String? = nil, enabled: Bool = true) {
        self.title = title
        self.details = details
        self.help = help
        self.identifier = identifier
        self.enabled = enabled
    }

    /// What to call it: most extras show only an icon, so its description comes before its title,
    /// then its help and identifier.
    var name: String { details ?? title ?? help ?? identifier ?? "unnamed" }

    /// Every name it answers to.
    var names: [String] { [details, title, help, identifier].compactMap { $0 } }
}

/// An app's menu bar extras (status items): finding one by name, opening it, and reading or
/// choosing from the menu it shows.
enum MenuExtras {
    /// Which extra a path starts at, and the menu titles below it.
    struct Location: Equatable {
        var index: Int
        var rest: [String]
    }

    /// What pressing an extra brought up.
    enum Shown {
        case menu(AXUIElement)
        case window(WindowService.Window)
        case nothing
    }

    static let escape = KeyCombo(keyCode: 53, flags: [], display: "⎋")

    /// `menu` with extras: the app's extras, or the items of one extra's menu.
    static func menu(_ params: MenuMethod.Params, app: AppRef, appElement: AXUIElement) async throws -> MenuMethod.Result {
        let elements = extraElements(of: appElement)
        let infos = elements.map(info)
        guard !params.path.isEmpty else {
            guard !infos.isEmpty else { throw noExtras(app.name) }
            return MenuMethod.Result(app: app, items: infos.map(item))
        }
        let location = try locate(params.path, in: infos, appName: app.name)
        let extra = elements[location.index]
        let name = infos[location.index].name
        let place = "the “\(name)” menu of \(app.name)"
        let depth = max(params.depth, 1)
        if let shown = menuChild(of: extra) {
            let items = try MenuService.items(at: location.rest, from: AX.children(shown), in: place)
            return MenuMethod.Result(app: app, items: items.map { MenuService.item($0, depth: depth) })
        }
        try await UserActivity.guardMenuOpening(name)
        switch try await open(extra, name: name, app: app, wantMenu: true) {
        case .menu(let menu):
            let read: [MenuMethod.Item]
            do {
                await waitUntilFilled(menu)
                read = try MenuService.items(at: location.rest, from: AX.children(menu), in: place).map { MenuService.item($0, depth: depth) }
            } catch {
                await close(menu, pid: app.pid)
                throw error
            }
            let closed = await close(menu, pid: app.pid)
            return MenuMethod.Result(app: app, items: read, notices: closed ? [] : [stillOpen(name)])
        case .window(let window):
            let closed = await close(window, extra: extra, app: app)
            return MenuMethod.Result(app: app, items: [], notices: [Notice(
                kind: "windowNotMenu",
                message: "“\(name)” shows a window rather than a menu, so there are no menu items to list. \(windowAdvice(window, name: name, closed: closed))"
            )])
        case .nothing:
            throw RPCError(
                code: RPCErrorCode.failed,
                message: "Pressing “\(name)” showed no menu or window\(hiddenNote(extra)), so it may have acted on the press by itself; check before pressing it again."
            )
        }
    }

    /// Waits up to a second for a menu that fills itself in after opening ("Loading…") to list the
    /// same items twice in a row.
    static func waitUntilFilled(_ menu: AXUIElement) async {
        func titles() -> [String] { AX.children(menu).map { AX.string($0, "AXTitle") ?? "" } }
        var previous = titles()
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(150))
            let current = titles()
            let loading = current.count <= 1 && current.allSatisfy { $0.hasPrefix("Loading") || $0.isEmpty }
            if current == previous, !loading { return }
            previous = current
        }
    }

    /// `menu-select` with extras: presses an extra, then chooses the item at the rest of the path
    /// in the menu it shows.
    static func select(_ params: MenuSelectMethod.Params) async throws -> ActionResult {
        let app = try await TargetResolver.app(Target(app: params.app))
        try WindowService.requireAccessibility()
        let appElement = AX.application(app.pid)
        AX.setTimeout(appElement, seconds: 2)
        let elements = extraElements(of: appElement)
        let infos = elements.map(info)
        let location = try locate(params.path, in: infos, appName: app.name)
        let extra = elements[location.index]
        let name = infos[location.index].name
        guard infos[location.index].enabled else {
            throw RPCError(code: RPCErrorCode.failed, message: "“\(name)” in \(app.name)'s menu bar extras is disabled right now.")
        }

        let window = try? await TargetResolver.resolve(Target(app: params.app)).window
        let before = params.diff ? window.map { Settle.Capture.take(window: $0, app: app) } : nil
        let windowsBefore = onScreenWindowIDs(of: app)
        let point = AX.frame(extra).map { Point(x: $0.midX.rounded(), y: $0.midY.rounded()) }
        try await UserActivity.guardMenuOpening(name)
        let started = Date()
        var result: ActionResult
        switch try await open(extra, name: name, app: app, wantMenu: !location.rest.isEmpty) {
        case .menu(let menu):
            let path = ([name] + location.rest).joined(separator: " › ")
            var notices = try await choose(location.rest, in: menu, name: name, app: app)
            if UserActivity.typed(since: started) {
                notices.append(Notice(kind: "userTyped", message: "The user typed while “\(name)”'s menu was open; some keystrokes may have gone to it."))
            }
            result = ActionResult(
                app: app, window: window?.info, element: nil, performed: "chose \(path) in \(app.name)'s menu bar extras",
                via: "AX", notices: notices, screenPoint: point
            )
            if let before, let window {
                await Settle.finish(&result, before: before, window: window, app: app)
            } else if params.diff {
                result.notices += await openedWindows(of: app, besides: windowsBefore)
            }
        case .window(let opened):
            guard location.rest.isEmpty else {
                let closed = await close(opened, extra: extra, app: app)
                throw RPCError(
                    code: RPCErrorCode.failed,
                    message: "“\(name)” shows a window rather than a menu, so there's no “\(location.rest[0])” to choose from a menu. \(windowAdvice(opened, name: name, closed: closed))"
                )
            }
            result = ActionResult(
                app: app, window: opened.info, element: nil, performed: "opened “\(name)” in \(app.name)'s menu bar extras", via: "AX",
                notices: [Notice(kind: "windowOpened", message: "Opened window \(opened.info.id) “\(opened.info.title)”; act on it with that window ID.")],
                screenPoint: point
            )
            if params.diff { await listContents(of: opened, app: opened.info.app, into: &result, since: started) }
        case .nothing:
            guard location.rest.isEmpty else {
                throw RPCError(
                    code: RPCErrorCode.failed,
                    message: "Pressing “\(name)” showed no menu\(hiddenNote(extra)), so “\(location.rest[0])” couldn't be chosen; it may have acted on the press by itself."
                )
            }
            result = ActionResult(
                app: app, window: window?.info, element: nil, performed: "pressed “\(name)” in \(app.name)'s menu bar extras", via: "AX",
                notices: [Notice(kind: "noMenu", message: "It showed no menu or window\(hiddenNote(extra)); check that it did what you expected.")],
                screenPoint: point
            )
            if let before, let window {
                await Settle.finish(&result, before: before, window: window, app: app)
            }
        }
        return result
    }

    /// Chooses the item at `path` in an extra's open menu, closing the menu when it can't.
    static func choose(_ path: [String], in menu: AXUIElement, name: String, app: AppRef) async throws -> [Notice] {
        var notices: [Notice] = []
        let item: AXUIElement
        let described = ([name] + path).joined(separator: " › ")
        do {
            guard !path.isEmpty else {
                let titles = AX.children(menu).compactMap { AX.string($0, "AXTitle") }.joined(separator: ", ")
                throw RPCError(code: RPCErrorCode.failed, message: "“\(name)” opens a menu; say which item to choose. Its items: \(titles)")
            }
            item = try MenuService.item(at: path, from: AX.children(menu), in: "the “\(name)” menu of \(app.name)")
            guard (AX.attribute(item, "AXEnabled") as? Bool) ?? true else {
                throw RPCError(code: RPCErrorCode.failed, message: "\(described) is disabled in \(app.name) right now.")
            }
            try ActionService.check(AX.perform(item, "AXPress"), doing: "choose \(described)", notices: &notices)
        } catch {
            await close(menu, pid: app.pid)
            throw error
        }
        await Settle.waitForMenuToClose(item)
        if isOpen(menu, pid: app.pid) {
            await close(menu, pid: app.pid)
            notices.append(Notice(kind: "menuStayedOpen", message: "The menu stayed open after choosing, so it was closed; check that the choice took."))
        }
        return notices
    }

    /// Which extra a path names first, and the titles left for its menu. With a single extra the
    /// path may leave its name out.
    static func locate(_ path: [String], in extras: [MenuExtraInfo], appName: String) throws -> Location {
        guard !extras.isEmpty else { throw noExtras(appName) }
        guard let first = path.first else {
            guard extras.count == 1 else {
                throw RPCError(code: RPCErrorCode.failed, message: "\(appName) has \(extras.count) menu bar extras; say which: \(listing(extras)).")
            }
            return Location(index: 0, rest: [])
        }
        let exact = exactMatches(first, in: extras)
        if extras.count == 1 {
            return Location(index: 0, rest: exact.isEmpty ? path : Array(path.dropFirst()))
        }
        let found = exact.isEmpty ? partialMatches(first, in: extras) : exact
        if found.isEmpty {
            throw RPCError(code: RPCErrorCode.failed, message: "No menu bar extra “\(first)” in \(appName). Its extras: \(listing(extras)).")
        }
        guard found.count == 1 else {
            let candidates = found.map { index in
                extras[index].name + (extras[index].identifier.map { " (id \($0))" } ?? "")
            }
            throw RPCError(
                code: RPCErrorCode.failed,
                message: "“\(first)” matches \(found.count) menu bar extras in \(appName): \(candidates.joined(separator: ", ")). Give its full name or id."
            )
        }
        return Location(index: found[0], rest: Array(path.dropFirst()))
    }

    /// The extras with a name equal to `query`, ignoring case and typographic punctuation.
    static func exactMatches(_ query: String, in extras: [MenuExtraInfo]) -> [Int] {
        let wanted = MenuService.normalize(query)
        return extras.indices.filter { index in extras[index].names.contains { MenuService.normalize($0) == wanted } }
    }

    /// The extras with a name containing `query`, ignoring case and typographic punctuation.
    static func partialMatches(_ query: String, in extras: [MenuExtraInfo]) -> [Int] {
        let wanted = MenuService.normalize(query)
        guard !wanted.isEmpty else { return [] }
        return extras.indices.filter { index in extras[index].names.contains { MenuService.normalize($0).contains(wanted) } }
    }

    /// The extras by name, with the identifier of any that share a name.
    static func listing(_ extras: [MenuExtraInfo]) -> String {
        extras.map { extra in
            let shared = extras.filter { $0.name == extra.name }.count > 1
            guard shared, let identifier = extra.identifier else { return extra.name }
            return "\(extra.name) (id \(identifier))"
        }.joined(separator: ", ")
    }

    static func noExtras(_ appName: String) -> RPCError {
        RPCError(
            code: RPCErrorCode.failed,
            message: "\(appName) has no menu bar extras. The system's own (Wi‑Fi, Sound, Battery, the clock…) belong to MenuBarAgent on recent macOS (Control Center on older versions), others to SystemUIServer; give one of those as the app."
        )
    }

    /// An extra as `menu` lists it.
    static func item(_ extra: MenuExtraInfo) -> MenuMethod.Item {
        MenuMethod.Item(
            title: extra.name, enabled: extra.enabled, shortcut: nil, mark: nil, isSeparator: false, hasSubmenu: false,
            children: [], identifier: extra.identifier == extra.name ? nil : extra.identifier
        )
    }

    /// The app's menu bar extras, in the order accessibility lists them.
    static func extraElements(of appElement: AXUIElement) -> [AXUIElement] {
        let extrasBar = AX.element(appElement, "AXExtrasMenuBar")
        let mainBar = AX.element(appElement, "AXMenuBar")
        let candidates = [extrasBar, mainBar].compactMap { $0 } + AX.children(appElement).filter { AX.role($0) == "AXMenuBar" }
        var bars: [AXUIElement] = []
        for bar in candidates where !bars.contains(where: { CFEqual($0, bar) }) {
            let isExtrasBar = extrasBar.map { CFEqual($0, bar) } ?? false
            let isMainMenu = mainBar.map { CFEqual($0, bar) } ?? false
            if isExtrasBar || !isMainMenu || holdsOnlyExtras(bar) { bars.append(bar) }
        }
        var found: [AXUIElement] = []
        for element in bars.flatMap(AX.children).flatMap(unwrapped) where !found.contains(where: { CFEqual($0, element) }) {
            found.append(element)
        }
        return found
    }

    /// The menu bar items inside a menu bar child: the child itself, or the items its wrapper
    /// groups hold (MenuBarAgent wraps each extra in a hosting view).
    static func unwrapped(_ element: AXUIElement) -> [AXUIElement] {
        guard AX.role(element) == "AXGroup" else { return [element] }
        var items: [AXUIElement] = []
        func visit(_ node: AXUIElement, _ depth: Int) {
            if AX.role(node) == "AXMenuBarItem" {
                items.append(node)
                return
            }
            guard depth < 3 else { return }
            AX.children(node).forEach { visit($0, depth + 1) }
        }
        visit(element, 0)
        return items.isEmpty ? [element] : items
    }

    /// Whether every item in a menu bar is a menu bar extra, as in apps that keep their extras in
    /// their only menu bar.
    static func holdsOnlyExtras(_ bar: AXUIElement) -> Bool {
        let items = AX.children(bar)
        return !items.isEmpty && items.allSatisfy { AX.string($0, "AXSubrole") == "AXMenuExtra" }
    }

    static func info(_ element: AXUIElement) -> MenuExtraInfo {
        MenuExtraInfo(
            title: AX.string(element, "AXTitle"), details: AX.string(element, "AXDescription"),
            help: AX.string(element, "AXHelp"), identifier: AX.string(element, "AXIdentifier"),
            enabled: (AX.attribute(element, "AXEnabled") as? Bool) ?? true
        )
    }

    /// Presses an extra and waits up to 1.5 s for the menu or window it shows. `wantMenu` prefers
    /// its show-menu action to its press, for extras that show their own menus.
    static func open(_ extra: AXUIElement, name: String, app: AppRef, wantMenu: Bool) async throws -> Shown {
        try OwnUI.refuse(app)
        let drawers = await MainActor.run { companions(of: app) }
        let owners = [app] + drawers
        let before = Set(owners.flatMap { onScreenWindowIDs(of: $0) })
        let offered = AX.actions(extra)
        let preferred = wantMenu && drawers.isEmpty ? ["AXShowMenu", "AXPress"] : ["AXPress", "AXShowMenu"]
        guard let action = preferred.first(where: { offered.contains($0) }) ?? (offered.isEmpty ? "AXPress" : nil) else {
            throw RPCError(code: RPCErrorCode.failed, message: "“\(name)” can't be pressed (its actions: \(offered.joined(separator: ", "))).")
        }
        AX.setTimeout(extra, seconds: 0.5)
        let error = AX.perform(extra, action)
        guard error == .success || error == .cannotComplete else {
            throw RPCError(code: RPCErrorCode.failed, message: "Couldn't open “\(name)” in \(app.name) (AX error \(error.rawValue)).")
        }
        let deadline = Date().addingTimeInterval(1.5)
        repeat {
            if let menu = openMenu(of: extra, app: app) { return .menu(menu) }
            let windows = owners.flatMap { (try? WindowService.windows(of: $0)) ?? [] }
            if let window = windows.first(where: { $0.info.onScreen && !before.contains($0.info.id) }) { return .window(window) }
            try? await Task.sleep(for: .milliseconds(100))
        } while Date() < deadline
        return .nothing
    }

    /// The extra's menu when accessibility lists its items.
    static func menuChild(of extra: AXUIElement) -> AXUIElement? {
        AX.children(extra).first { AX.role($0) == "AXMenu" && !AX.children($0).isEmpty }
    }

    /// The menu an extra opened: under the extra, or under the app for a menu it pops up itself.
    static func openMenu(of extra: AXUIElement, app: AppRef) -> AXUIElement? {
        if let menu = menuChild(of: extra) { return menu }
        let appElement = AX.application(app.pid)
        AX.setTimeout(appElement, seconds: 1)
        return AX.children(appElement).first { AX.role($0) == "AXMenu" && !AX.children($0).isEmpty }
    }

    /// Closes an open menu: cancels it through accessibility, then sends Escape if the app still
    /// shows it. Returns whether it closed.
    @discardableResult
    static func close(_ menu: AXUIElement, pid: pid_t) async -> Bool {
        guard !AX.children(menu).isEmpty else { return true }
        AX.perform(menu, "AXCancel")
        if await waitUntilClosed(menu, pid: pid) { return true }
        ActionService.post(escape, to: pid)
        return await waitUntilClosed(menu, pid: pid)
    }

    /// Closes a window an extra opened: Escape to the app, then pressing the extra again. Returns
    /// whether it closed.
    @discardableResult
    static func close(_ window: WindowService.Window, extra: AXUIElement, app: AppRef) async -> Bool {
        let owner = window.info.app
        ActionService.post(escape, to: owner.pid)
        if await waitUntilGone(window, app: owner) { return true }
        AX.perform(extra, "AXPress")
        return await waitUntilGone(window, app: owner)
    }

    /// Other apps that show an extra's window: on macOS 27, Control Center draws the panels of
    /// MenuBarAgent's extras (Battery, Wi‑Fi, Sound…) and Notification Center the clock's.
    @MainActor
    static func companions(of app: AppRef) -> [AppRef] {
        guard app.bundleIdentifier == "com.apple.MenuBarAgent" else { return [] }
        let drawers: Set<String> = ["com.apple.controlcenter", "com.apple.notificationcenterui"]
        return NSWorkspace.shared.runningApplications.filter { drawers.contains($0.bundleIdentifier ?? "") }.map {
            AppRef(name: $0.localizedName ?? "Control Center", bundleIdentifier: $0.bundleIdentifier, pid: $0.processIdentifier)
        }
    }

    static func waitUntilGone(_ window: WindowService.Window, app: AppRef) async -> Bool {
        let deadline = Date().addingTimeInterval(0.8)
        repeat {
            if !onScreenWindowIDs(of: app).contains(window.info.id) { return true }
            try? await Task.sleep(for: .milliseconds(100))
        } while Date() < deadline
        return false
    }

    /// What to do about a window an extra showed in place of a menu, once it's closed or not.
    static func windowAdvice(_ window: WindowService.Window, name: String, closed: Bool) -> String {
        guard closed else {
            return "It's still open as window \(window.info.id) “\(window.info.title)”: read it with a snapshot of that window and press its controls."
        }
        return "It was closed again; open it with menu-select --extras and just “\(name)” as the path (menu_select with extras=true over MCP) to get its elements as refs to press."
    }

    static func waitUntilClosed(_ menu: AXUIElement, pid: pid_t) async -> Bool {
        let deadline = Date().addingTimeInterval(0.6)
        repeat {
            if !isOpen(menu, pid: pid) { return true }
            try? await Task.sleep(for: .milliseconds(60))
        } while Date() < deadline
        return false
    }

    /// Whether a menu is showing: accessibility still lists its items and the app has a menu on
    /// screen.
    static func isOpen(_ menu: AXUIElement, pid: pid_t) -> Bool {
        !AX.children(menu).isEmpty && menuOnScreen(pid: pid)
    }

    /// Whether one of the app's own windows at the menu level is on screen.
    static func menuOnScreen(pid: pid_t) -> Bool {
        let level = Int(CGWindowLevelForKey(.popUpMenuWindow))
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.contains {
            ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == level
        }
    }

    static func onScreenWindowIDs(of app: AppRef) -> Set<UInt32> {
        Set(((try? WindowService.windows(of: app)) ?? []).filter(\.info.onScreen).map(\.info.id))
    }

    /// Notices for windows the app opened since `before`, waiting up to 1.5 s for one.
    static func openedWindows(of app: AppRef, besides before: Set<UInt32>) async -> [Notice] {
        let deadline = Date().addingTimeInterval(1.5)
        repeat {
            let opened = ((try? WindowService.windows(of: app)) ?? []).filter { $0.info.onScreen && !before.contains($0.info.id) }
            if !opened.isEmpty {
                return opened.map { Notice(kind: "windowOpened", message: "Opened window \($0.info.id) “\($0.info.title)”.") }
            }
            try? await Task.sleep(for: .milliseconds(150))
        } while Date() < deadline
        return []
    }

    /// Adds the elements of a window an extra opened to `result` as added changes with refs,
    /// waiting up to 1 s for it to fill in.
    static func listContents(of window: WindowService.Window, app: AppRef, into result: inout ActionResult, since started: Date) async {
        var nodes: [UINode] = []
        let deadline = Date().addingTimeInterval(1)
        repeat {
            nodes = contents(of: window, app: app)
            if !nodes.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(200))
        } while Date() < deadline
        result.changes = nodes.prefix(40).map { UIChange(kind: "added", node: $0) }
        result.moreChanges = max(0, nodes.count - 40)
        result.settledMilliseconds = max(1, Int(Date().timeIntervalSince(started) * 1000))
    }

    /// A window's elements with refs, as a flat list.
    static func contents(of window: WindowService.Window, app: AppRef) -> [UINode] {
        let raw = AXReader(maxNodes: 2000, maxDepth: 40, timeBudget: 1.5).read(window.content)
        let shaped = TreeShaper(space: window.space, maxNodes: 200, maxDepth: 30, ref: Snapshotter.registrar(for: app)).shape(raw)
        var nodes: [UINode] = []
        func flatten(_ node: UINode) {
            var copy = node
            copy.children = []
            copy.omitted = 0
            nodes.append(copy)
            node.children.forEach(flatten)
        }
        shaped.root.children.forEach(flatten)
        return nodes
    }

    /// A note for an extra that isn't on any screen, such as one the menu bar hides.
    static func hiddenNote(_ extra: AXUIElement) -> String {
        guard let frame = AX.frame(extra), PointerService.onScreen(frame) != nil else {
            return " (it isn't on screen; the menu bar may be hiding it)"
        }
        return ""
    }

    static func stillOpen(_ name: String) -> Notice {
        Notice(kind: "menuOpen", message: "“\(name)”'s menu may still be open; it closes on the next click or Escape.")
    }
}
