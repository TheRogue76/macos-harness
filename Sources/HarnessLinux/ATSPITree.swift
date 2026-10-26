#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import HarnessCore
import HarnessDBus

/// What identifies an element on the accessibility bus: its app's bus name and its object path.
struct ATSPIKey: Hashable, Sendable {
    var bus: String
    var path: String
}

/// AT-SPI roles in the AX vocabulary the rest of the harness speaks.
enum ATSPIRoles {
    /// The AX role and subrole for an AT-SPI role number and states.
    static func ax(_ role: UInt32, states: ATSPIStates) -> (role: String, subrole: String?)? {
        switch role {
        case 43: return ("AXButton", nil)
        case 129: return ("AXMenuButton", nil)
        case 62: return ("AXCheckBox", "AXToggle")
        case 7: return ("AXCheckBox", nil)
        case 130: return ("AXCheckBox", "AXSwitch")
        case 44: return ("AXRadioButton", nil)
        case 40: return ("AXTextField", "AXSecureTextField")
        case 79: return ("AXTextField", nil)
        case 76: return ("AXComboBox", nil)
        case 61:
            if states.contains(.editable) {
                return states.contains(.multiLine) ? ("AXTextArea", nil) : ("AXTextField", nil)
            }
            return ("AXStaticText", nil)
        case 60: return ("AXTextArea", nil)
        case 29, 116, 81, 73, 122, 123: return ("AXStaticText", nil)
        case 83: return ("AXHeading", nil)
        case 88: return ("AXLink", nil)
        case 51: return ("AXSlider", nil)
        case 52: return ("AXIncrementor", nil)
        case 48: return ("AXScrollBar", nil)
        case 42: return ("AXProgressIndicator", nil)
        case 103, 114: return ("AXLevelIndicator", nil)
        case 11: return states.contains(.editable) ? ("AXComboBox", nil) : ("AXPopUpButton", nil)
        case 31, 98, 121: return ("AXList", nil)
        case 32, 90: return ("AXRow", nil)
        case 91: return ("AXRow", "AXOutlineRow")
        case 55, 92: return ("AXTable", nil)
        case 56: return ("AXCell", nil)
        case 10, 57, 47, 58: return ("AXCell", "AXColumnHeader")
        case 65, 66: return ("AXOutline", nil)
        case 34: return ("AXMenuBar", nil)
        case 33, 41: return ("AXMenu", nil)
        case 35, 8, 45, 59: return ("AXMenuItem", nil)
        case 38: return ("AXTabGroup", nil)
        case 37: return ("AXRadioButton", "AXTabButton")
        case 63: return ("AXToolbar", nil)
        case 27, 26, 13: return ("AXImage", nil)
        case 23, 69, 14: return ("AXWindow", "AXStandardWindow")
        case 16, 2, 19, 22, 9, 36: return ("AXWindow", "AXDialog")
        case 49: return ("AXScrollArea", nil)
        case 53: return ("AXSplitGroup", nil)
        case 95, 25: return ("AXWebArea", nil)
        case 109: return ("AXGroup", "AXDocumentArticle")
        case 64: return ("AXHelpTag", nil)
        case 12: return ("AXDateField", nil)
        case 75: return ("AXApplication", nil)
        case 50: return nil
        default: return ("AXGroup", nil)
        }
    }

    /// Roles whose checked state is their value.
    static let checkable: Set<UInt32> = [7, 8, 44, 45, 62, 130, 37]
    /// Roles whose text is their value rather than their name.
    static let textual: Set<UInt32> = [29, 116, 81, 73, 122, 123, 61, 79, 40, 60, 76]
    /// Roles named by their text when they have no name of their own.
    static let editable: Set<UInt32> = [61, 79, 40, 60, 76]

    /// An element's AT-SPI action names in the AX vocabulary, once each. GTK's action-group names,
    /// like `win.close`, belong to the window or app rather than the element, so they're left out.
    static func actions(_ names: [String]) -> [String] {
        var seen: Set<String> = []
        return names.filter { !$0.isEmpty && !$0.contains(".") }.map(action).filter { seen.insert($0).inserted }
    }

    /// An AT-SPI action name in the AX vocabulary.
    static func action(_ name: String) -> String {
        switch name.lowercased() {
        case "click", "press", "activate", "toggle", "jump", "switch", "open", "select": "AXPress"
        case "showmenu", "show menu", "menu", "show context menu", "context menu": "AXShowMenu"
        case "increment": "AXIncrement"
        case "decrement": "AXDecrement"
        case "expand or contract", "expand", "collapse": "AXPress"
        default: name
        }
    }
}

/// An app's accessibility tree as raw nodes.
enum ATSPITree {
    struct Extras: Sendable {
        var frame: CGRect?
        var actions: [String] = []
        var value: Double?
        var text: String?
        var identifier: String?
    }

    /// The raw tree below `start`, with frames relative to its window, up to `limit` elements.
    static func read(
        _ items: [ATSPIItem], bus: String, from start: String, on connection: DBusConnection, limit: Int
    ) async -> (root: RawNode, count: Int)? {
        let chosen = select(items, from: start, limit: limit)
        guard !chosen.isEmpty else { return nil }
        let extras = await fetchExtras(chosen, bus: bus, on: connection)
        guard let root = assemble(items, chosen: chosen, bus: bus, from: start, extras: extras) else { return nil }
        return (root, chosen.count)
    }

