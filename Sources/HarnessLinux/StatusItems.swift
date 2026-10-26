import Foundation
import HarnessCore
import HarnessDBus
import HarnessProtocol

/// The user's session bus, where status icons and their menus live.
public actor SessionBus {
    public static let shared = SessionBus()

    private var current: DBusConnection?

    /// The connection, made on first use and again after it closes.
    public func connection() async throws -> DBusConnection {
        if let current, !current.isClosed { return current }
        do {
            let made = try await DBusConnection.session()
            current = made
            return made
        } catch {
            throw RPCError(code: RPCErrorCode.failed, message: "Can't reach the D-Bus session bus (\(error)); Linux desktop apps need a graphical session.")
        }
    }
}

/// A status icon, as StatusNotifierItem describes it.
struct StatusItem: Sendable, Equatable {
    var service: String
    var path: String
    var pid: Int32?
    var id: String
    var title: String
    /// The object path of its DBusMenu, when it has one.
    var menu: String?
    var process: String?

    /// What the icon is called: its title, else its ID.
    var name: String { title.isEmpty ? id : title }
}

/// An entry of a DBusMenu.
struct StatusMenuEntry: Sendable, Equatable {
    var id: Int32
    var label: String
    var enabled = true
    var visible = true
    var isSeparator = false
    /// ✓ or • when the entry is a checked toggle.
    var mark: String?
    var shortcut: String?
    var isSubmenu = false
    var children: [StatusMenuEntry] = []
}

/// Status icons (menu bar extras, on Linux) through StatusNotifierItem and DBusMenu.
enum StatusItems {
    static let interfaces = ["org.kde.StatusNotifierItem", "org.freedesktop.StatusNotifierItem"]
    static let dbusMenu = "com.canonical.dbusmenu"
    static let timeout = Duration.seconds(3)

