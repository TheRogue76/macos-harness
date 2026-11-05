import Foundation
import HarnessCore
import HarnessDBus
import HarnessProtocol
import Synchronization

/// A tray icon through StatusNotifierItem, with its menu through DBusMenu: what KDE, Sway's
/// bars and GNOME's AppIndicator extension show in the panel.
public final class TrayIcon: Sendable {
    /// One line of the menu.
    public struct Item: Sendable, Equatable {
        public var label: String
        public var enabled: Bool
        public var separator: Bool
        /// What choosing it does, by name; nil for a line that only informs.
        public var action: String?

        public init(_ label: String, enabled: Bool = true, action: String? = nil) {
            self.label = label
            self.enabled = enabled
            separator = false
            self.action = action
        }

        public static let separatorLine = Item(separator: ())

        private init(separator: Void) {
            label = ""
            enabled = true
            self.separator = true
            action = nil
        }
    }

    /// What the icon shows.
    public struct Look: Sendable, Equatable {
        public var tooltip: String
        public var attention: Bool
        public var items: [Item]

        public init(tooltip: String, attention: Bool, items: [Item]) {
            self.tooltip = tooltip
            self.attention = attention
            self.items = items
        }
    }

    static let itemPath = "/StatusNotifierItem"
    static let menuPath = "/MenuBar"
    static let itemInterface = "org.kde.StatusNotifierItem"
    static let menuInterface = "com.canonical.dbusmenu"

    let connection: DBusConnection
    let busName: String
    let id: String
    let title: String
    let iconFolder: String
    /// Whether a click opens the menu, rather than calling `onActivate`.
    let isMenu: Bool
    private let look: Mutex<(look: Look, revision: UInt32)>
    private let onAction: @Sendable (String) -> Void
    private let onActivate: @Sendable (Int32, Int32) -> Void

    private init(
        connection: DBusConnection, busName: String, id: String, title: String, iconFolder: String, isMenu: Bool, look: Look,
        onAction: @escaping @Sendable (String) -> Void, onActivate: @escaping @Sendable (Int32, Int32) -> Void
    ) {
        self.connection = connection
        self.busName = busName
        self.id = id
        self.title = title
        self.iconFolder = iconFolder
        self.isMenu = isMenu
        self.look = Mutex((look, 1))
        self.onAction = onAction
        self.onActivate = onActivate
    }

    /// Shows the icon, registering it with the panel's watcher; fails when no panel shows tray
    /// icons (plain GNOME without the AppIndicator extension). A click calls `onActivate` with
    /// where it was, as the panel reports it (0, 0 when it doesn't), or opens the menu when
    /// `isMenu`; the menu opens on a right-click either way.
    public static func show(
        id: String, title: String, isMenu: Bool, look: Look, onAction: @escaping @Sendable (String) -> Void,
        onActivate: @escaping @Sendable (Int32, Int32) -> Void
    ) async throws -> TrayIcon {
        let connection = try await DBusConnection.session()
        let busName = "org.kde.StatusNotifierItem-\(getpid())-1"
        let folder = try Self.writeIcons()
        let icon = TrayIcon(
            connection: connection, busName: busName, id: id, title: title, iconFolder: folder, isMenu: isMenu, look: look,
            onAction: onAction, onActivate: onActivate
        )
        connection.export(itemPath) { [weak icon] message in icon?.answerItem(message) }
        connection.export(menuPath) { [weak icon] message in icon?.answerMenu(message) }
        do {
            _ = try await connection.call(
                "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName", [.string(busName), .uint32(4)]
            )
            _ = try await connection.call(
                "org.kde.StatusNotifierWatcher", "/StatusNotifierWatcher", "org.kde.StatusNotifierWatcher",
                "RegisterStatusNotifierItem", [.string(busName)]
            )
        } catch {
            connection.close()
            throw error
        }
        return icon
    }

    /// Changes what the icon shows and what its menu holds.
    public func update(_ next: Look) {
        let (previous, revision) = look.withLock { state -> (Look, UInt32) in
            let previous = state.look
            if previous != next { state = (next, state.revision + 1) }
            return (previous, state.revision)
        }
        guard previous != next else { return }
        if previous.attention != next.attention {
            signal(Self.itemPath, Self.itemInterface, "NewStatus", [.string(next.attention ? "NeedsAttention" : "Active")])
            signal(Self.itemPath, Self.itemInterface, "NewIcon", [])
        }
        if previous.tooltip != next.tooltip { signal(Self.itemPath, Self.itemInterface, "NewToolTip", []) }
        if previous.items != next.items {
            signal(Self.menuPath, Self.menuInterface, "LayoutUpdated", [.uint32(revision), .int32(0)])
        }
    }

