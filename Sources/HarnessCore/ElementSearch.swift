import ApplicationServices
import CoreGraphics
import Foundation
import HarnessProtocol

/// Finds elements in a raw AX tree by text, role and identifier.
public enum ElementSearch {
    public struct Hit {
        public var raw: RawNode
        /// Labels of the nearest labeled ancestors, outermost first.
        public var path: [String]
        /// Visible part in global coordinates; nil when scrolled or clipped out of view.
        public var visible: CGRect?
    }

    /// Short role names from `snapshot` output, mapped back to AX roles and subroles.
    static let roleAliases: [String: (role: String, subrole: String?)] = [
        "text": ("AXStaticText", nil), "textfield": ("AXTextField", nil), "textarea": ("AXTextArea", nil),
        "checkbox": ("AXCheckBox", nil), "switch": ("AXCheckBox", "AXSwitch"), "radio": ("AXRadioButton", nil),
        "tab": ("AXRadioButton", "AXTabButton"), "popup": ("AXPopUpButton", nil), "menubutton": ("AXMenuButton", nil),
        "scroll": ("AXScrollArea", nil), "element": ("AXGenericElement", nil), "split": ("AXSplitGroup", nil),
        "disclosure": ("AXDisclosureTriangle", nil), "radiogroup": ("AXRadioGroup", nil), "tabs": ("AXTabGroup", nil),
        "combobox": ("AXComboBox", nil), "searchfield": ("AXTextField", "AXSearchField"), "link": ("AXLink", nil),
        "menuitem": ("AXMenuItem", nil), "row": ("AXRow", nil), "cell": ("AXCell", nil),
    ]

    public static func roleMatches(_ wanted: String, _ node: RawNode) -> Bool {
        let key = wanted.lowercased()
        if let alias = roleAliases[key] {
            guard node.role == alias.role else { return false }
            return alias.subrole.map { $0 == node.subrole } ?? true
        }
        let axName = wanted.hasPrefix("AX") ? wanted : "AX" + wanted
        return axName.caseInsensitiveCompare(node.role) == .orderedSame
            || axName.caseInsensitiveCompare(node.subrole ?? "") == .orderedSame
    }

    public static func matches(_ node: RawNode, _ selector: ElementSelector) -> Bool {
        let asksForWindow = selector.role?.lowercased() == "window"
        guard !selector.isEmpty, node.role != "AXWindow" || asksForWindow, !TreeShaper.noiseRoles.contains(node.role) else { return false }
        if let role = selector.role, !roleMatches(role, node) { return false }
        if let identifier = selector.identifier, identifier.lowercased() != node.identifier?.lowercased() { return false }
        if let text = selector.text?.lowercased() {
            let candidates = [node.label, node.value, node.identifier].compactMap { $0?.lowercased() }
            let hit = selector.exact ? candidates.contains(text) : candidates.contains { $0.contains(text) }
            if !hit { return false }
        }
        return true
    }

    public static func search(_ root: RawNode, for selector: ElementSelector, clip: CGRect, limit: Int) -> [Hit] {
        var hits: [Hit] = []
        var seen: Set<AnyHashable> = []
        func visit(_ node: RawNode, path: [String], clip: CGRect) {
            guard hits.count < limit else { return }
            if matches(node, selector), node.key.map({ seen.insert($0).inserted }) ?? true {
                let visible = node.frame?.visiblePart(in: clip)
                hits.append(Hit(raw: node, path: path, visible: visible))
            }
            let childClip = node.role == "AXScrollArea" ? (node.frame?.intersection(clip) ?? clip) : clip
            let name = node.role == "AXWindow" ? nil : node.label.map { "\(node.role.dropFirst(2).lowercased()) \"\($0.prefix(40))\"" }
            for child in node.children {
                visit(child, path: name.map { path + [$0] } ?? path, clip: childClip)
            }
        }
        visit(root, path: [], clip: clip)
        return hits
    }

    /// Picks the one element a selector means, preferring visible, actionable matches.
    /// Throws with the candidates when it's ambiguous.
    static func single(_ hits: [Hit], selector: ElementSelector, describe: (Hit) -> String) throws -> Hit {
        guard !hits.isEmpty else {
            throw RPCError(code: RPCErrorCode.failed, message: "Nothing matches \(describeSelector(selector)). Try `find` or `snapshot` to see what's there.")
        }
        var pool = hits
        let visible = pool.filter { $0.visible != nil }
        if !visible.isEmpty { pool = visible }
        let actionable = pool.filter { AX.interactiveRoles.contains($0.raw.role) || !TreeShaper.meaningfulActions($0.raw.actions).isEmpty }
        if !actionable.isEmpty { pool = actionable }
        if pool.count > 1, let text = selector.text?.lowercased() {
            let exact = pool.filter { [$0.raw.label, $0.raw.value, $0.raw.identifier].compactMap { $0?.lowercased() }.contains(text) }
            if !exact.isEmpty { pool = exact }
        }
        guard pool.count == 1 else {
            let listed = pool.prefix(6).map(describe).joined(separator: "; ")
            throw RPCError(
                code: RPCErrorCode.failed,
                message: "\(pool.count) elements match \(describeSelector(selector)): \(listed). Use one of these refs, or narrow it with --role or --id."
            )
        }
        return pool[0]
    }

    static func describeSelector(_ selector: ElementSelector) -> String {
        var parts: [String] = []
        if let text = selector.text { parts.append("“\(text)”") }
        if let role = selector.role { parts.append("role \(role)") }
        if let identifier = selector.identifier { parts.append("id \(identifier)") }
        return parts.isEmpty ? "that selector" : parts.joined(separator: ", ")
    }
}