    /// The elements below `start` that are showing, breadth first, up to `limit`.
    static func select(_ items: [ATSPIItem], from start: String, limit: Int) -> [ATSPIItem] {
        let byPath = Dictionary(items.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let children = ATSPI.children(of: items)
        let showingKnown = items.contains { $0.states.contains(.showing) }
        var chosen: [ATSPIItem] = []
        var queue = [start][...]
        while let path = queue.popFirst(), chosen.count < limit {
            guard let item = byPath[path] else { continue }
            if path != start, showingKnown, !item.states.contains(.showing) { continue }
            chosen.append(item)
            queue.append(contentsOf: children[path] ?? [])
        }
        return chosen
    }

    /// The raw tree of the chosen elements, counting the children left out as unread.
    static func assemble(
        _ items: [ATSPIItem], chosen: [ATSPIItem], bus: String, from start: String, extras: [String: Extras]
    ) -> RawNode? {
        let byPath = Dictionary(items.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let children = ATSPI.children(of: items)
        let showingKnown = items.contains { $0.states.contains(.showing) }
        let kept = Set(chosen.map(\.path))
        func build(_ item: ATSPIItem) -> RawNode? {
            let childPaths = children[item.path] ?? []
            let readChildren = childPaths.filter(kept.contains)
            let built = readChildren.compactMap { byPath[$0] }.compactMap(build)
            guard var node = makeNode(item, bus: bus, extras: extras[item.path] ?? Extras()) else {
                return built.count == 1 ? built[0] : nil
            }
            node.children = built
            node.unread = max(0, item.childCount - readChildren.count - hiddenCount(childPaths, byPath: byPath, showingKnown: showingKnown))
            return node
        }
        return byPath[start].flatMap(build)
    }

    private static func hiddenCount(_ paths: [String], byPath: [String: ATSPIItem], showingKnown: Bool) -> Int {
        guard showingKnown else { return 0 }
        return paths.filter { byPath[$0].map { !$0.states.contains(.showing) } ?? false }.count
    }

    /// The raw node for one element.
    static func makeNode(_ item: ATSPIItem, bus: String, extras: Extras) -> RawNode? {
        guard let (role, subrole) = ATSPIRoles.ax(item.role, states: item.states) else { return nil }
        let name = item.name.isEmpty ? nil : item.name
        let text = extras.text.flatMap { $0.isEmpty ? nil : $0 }
        let value: String?
        var title = name
        if ATSPIRoles.checkable.contains(item.role) {
            value = item.states.contains(.checked) || item.states.contains(.pressed) ? "1" : "0"
        } else if ATSPIRoles.editable.contains(item.role), role != "AXStaticText" {
            value = subrole == "AXSecureTextField" ? nil : text
        } else if ATSPIRoles.textual.contains(item.role) {
            value = text ?? name
            title = nil
        } else if let number = extras.value {
            value = number.rounded() == number ? String(Int(number)) : String(number)
        } else {
            value = nil
        }
        let description = item.description.isEmpty || item.description == item.name ? nil : item.description
        return RawNode(
            key: AnyHashable(ATSPIKey(bus: bus, path: item.path)), role: role, subrole: subrole, title: title,
            details: description, value: value, identifier: extras.identifier.flatMap { $0.isEmpty ? nil : $0 },
            enabled: item.states.contains(.sensitive) || item.states.contains(.enabled),
            focused: item.states.contains(.focused), selected: item.states.contains(.selected),
            actions: extras.actions, frame: extras.frame
        )
    }

    /// Frames, actions, values, text and identifiers for every item, asked for all at once.
    static func fetchExtras(_ items: [ATSPIItem], bus: String, on connection: DBusConnection) async -> [String: Extras] {
        await withTaskGroup(of: (String, Extras).self) { group in
            for item in items {
                group.addTask { (item.path, await extras(for: item, bus: bus, on: connection)) }
            }
            var result: [String: Extras] = [:]
            for await (path, extras) in group { result[path] = extras }
            return result
        }
    }

    private static func extras(for item: ATSPIItem, bus: String, on connection: DBusConnection) async -> Extras {
        let path = item.path
        let timeout = ATSPI.timeout
        async let extents = item.interfaces.contains("org.a11y.atspi.Component")
            ? try? connection.call(bus, path, "org.a11y.atspi.Component", "GetExtents", [.uint32(1)], timeout: timeout) : nil
        async let actions = item.interfaces.contains("org.a11y.atspi.Action")
            ? try? connection.call(bus, path, "org.a11y.atspi.Action", "GetActions", timeout: timeout) : nil
        async let value = item.interfaces.contains("org.a11y.atspi.Value")
            ? try? connection.property(bus, path, "org.a11y.atspi.Value", "CurrentValue", timeout: timeout) : nil
        async let text = item.interfaces.contains("org.a11y.atspi.Text")
            && (ATSPIRoles.editable.contains(item.role) || (ATSPIRoles.textual.contains(item.role) && item.name.isEmpty))
            ? try? connection.call(bus, path, "org.a11y.atspi.Text", "GetText", [.int32(0), .int32(-1)], timeout: timeout) : nil
        async let identifier = try? connection.property(bus, path, ATSPI.accessible, "AccessibleId", timeout: timeout)
        var extras = Extras()
        if let box = await extents?.first?.fields?.compactMap(\.int), box.count == 4 {
            extras.frame = CGRect(x: box[0], y: box[1], width: box[2], height: box[3])
        }
        extras.actions = ATSPIRoles.actions((await actions?.first?.elements ?? []).compactMap { $0.fields?.first?.string })
        extras.value = await value?.double
        extras.text = await text?.first?.string
        extras.identifier = await identifier?.string
        return extras
    }
}