    /// Every status icon: those the watcher knows, and any that only took a StatusNotifierItem
    /// name, as when no watcher runs.
    static func all(on connection: DBusConnection) async throws -> [StatusItem] {
        var places: [(service: String, path: String)] = []
        if let registered = try? await connection.property(
            "org.kde.StatusNotifierWatcher", "/StatusNotifierWatcher", "org.kde.StatusNotifierWatcher", "RegisteredStatusNotifierItems",
            timeout: timeout
        ) {
            places += (registered.elements ?? []).compactMap { $0.string }.map(location)
        }
        let names = try await connection.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "ListNames", timeout: timeout)
        for name in (names.first?.elements ?? []).compactMap(\.string)
        where name.hasPrefix("org.kde.StatusNotifierItem-") || name.hasPrefix("org.freedesktop.StatusNotifierItem-") {
            places.append((name, "/StatusNotifierItem"))
        }
        var seen: Set<String> = []
        let unique = places.filter { seen.insert("\($0.service)|\($0.path)").inserted }
        let items = await withTaskGroup(of: (Int, StatusItem?).self) { group in
            for (index, place) in unique.enumerated() {
                group.addTask { (index, await describe(place.service, path: place.path, on: connection)) }
            }
            var found: [(Int, StatusItem?)] = []
            for await item in group { found.append(item) }
            return found.sorted { $0.0 < $1.0 }.compactMap(\.1)
        }
        var owners: Set<String> = []
        return items.filter { owners.insert("\($0.pid ?? -1)|\($0.path)|\($0.id)").inserted }
    }

    /// A watcher entry, `service@/path` or just `service`, as a service and object path.
    static func location(_ entry: String) -> (service: String, path: String) {
        if let at = entry.firstIndex(of: "@") {
            return (String(entry[..<at]), String(entry[entry.index(after: at)...]))
        }
        if entry.hasPrefix("/") { return ("", entry) }
        return (entry, "/StatusNotifierItem")
    }

    static func describe(_ service: String, path: String, on connection: DBusConnection) async -> StatusItem? {
        guard !service.isEmpty else { return nil }
        var properties: [String: DBusValue]?
        for interface in interfaces {
            if let all = try? await connection.call(
                service, path, "org.freedesktop.DBus.Properties", "GetAll", [.string(interface)], timeout: timeout
            ).first?.dictionary, !all.isEmpty {
                properties = all
                break
            }
        }
        guard let properties else { return nil }
        let pid = try? await connection.call(
            "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "GetConnectionUnixProcessID", [.string(service)],
            timeout: timeout
        ).first?.int
        let menu = properties["Menu"]?.string.flatMap { $0 == "/" || $0.isEmpty ? nil : $0 }
        let processName = pid.flatMap { LinuxProcesses().snapshot(of: Int32($0)) }.map { snapshot in
            let script = snapshot.arguments.dropFirst().first { $0.hasSuffix(".py") || $0.hasSuffix(".js") }
            return ((script ?? snapshot.path) as NSString).lastPathComponent
        }
        return StatusItem(
            service: service, path: path, pid: pid.map(Int32.init), id: properties["Id"]?.string ?? "",
            title: properties["Title"]?.string ?? "", menu: menu, process: processName
        )
    }

    /// The icons a query means: a pid, or a name matched against the icons' titles and IDs and
    /// their processes. An empty query means them all.
    static func matching(_ query: String, in items: [StatusItem]) -> [StatusItem] {
        let wanted = query.trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty, wanted != "*" else { return items }
        if let pid = Int32(wanted) { return items.filter { $0.pid == pid } }
        func names(_ item: StatusItem) -> [String] { [item.title, item.id, item.process].compactMap { $0 }.filter { !$0.isEmpty } }
        let exact = items.filter { names($0).contains { LinuxApps.matches($0, wanted) } }
        if !exact.isEmpty { return exact }
        return items.filter { names($0).contains { $0.localizedCaseInsensitiveContains(wanted) } }
    }

    /// An icon's menu, after telling it the menu is about to show so a menu built on demand fills in.
    static func layout(of item: StatusItem, on connection: DBusConnection) async throws -> StatusMenuEntry {
        guard let menu = item.menu else {
            throw RPCError(code: RPCErrorCode.failed, message: "“\(item.name)” has no menu; choose it alone to activate it.")
        }
        _ = try? await connection.call(item.service, menu, dbusMenu, "AboutToShow", [.int32(0)], timeout: timeout)
        let reply = try await connection.call(
            item.service, menu, dbusMenu, "GetLayout", [.int32(0), .int32(-1), .array(element: "s", [])], timeout: timeout
        )
        guard reply.count == 2, let root = entry(from: reply[1]) else {
            throw RPCError(code: RPCErrorCode.failed, message: "“\(item.name)” sent a menu the harness can't read.")
        }
        return root
    }

    /// A DBusMenu `(ia{sv}av)` entry and its visible children.
    static func entry(from value: DBusValue) -> StatusMenuEntry? {
        guard let fields = value.unwrapped.fields, fields.count == 3, let id = fields[0].int else { return nil }
        let properties = fields[1].dictionary ?? [:]
        var entry = StatusMenuEntry(id: Int32(id), label: mnemonicFree(properties["label"]?.string ?? ""))
        entry.enabled = properties["enabled"]?.bool ?? true
        entry.visible = properties["visible"]?.bool ?? true
        entry.isSeparator = properties["type"]?.string == "separator"
        if let kind = properties["toggle-type"]?.string, properties["toggle-state"]?.int == 1 {
            entry.mark = kind == "radio" ? "•" : "✓"
        }
        if let keys = properties["shortcut"]?.elements?.first?.elements?.compactMap(\.string), !keys.isEmpty {
            entry.shortcut = keys.joined(separator: "+")
        }
        entry.children = (fields[2].elements ?? []).compactMap(entry(from:)).filter(\.visible)
        entry.isSubmenu = properties["children-display"]?.string == "submenu" || !entry.children.isEmpty
        return entry
    }

    /// A label without its mnemonic underscores (`_Save` is Save, `__` is a real underscore).
    static func mnemonicFree(_ label: String) -> String {
        var result = ""
        var pending = false
        for character in label {
            if character == "_", !pending {
                pending = true
                continue
            }
            result.append(character)
            pending = false
        }
        return result
    }

    static func menuItem(_ entry: StatusMenuEntry, depth: Int) -> MenuMethod.Item {
        MenuMethod.Item(
            title: entry.label, enabled: entry.enabled, shortcut: entry.shortcut, mark: entry.mark, isSeparator: entry.isSeparator,
            hasSubmenu: entry.isSubmenu, children: depth > 0 ? entry.children.map { menuItem($0, depth: depth - 1) } : []
        )
    }

    /// The icon a path starts with, and the rest of the path; the icon's name may be left out
    /// when the query means just one.
    static func pick(_ path: [String], from items: [StatusItem]) throws -> (StatusItem, [String]) {
        if let first = path.first, let item = items.first(where: { LinuxApps.matches($0.name, first) || LinuxApps.matches($0.id, first) }) {
            return (item, Array(path.dropFirst()))
        }
        if items.count == 1 { return (items[0], path) }
        let names = items.map(\.name).joined(separator: ", ")
        if let first = path.first {
            throw RPCError(code: RPCErrorCode.notFound, message: "No status icon called “\(first)”; the icons are \(names).")
        }
        throw RPCError(code: RPCErrorCode.invalidParams, message: "Say which status icon: \(names).")
    }

    /// The entry a path names below `root`.
    static func entry(at path: [String], in root: StatusMenuEntry, icon: String) throws -> StatusMenuEntry {
        var current = root
        for title in path {
            let choices = current.children.filter { !$0.isSeparator }
            guard let next = choices.first(where: { LinuxDesktop.titleMatches($0.label, title) }) else {
                throw RPCError(
                    code: RPCErrorCode.notFound,
                    message: "“\(icon)”'s menu has no “\(title)”; the choices are \(choices.map(\.label).joined(separator: ", "))."
                )
            }
            current = next
        }
        return current
    }
}

