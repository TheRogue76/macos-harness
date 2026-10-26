import Foundation
import HarnessCore
import HarnessDBus
import HarnessProtocol

/// `menu` and `menu-select` on Linux desktop apps: a window's menu bar, as GTK 3, GTK 4's
/// `GtkPopoverMenuBar` and Qt show it, and the menu buttons GTK 4 apps put in their header bar
/// instead, whose menus exist only while they're open.
extension LinuxDesktop {
    /// A top-level menu: a menu bar's item, or a menu button and whether its menu is open.
    struct TopMenu {
        var node: RawNode
        var isButton: Bool

        /// The title: a menu button's label text, since GTK 4 names an open menu button after
        /// both its label and its menu ("More More").
        var title: String? {
            guard isButton, let text = firstText(below: node) else { return node.label }
            return text
        }
    }

    /// The first static text inside a node.
    static func firstText(below node: RawNode) -> String? {
        for child in node.children {
            if child.role == "AXStaticText", let text = child.value ?? child.title, !text.isEmpty { return text }
            if child.role != "AXMenu", let text = firstText(below: child) { return text }
        }
        return nil
    }

    public static func menu(_ params: MenuMethod.Params) async throws -> MenuMethod.Result {
        try refuseExtras(params.extras)
        var place = try await place(Target(app: params.app))
        var tree = try await tree(of: place, limit: 8000)
        let tops = topMenus(in: tree, items: place.items)
        guard !tops.isEmpty else {
            throw RPCError(code: RPCErrorCode.notFound, message: "\(place.ref.name)'s window has no menu bar or menu buttons.")
        }
        guard let first = params.path.first else {
            return MenuMethod.Result(app: place.ref, items: tops.map { top in
                var item = menuItem(top.node, depth: 0)
                item.title = top.title ?? item.title
                if top.isButton { item.hasSubmenu = true }
                return item
            })
        }
        guard let top = tops.first(where: { titleMatches($0.title, first) }) else {
            throw RPCError(code: RPCErrorCode.notFound, message: notFound(first, among: tops.compactMap(\.title)))
        }
        let (opened, menu): (Bool, RawNode?)
        (place, tree, menu, opened) = try await open(top, in: place, tree: tree)
        let listed: Result<[MenuMethod.Item], any Error> = Result {
            guard var current = menu else {
                throw RPCError(code: RPCErrorCode.failed, message: "\(first) didn't open a menu.")
            }
            for title in params.path.dropFirst() {
                let items = menuItems(of: current)
                guard let item = items.first(where: { titleMatches($0, title) }) else {
                    throw RPCError(code: RPCErrorCode.notFound, message: notFound(title, among: items.compactMap(\.label)))
                }
                guard let next = submenu(of: item) else {
                    throw RPCError(code: RPCErrorCode.failed, message: "“\(title)” has no submenu.")
                }
                current = next
            }
            return menuItems(of: current).map { menuItem($0, depth: max(params.depth, 1) - 1) }
        }
        if opened { try? await pressNode(top.node, in: place) }
        return MenuMethod.Result(app: place.ref, items: try listed.get())
    }

    public static func menuSelect(_ params: MenuSelectMethod.Params, context: ActionContext) async throws -> ActionResult {
        try refuseExtras(params.extras)
        guard let first = params.path.first else {
            throw RPCError(code: RPCErrorCode.invalidParams, message: "Give the menu path, e.g. File > Save.")
        }
        var place = try await place(Target(app: params.app))
        try await context.claim(WindowClaims.key(window: place.info.id), place: "\(place.ref.name)'s window “\(place.info.title)”")
        var tree = try await tree(of: place, limit: 8000)
        let before = tree
        let tops = topMenus(in: tree, items: place.items)
        guard let top = tops.first(where: { titleMatches($0.title, first) }) else {
            throw RPCError(code: RPCErrorCode.notFound, message: tops.isEmpty
                ? "\(place.ref.name)'s window has no menu bar or menu buttons." : notFound(first, among: tops.compactMap(\.title)))
        }
        var chosen = top.node
        if params.path.count > 1 {
            var menu: RawNode?
            var opened = false
            (place, tree, menu, opened) = try await open(top, in: place, tree: tree)
            do {
                for (index, title) in params.path.dropFirst().enumerated() {
                    guard let current = menu else {
                        throw RPCError(code: RPCErrorCode.failed, message: "\(params.path[index]) didn't open a menu.")
                    }
                    let items = menuItems(of: current)
                    guard let item = items.first(where: { titleMatches($0, title) }) else {
                        throw RPCError(code: RPCErrorCode.notFound, message: notFound(title, among: items.compactMap(\.label)))
                    }
                    if item.enabled == false {
                        throw RPCError(code: RPCErrorCode.disabled, message: "“\(title)” is disabled, so nothing happened.")
                    }
                    chosen = item
                    if index < params.path.count - 2 {
                        if submenu(of: item).map(menuItems(of:))?.isEmpty ?? true {
                            try await pressNode(item, in: place)
                            (place, tree, menu) = try await waitForMenu(place, after: item)
                        } else {
                            menu = submenu(of: item)
                        }
                    }
                }
            } catch {
                if opened { try? await pressNode(top.node, in: place) }
                throw error
            }
        }
        try await pressNode(chosen, in: place)
        let shaper = TreeShaper(window: place.frame, maxNodes: 1, maxDepth: 0, ref: registrar(place))
        let node = shaper.makeNode(chosen, visible: chosen.frame)
        var result = ActionResult(
            app: place.ref, window: place.info, element: node, performed: "chose \(params.path.joined(separator: " > "))", via: "at-spi"
        )
        if params.diff { await settle(&result, before: before, place: place) }
        return result
    }