    public func close() {
        connection.close()
    }

    private func signal(_ path: String, _ interface: String, _ member: String, _ body: [DBusValue]) {
        try? connection.emit(DBusMessage(kind: .signal, path: path, interface: interface, member: member, body: body))
    }

    func answerItem(_ message: DBusMessage) -> [DBusValue]? {
        switch (message.interface, message.member) {
        case ("org.freedesktop.DBus.Properties", "Get"):
            guard message.body.count == 2, let name = message.body[1].string, let value = itemProperties()[name] else { return nil }
            return [.variant(value)]
        case ("org.freedesktop.DBus.Properties", "GetAll"):
            return [.properties(itemProperties())]
        case ("org.freedesktop.DBus.Introspectable", "Introspect"):
            return [.string(Self.itemIntrospection)]
        case (_, "Activate"):
            let point = message.body.compactMap(\.int)
            onActivate(Int32(clamping: point.first ?? 0), Int32(clamping: point.dropFirst().first ?? 0))
            return []
        case (_, "SecondaryActivate"), (_, "ContextMenu"), (_, "Scroll"), (_, "ProvideXdgActivationToken"):
            return []
        default:
            return nil
        }
    }

    func itemProperties() -> [String: DBusValue] {
        let current = look.withLock { $0.look }
        let tooltip = DBusValue.structure([
            .string(""), .array(element: "(iiay)", []), .string(title), .string(current.tooltip),
        ])
        return [
            "Category": .string("ApplicationStatus"),
            "Id": .string(id),
            "Title": .string(title),
            "Status": .string(current.attention ? "NeedsAttention" : "Active"),
            "WindowId": .int32(0),
            "IconThemePath": .string(iconFolder),
            "IconName": .string(current.attention ? Self.attentionIcon : Self.icon),
            "AttentionIconName": .string(Self.attentionIcon),
            "OverlayIconName": .string(""),
            "IconPixmap": .array(element: "(iiay)", []),
            "AttentionIconPixmap": .array(element: "(iiay)", []),
            "OverlayIconPixmap": .array(element: "(iiay)", []),
            "AttentionMovieName": .string(""),
            "ToolTip": tooltip,
            "ItemIsMenu": .boolean(isMenu),
            "Menu": .objectPath(Self.menuPath),
        ]
    }

    func answerMenu(_ message: DBusMessage) -> [DBusValue]? {
        let (current, revision) = look.withLock { ($0.look, $0.revision) }
        switch (message.interface, message.member) {
        case (_, "GetLayout"):
            return [.uint32(revision), Self.layout(current.items)]
        case (_, "GetGroupProperties"):
            let ids = message.body.first?.elements?.compactMap(\.int) ?? []
            let all = Self.entries(current.items)
            let chosen = ids.isEmpty ? all : all.filter { ids.contains($0.id) }
            return [.array(element: "(ia{sv})", chosen.map { .structure([.int32(Int32($0.id)), .properties($0.properties)]) })]
        case (_, "GetProperty"):
            guard message.body.count == 2, let id = message.body[0].int, let name = message.body[1].string,
                  let value = Self.entries(current.items).first(where: { $0.id == id })?.properties[name] else { return nil }
            return [.variant(value)]
        case (_, "Event"):
            if message.body.count >= 2, message.body[1].string == "clicked", let id = message.body[0].int {
                activate(id, in: current.items)
            }
            return []
        case (_, "EventGroup"):
            for event in message.body.first?.elements ?? [] {
                guard let fields = event.fields, fields.count >= 2, fields[1].string == "clicked", let id = fields[0].int else { continue }
                activate(id, in: current.items)
            }
            return [.array(element: "i", [])]
        case (_, "AboutToShow"):
            return [.boolean(false)]
        case (_, "AboutToShowGroup"):
            return [.array(element: "i", []), .array(element: "i", [])]
        case ("org.freedesktop.DBus.Properties", "Get"):
            guard message.body.count == 2, let name = message.body[1].string, let value = Self.menuProperties[name] else { return nil }
            return [.variant(value)]
        case ("org.freedesktop.DBus.Properties", "GetAll"):
            return [.properties(Self.menuProperties)]
        case ("org.freedesktop.DBus.Introspectable", "Introspect"):
            return [.string(Self.menuIntrospection)]
        default:
            return nil
        }
    }

    private func activate(_ id: Int, in items: [Item]) {
        guard id > 0, id <= items.count, let action = items[id - 1].action, items[id - 1].enabled else { return }
        onAction(action)
    }