extension LinuxDesktop {
    static func appRef(for item: StatusItem) -> AppRef {
        AppRef(name: item.process ?? item.name, bundleIdentifier: item.id.isEmpty ? nil : item.id, pid: item.pid ?? -1)
    }

    /// `menu --extras`: the app's status icons, or what one's menu holds.
    static func statusMenu(_ params: MenuMethod.Params) async throws -> MenuMethod.Result {
        let connection = try await SessionBus.shared.connection()
        let all = try await StatusItems.all(on: connection)
        let items = StatusItems.matching(params.app, in: all)
        guard !items.isEmpty else {
            throw RPCError(code: RPCErrorCode.notFound, message: all.isEmpty
                ? "No app shows a status icon (StatusNotifierItem) here."
                : "No status icon belongs to “\(params.app)”; the icons are \(all.map(\.name).joined(separator: ", ")).")
        }
        if params.path.isEmpty, items.count > 1 || items[0].menu == nil {
            return MenuMethod.Result(app: appRef(for: items[0]), items: items.map { item in
                MenuMethod.Item(
                    title: item.name, enabled: true, shortcut: nil, mark: nil, isSeparator: false, hasSubmenu: item.menu != nil,
                    children: [], identifier: item.id.isEmpty ? nil : item.id
                )
            })
        }
        let (item, rest) = try StatusItems.pick(params.path, from: items)
        let root = try await StatusItems.layout(of: item, on: connection)
        let entry = try StatusItems.entry(at: rest, in: root, icon: item.name)
        return MenuMethod.Result(app: appRef(for: item), items: entry.children.map { StatusItems.menuItem($0, depth: max(params.depth, 1) - 1) })
    }

    /// `menu-select --extras`: chooses an entry of a status icon's menu, or activates the icon.
    static func statusSelect(_ params: MenuSelectMethod.Params) async throws -> ActionResult {
        let connection = try await SessionBus.shared.connection()
        let items = StatusItems.matching(params.app, in: try await StatusItems.all(on: connection))
        guard !items.isEmpty else {
            throw RPCError(code: RPCErrorCode.notFound, message: "No status icon belongs to “\(params.app)”.")
        }
        let (item, rest) = try StatusItems.pick(params.path, from: items)
        if rest.isEmpty {
            _ = try await connection.call(item.service, item.path, StatusItems.interfaces[0], "Activate", [.int32(0), .int32(0)], timeout: StatusItems.timeout)
            return ActionResult(app: appRef(for: item), window: nil, element: nil, performed: "activated “\(item.name)”", via: "status-notifier")
        }
        let root = try await StatusItems.layout(of: item, on: connection)
        let entry = try StatusItems.entry(at: rest, in: root, icon: item.name)
        guard entry.enabled else {
            throw RPCError(code: RPCErrorCode.disabled, message: "“\(entry.label)” is disabled, so nothing happened.")
        }
        guard let menu = item.menu else { throw RPCError(code: RPCErrorCode.failed, message: "“\(item.name)” has no menu.") }
        let now = UInt32(truncatingIfNeeded: Int(Date().timeIntervalSince1970))
        _ = try await connection.call(
            item.service, menu, StatusItems.dbusMenu, "Event", [.int32(entry.id), .string("clicked"), .variant(.int32(0)), .uint32(now)],
            timeout: StatusItems.timeout
        )
        return ActionResult(
            app: appRef(for: item), window: nil, element: nil, performed: "chose \(([item.name] + rest).joined(separator: " > "))",
            via: "dbusmenu"
        )
    }
}