    private static func refuseExtras(_ extras: Bool?) throws {
        if extras == true {
            throw RPCError(code: RPCErrorCode.failed, message: "Menu bar extras (status icons) on Linux aren't supported yet.")
        }
    }

    /// A top-level menu opened when it isn't: a menu button pressed, or a menu bar item pressed
    /// when its submenu isn't in the tree yet. Says whether it opened it.
    static func open(_ top: TopMenu, in place: Place, tree: RawNode) async throws -> (Place, RawNode, RawNode?, Bool) {
        if top.isButton {
            if isOpen(top.node) { return (place, tree, buttonMenu(top.node), false) }
            try await pressNode(top.node, in: place)
            let (fresh, freshTree, menu) = try await waitForMenu(place, button: top.node)
            return (fresh, freshTree, menu, true)
        }
        if let menu = submenu(of: top.node), !menuItems(of: menu).isEmpty { return (place, tree, menu, false) }
        guard top.node.actions.contains("AXPress") else {
            throw RPCError(
                code: RPCErrorCode.failed,
                message: "\(top.node.label ?? "That menu")'s menu opens only with a click, as GTK 4 menu bars' do, which Linux desktop apps can't do yet."
            )
        }
        try await pressNode(top.node, in: place)
        let (fresh, freshTree, menu) = try await waitForMenu(place, after: top.node)
        return (fresh, freshTree, menu, true)
    }

    /// The window read again until a menu button's menu, or the submenu a menu item opens, is
    /// open, for up to 4 s: a GTK app can be busy for a couple of seconds as a popover opens.
    static func waitForMenu(_ place: Place, button: RawNode? = nil, after item: RawNode? = nil) async throws -> (Place, RawNode, RawNode?) {
        let deadline = Date().addingTimeInterval(4)
        var fresh = place
        var tree: RawNode
        repeat {
            try await Task.sleep(for: .milliseconds(200))
            fresh.items = try await ATSPI.items(of: place.app.bus, on: place.connection)
            tree = try await self.tree(of: fresh, limit: 8000)
            if let button, let current = find(button.key, in: tree), isOpen(current), let menu = buttonMenu(current) {
                return (fresh, tree, menu)
            }
            if let item, let current = find(item.key, in: tree), let menu = submenu(of: current), !menuItems(of: menu).isEmpty {
                return (fresh, tree, menu)
            }
        } while Date() < deadline
        return (fresh, tree, nil)
    }

    static func find(_ key: AnyHashable?, in tree: RawNode) -> RawNode? {
        guard let key else { return nil }
        if tree.key == key { return tree }
        for child in tree.children {
            if let found = find(key, in: child) { return found }
        }
        return nil
    }

    /// Whether a menu button's menu is open: its toggle is on, or for other menu buttons, a menu
    /// with items shows inside it.
    static func isOpen(_ button: RawNode) -> Bool {
        if let toggle = button.children.first(where: { $0.role == "AXCheckBox" && $0.subrole == "AXToggle" }) {
            return toggle.value == "1"
        }
        return buttonMenu(button) != nil
    }