    static let menuProperties: [String: DBusValue] = [
        "Version": .uint32(3), "TextDirection": .string("ltr"), "Status": .string("normal"), "IconThemePath": .array(element: "s", []),
    ]

    /// Each line of the menu with its DBusMenu id (its place, from 1) and properties.
    static func entries(_ items: [Item]) -> [(id: Int, properties: [String: DBusValue])] {
        items.enumerated().map { index, item in
            var properties: [String: DBusValue] = item.separator
                ? ["type": .string("separator")]
                : ["label": .string(item.label.replacingOccurrences(of: "_", with: "__")), "enabled": .boolean(item.enabled)]
            properties["visible"] = .boolean(true)
            return (index + 1, properties)
        }
    }

    /// The menu as DBusMenu's `(ia{sv}av)` tree: a root holding every line.
    static func layout(_ items: [Item]) -> DBusValue {
        let children = entries(items).map { entry in
            DBusValue.variant(.structure([.int32(Int32(entry.id)), .properties(entry.properties), .array(element: "v", [])]))
        }
        return .structure([.int32(0), .properties(["children-display": .string("submenu")]), .array(element: "v", children)])
    }

    static let icon = "\(HarnessProduct.linuxIconName)-symbolic"
    static let attentionIcon = "\(HarnessProduct.linuxIconName)-attention"

    /// The Control Tower glyph: Otto's one-colour glyph, as on the Mac's menu bar.
    static func glyph(color: String, dot: Bool) -> String {
        """
            <svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 18 18">
            <path d="M5.77 9.56 C5.34 10.69 6.33 11.36 5.48 12.38 C5.06 12.89 4.50 13.30 3.80 13.61" fill="none" stroke="\(color)" stroke-width="1.6" stroke-linecap="round"/>
            <path d="M3.71 13.80 Q3.51 14.80 2.51 14.56" fill="none" stroke="\(color)" stroke-width="1.05" stroke-linecap="round"/>
            <path d="M3.60 13.54 Q2.72 13.02 2.23 13.92" fill="none" stroke="\(color)" stroke-width="1.05" stroke-linecap="round"/>
            <path d="M7.88 9.79 C7.59 10.91 8.58 11.59 8.02 12.71 C7.85 13.16 7.65 13.61 7.45 14.06" fill="none" stroke="\(color)" stroke-width="1.6" stroke-linecap="round"/>
            <path d="M7.52 14.26 Q8.04 15.14 7.13 15.63" fill="none" stroke="\(color)" stroke-width="1.05" stroke-linecap="round"/>
            <path d="M7.26 14.15 Q6.26 14.35 6.50 15.35" fill="none" stroke="\(color)" stroke-width="1.05" stroke-linecap="round"/>
            <path d="M10.12 9.79 C10.41 10.91 9.42 11.59 9.98 12.71 C10.15 13.16 10.35 13.61 10.55 14.06" fill="none" stroke="\(color)" stroke-width="1.6" stroke-linecap="round"/>
            <path d="M10.74 14.15 Q11.74 14.35 11.50 15.35" fill="none" stroke="\(color)" stroke-width="1.05" stroke-linecap="round"/>
            <path d="M10.48 14.26 Q9.96 15.14 10.87 15.63" fill="none" stroke="\(color)" stroke-width="1.05" stroke-linecap="round"/>
            <path d="M12.23 9.56 C12.66 10.69 11.67 11.36 12.52 12.38 C12.94 12.89 13.50 13.30 14.20 13.61" fill="none" stroke="\(color)" stroke-width="1.6" stroke-linecap="round"/>
            <path d="M14.40 13.54 Q15.28 13.02 15.77 13.92" fill="none" stroke="\(color)" stroke-width="1.05" stroke-linecap="round"/>
            <path d="M14.29 13.80 Q14.49 14.80 15.49 14.56" fill="none" stroke="\(color)" stroke-width="1.05" stroke-linecap="round"/>
            <rect x="4" y="2.6" width="10" height="6.6" rx="2.1" fill="none" stroke="\(color)" stroke-width="1.5"/>
            <path d="M6.3 4.7 L7.8 5.9 L6.3 7.1" fill="none" stroke="\(color)" stroke-width="1.2" stroke-linecap="round" stroke-linejoin="round"/>
            \(dot ? "<circle cx=\"15\" cy=\"3.2\" r=\"3\" fill=\"#FF450F\"/>" : "")
            </svg>

            """
    }

