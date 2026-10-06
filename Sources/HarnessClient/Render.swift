import Foundation
import HarnessProtocol

/// Compact text views of helper results, written for agents to read: one element per line,
/// refs first, coordinates last. Shared by the CLI and the MCP server.
public enum Render {
    public static func snapshot(_ result: SnapshotMethod.Result) -> String {
        var lines = [windowHeader(result.window) + " · \(result.shownCount) shown of \(result.readCount) read in \(result.milliseconds) ms"]
        lines += result.notices.map(notice)
        lines.append("Coordinates are window-relative points; @x,y is where to click.")
        tree(result.root, depth: 0, into: &lines)
        return lines.joined(separator: "\n")
    }

    public static func find(_ result: FindMethod.Result) -> String {
        var lines = [windowHeader(result.window)]
        lines += result.notices.filter { $0.kind != "notFrontmost" }.map(notice)
        if result.matches.isEmpty {
            lines.append("No matches.")
        }
        for match in result.matches {
            var line = node(match.node)
            if match.node.hit == nil { line += " (not visible: scrolled or clipped)" }
            if !match.path.isEmpty { line += "  in " + match.path.suffix(3).joined(separator: " › ") }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    public static func windows(_ result: WindowsMethod.Result) -> String {
        guard !result.windows.isEmpty else { return "No windows." }
        return result.windows.map { window in
            var states: [String] = []
            if window.focused { states.append("focused") }
            if window.main { states.append("main") }
            if window.minimized { states.append("minimized") }
            if !window.onScreen && !window.minimized { states.append("off screen") }
            if window.hasSheet { states.append("sheet open") }
            if let subrole = window.subrole, subrole != "AXStandardWindow" { states.append(shortRole(subrole)) }
            let frame = window.frame
            return "\(window.id)  \(window.app.name)  \"\(window.title)\"  \(Int(frame.width))x\(Int(frame.height)) at (\(Int(frame.x)),\(Int(frame.y)))"
                + (states.isEmpty ? "" : "  " + states.joined(separator: ", "))
        }.joined(separator: "\n")
    }

    public static func menu(_ result: MenuMethod.Result, path: [String]) -> String {
        var lines = ["\(result.app.name) menu" + (path.isEmpty ? " bar" : ": " + path.joined(separator: " › "))]
        lines += result.notices.map(notice)
        func visit(_ item: MenuMethod.Item, depth: Int) {
            let indent = String(repeating: "  ", count: depth + 1)
            if item.isSeparator {
                lines.append(indent + "───")
                return
            }
            var line = indent + (item.mark.map { "\($0) " } ?? "") + item.title
            if item.hasSubmenu { line += " ›" }
            if let shortcut = item.shortcut { line += "  \(shortcut)" }
            if !item.enabled { line += "  (disabled)" }
            lines.append(line)
            item.children.forEach { visit($0, depth: depth + 1) }
        }
        result.items.forEach { visit($0, depth: 0) }
        return lines.joined(separator: "\n")
    }

    static func windowHeader(_ window: WindowInfo) -> String {
        var states: [String] = []
        if window.focused { states.append("focused") }
        if window.minimized { states.append("minimized") }
        let state = states.isEmpty ? "" : " · " + states.joined(separator: ", ")
        return "\(window.app.name) (pid \(window.app.pid)) window \(window.id) \"\(window.title)\" \(Int(window.frame.width))x\(Int(window.frame.height))\(state)"
    }

    static func notice(_ notice: Notice) -> String {
        "! \(notice.message)"
    }

    static func tree(_ item: UINode, depth: Int, into lines: inout [String]) {
        lines.append(String(repeating: "  ", count: depth) + node(item))
        for child in item.children {
            tree(child, depth: depth + 1, into: &lines)
        }
    }

    /// `e12 button "Save" id=OKButton disabled @412,120`
    public static func node(_ node: UINode) -> String {
        var parts = [node.ref, shortRole(node.subrole.flatMap { subroleNames[$0] } ?? node.role)]
        if let label = node.label { parts.append(quote(label, limit: 80)) }
        if let value = node.value {
            if toggleRoles.contains(node.role) {
                parts.append(value == "1" ? "on" : value == "0" ? "off" : "value=\(quote(value, limit: 40))")
            } else if node.label == nil {
                parts.append(quote(value, limit: 120))
            } else {
                parts.append("= " + quote(value, limit: 80))
            }
        }
        if let identifier = node.identifier { parts.append("id=\(identifier)") }
        if node.enabled == false { parts.append("disabled") }
        if node.focused == true { parts.append("focused") }
        if node.selected == true { parts.append("selected") }
        let actions = node.actions.filter { $0 != "AXPress" }.map(shortAction)
        if !actions.isEmpty { parts.append("actions: " + actions.joined(separator: ", ")) }
        if let hit = node.hit, node.role != "AXWindow" { parts.append("@\(Int(hit.x)),\(Int(hit.y))") }
        if node.omitted > 0 { parts.append("(+\(node.omitted) more)") }
        return parts.joined(separator: " ")
    }

    static let toggleRoles: Set<String> = ["AXCheckBox", "AXRadioButton", "AXMenuItemCheckbox"]

    static let subroleNames: [String: String] = [
        "AXSwitch": "switch", "AXSearchField": "searchfield", "AXTabButton": "tab",
        "AXSecureTextField": "securefield", "AXToggle": "toggle",
    ]

    static let roleNames: [String: String] = [
        "AXStaticText": "text", "AXTextField": "textfield", "AXTextArea": "textarea", "AXCheckBox": "checkbox",
        "AXRadioButton": "radio", "AXPopUpButton": "popup", "AXMenuButton": "menubutton", "AXScrollArea": "scroll",
        "AXGenericElement": "element", "AXSplitGroup": "split", "AXDisclosureTriangle": "disclosure",
        "AXRadioGroup": "radiogroup", "AXTabGroup": "tabs", "AXComboBox": "combobox", "AXValueIndicator": "indicator",
    ]

    static func shortRole(_ role: String) -> String {
        if let name = roleNames[role] { return name }
        guard role.hasPrefix("AX") else { return role }
        let bare = role.dropFirst(2)
        return bare.prefix(1).lowercased() + bare.dropFirst()
    }

    static func shortAction(_ action: String) -> String {
        guard action.hasPrefix("AX") else { return action }
        return String(action.dropFirst(2)).lowercased()
    }

    static func quote(_ text: String, limit: Int) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ⏎ ")
        let clipped = flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
        return "\"\(clipped)\""
    }
}