    /// The menu inside a menu button, where GTK 4 keeps its popover.
    static func buttonMenu(_ button: RawNode) -> RawNode? {
        var found: RawNode?
        func visit(_ node: RawNode) {
            guard found == nil else { return }
            if node.role == "AXMenu", !menuItems(of: node).isEmpty { found = node } else { node.children.forEach(visit) }
        }
        button.children.forEach(visit)
        return found
    }

    /// Presses a menu, menu item or menu button through AT-SPI.
    static func pressNode(_ node: RawNode, in place: Place) async throws {
        guard let key = node.key?.base as? ATSPIKey, let item = place.items.first(where: { $0.path == key.path }) else {
            throw RPCError(code: RPCErrorCode.failed, message: "That menu is no longer there; try again.")
        }
        let element = Element(bus: place.app.bus, item: item, connection: place.connection, name: "“\(node.label ?? "menu")”")
        try await press(element, node: node, in: place)
    }

    /// The window's menu bars' items, then its menu buttons.
    static func topMenus(in tree: RawNode, items: [ATSPIItem]) -> [TopMenu] {
        var bars: [TopMenu] = []
        var buttons: [TopMenu] = []
        func visit(_ node: RawNode) {
            if node.role == "AXMenuBar" {
                bars += node.children.filter { ["AXMenu", "AXMenuItem", "AXMenuBarItem"].contains($0.role) && $0.label != nil }
                    .map { TopMenu(node: $0, isButton: false) }
                return
            }
            if isMenuButton(node, items: items), node.label != nil {
                buttons.append(TopMenu(node: node, isButton: true))
                return
            }
            node.children.forEach(visit)
        }
        visit(tree)
        return bars + buttons
    }

    /// Whether a node opens a popup menu: AT-SPI's menu-button role, a button that says it has a
    /// popup, or GTK 4's `GtkMenuButton`, a button with no action of its own around a toggle
    /// with the same label.
    static func isMenuButton(_ node: RawNode, items: [ATSPIItem]) -> Bool {
        if node.role == "AXMenuButton" { return true }
        guard node.role == "AXButton" else { return false }
        if let key = node.key?.base as? ATSPIKey, let item = items.first(where: { $0.path == key.path }),
           item.states.contains(.hasPopup) {
            return true
        }
        return !node.actions.contains("AXPress") && node.children.contains { child in
            child.role == "AXCheckBox" && child.subrole == "AXToggle" && child.label == node.label
        }
    }

    /// A menu item's submenu: a menu inside it, or the item itself when it's a menu.
    static func submenu(of item: RawNode) -> RawNode? {
        if item.role == "AXMenu" { return item }
        return item.children.first { $0.role == "AXMenu" }
    }

    /// The items of a menu, looking through the groups toolkits wrap them in.
    static func menuItems(of menu: RawNode) -> [RawNode] {
        var items: [RawNode] = []
        func visit(_ node: RawNode, depth: Int) {
            for child in node.children {
                if ["AXMenuItem", "AXMenu"].contains(child.role) {
                    items.append(child)
                } else if depth < 12 {
                    visit(child, depth: depth + 1)
                }
            }
        }
        visit(menu, depth: 0)
        return items
    }

    static func menuItem(_ node: RawNode, depth: Int) -> MenuMethod.Item {
        let submenu = submenu(of: node)
        let children = depth > 0 ? (submenu.map(menuItems(of:)) ?? []).map { menuItem($0, depth: depth - 1) } : []
        return MenuMethod.Item(
            title: node.label ?? "", enabled: node.enabled ?? true, shortcut: nil, mark: node.value == "1" ? "✓" : nil,
            isSeparator: false, hasSubmenu: submenu.map { !menuItems(of: $0).isEmpty } ?? false, children: children
        )
    }

    /// Whether a node's title is `title`, ignoring case, mnemonic underscores and a trailing ellipsis.
    static func titleMatches(_ node: RawNode, _ title: String) -> Bool {
        titleMatches(node.label, title)
    }

    static func titleMatches(_ label: String?, _ title: String) -> Bool {
        func clean(_ text: String) -> String {
            var text = text.replacingOccurrences(of: "_", with: "").trimmingCharacters(in: .whitespaces)
            for suffix in ["…", "..."] where text.hasSuffix(suffix) { text = String(text.dropLast(suffix.count)) }
            return text.lowercased()
        }
        guard let label else { return false }
        return clean(label) == clean(title)
    }

    static func notFound(_ title: String, among titles: [String]) -> String {
        return "There's no “\(title)” here" + (titles.isEmpty ? "." : "; the choices are \(titles.joined(separator: ", ")).")
    }
}