    /// Writes the icons where the panel looks for them, as given by `IconThemePath`.
    static func writeIcons(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> String {
        let runtime = environment["XDG_RUNTIME_DIR"].flatMap { $0.isEmpty ? nil : $0 } ?? NSTemporaryDirectory()
        let folder = "\(runtime)/\(HarnessProduct.folderName)/icons"
        let apps = "\(folder)/hicolor/scalable/apps"
        try FileManager.default.createDirectory(atPath: apps, withIntermediateDirectories: true)
        for directory in [folder, apps] {
            try Data(glyph(color: "#bebebe", dot: false).utf8).write(to: URL(fileURLWithPath: "\(directory)/\(icon).svg"))
            try Data(glyph(color: "#bebebe", dot: true).utf8).write(to: URL(fileURLWithPath: "\(directory)/\(attentionIcon).svg"))
        }
        return folder
    }

    static let itemIntrospection = """
        <node><interface name="org.kde.StatusNotifierItem">
        <property name="Category" type="s" access="read"/><property name="Id" type="s" access="read"/>
        <property name="Title" type="s" access="read"/><property name="Status" type="s" access="read"/>
        <property name="WindowId" type="i" access="read"/><property name="IconThemePath" type="s" access="read"/>
        <property name="IconName" type="s" access="read"/><property name="IconPixmap" type="a(iiay)" access="read"/>
        <property name="OverlayIconName" type="s" access="read"/><property name="OverlayIconPixmap" type="a(iiay)" access="read"/>
        <property name="AttentionIconName" type="s" access="read"/><property name="AttentionIconPixmap" type="a(iiay)" access="read"/>
        <property name="AttentionMovieName" type="s" access="read"/><property name="ToolTip" type="(sa(iiay)ss)" access="read"/>
        <property name="ItemIsMenu" type="b" access="read"/><property name="Menu" type="o" access="read"/>
        <method name="ContextMenu"><arg name="x" type="i" direction="in"/><arg name="y" type="i" direction="in"/></method>
        <method name="Activate"><arg name="x" type="i" direction="in"/><arg name="y" type="i" direction="in"/></method>
        <method name="SecondaryActivate"><arg name="x" type="i" direction="in"/><arg name="y" type="i" direction="in"/></method>
        <method name="Scroll"><arg name="delta" type="i" direction="in"/><arg name="orientation" type="s" direction="in"/></method>
        <signal name="NewTitle"/><signal name="NewIcon"/><signal name="NewAttentionIcon"/><signal name="NewOverlayIcon"/>
        <signal name="NewToolTip"/><signal name="NewStatus"><arg name="status" type="s"/></signal>
        </interface></node>
        """

    static let menuIntrospection = """
        <node><interface name="com.canonical.dbusmenu">
        <property name="Version" type="u" access="read"/><property name="TextDirection" type="s" access="read"/>
        <property name="Status" type="s" access="read"/><property name="IconThemePath" type="as" access="read"/>
        <method name="GetLayout"><arg type="i" name="parentId" direction="in"/><arg type="i" name="recursionDepth" direction="in"/>
        <arg type="as" name="propertyNames" direction="in"/><arg type="u" name="revision" direction="out"/>
        <arg type="(ia{sv}av)" name="layout" direction="out"/></method>
        <method name="GetGroupProperties"><arg type="ai" name="ids" direction="in"/><arg type="as" name="propertyNames" direction="in"/>
        <arg type="a(ia{sv})" name="properties" direction="out"/></method>
        <method name="GetProperty"><arg type="i" name="id" direction="in"/><arg type="s" name="name" direction="in"/>
        <arg type="v" name="value" direction="out"/></method>
        <method name="Event"><arg type="i" name="id" direction="in"/><arg type="s" name="eventId" direction="in"/>
        <arg type="v" name="data" direction="in"/><arg type="u" name="timestamp" direction="in"/></method>
        <method name="EventGroup"><arg type="a(isvu)" name="events" direction="in"/><arg type="ai" name="idErrors" direction="out"/></method>
        <method name="AboutToShow"><arg type="i" name="id" direction="in"/><arg type="b" name="needUpdate" direction="out"/></method>
        <method name="AboutToShowGroup"><arg type="ai" name="ids" direction="in"/><arg type="ai" name="updatesNeeded" direction="out"/>
        <arg type="ai" name="idErrors" direction="out"/></method>
        <signal name="ItemsPropertiesUpdated"><arg type="a(ia{sv})"/><arg type="a(ias)"/></signal>
        <signal name="LayoutUpdated"><arg type="u" name="revision"/><arg type="i" name="parent"/></signal>
        <signal name="ItemActivationRequested"><arg type="i" name="id"/><arg type="u" name="timestamp"/></signal>
        </interface></node>
        """
}
