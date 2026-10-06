import AppKit
import ApplicationServices
import Foundation
import HarnessProtocol

/// Reads an app's menu bar. Menus are large (200–470 items in Apple's apps), so callers
/// walk down a path instead of reading everything.
public enum MenuService {
    public static func menu(_ params: MenuMethod.Params) async throws -> MenuMethod.Result {
        let app = try await MainActor.run { try AppResolver.resolve(params.app) }
        try WindowService.requireAccessibility()
        let appElement = AX.application(app.pid)
        AX.setTimeout(appElement, seconds: 1.5)
        guard let menuBar = AX.element(appElement, "AXMenuBar") else {
            throw RPCError(code: RPCErrorCode.failed, message: "\(app.name) has no menu bar.")
        }
        var current = AX.children(menuBar)
        for title in params.path {
            guard let match = current.first(where: { normalize(AX.string($0, "AXTitle")) == normalize(title) }) else {
                let available = current.compactMap { AX.string($0, "AXTitle") }.joined(separator: ", ")
                throw RPCError(code: RPCErrorCode.failed, message: "No menu item \"\(title)\" in \(app.name). Available: \(available)")
            }
            guard let submenu = AX.children(match).first(where: { AX.role($0) == "AXMenu" }) else {
                throw RPCError(code: RPCErrorCode.failed, message: "\"\(title)\" isn't a menu.")
            }
            current = AX.children(submenu)
        }
        let frontmost = await MainActor.run { NSWorkspace.shared.frontmostApplication?.processIdentifier }
        let notices = frontmost == app.pid ? [] : [Notice(
            kind: "notFrontmost",
            message: "\(app.name) isn't frontmost, so items that act on its key window show as disabled until it is."
        )]
        return MenuMethod.Result(app: app, items: current.map { item($0, depth: max(params.depth, 1)) }, notices: notices)
    }

    static func item(_ element: AXUIElement, depth: Int) -> MenuMethod.Item {
        let title = AX.string(element, "AXTitle") ?? ""
        let submenu = AX.children(element).first { AX.role($0) == "AXMenu" }
        let children = depth > 1 ? (submenu.map { AX.children($0).map { item($0, depth: depth - 1) } } ?? []) : []
        return MenuMethod.Item(
            title: title,
            enabled: (AX.attribute(element, "AXEnabled") as? Bool) ?? true,
            shortcut: shortcut(element),
            mark: AX.string(element, "AXMenuItemMarkChar"),
            isSeparator: title.isEmpty && submenu == nil,
            hasSubmenu: submenu != nil,
            children: children
        )
    }

    static let specialKeys: [Int: String] = [
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 117: "⌦",
        123: "←", 124: "→", 125: "↓", 126: "↑", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
    ]

    /// Builds "⌃⌥⇧⌘K" from the AX shortcut attributes.
    static func shortcut(_ element: AXUIElement) -> String? {
        var key = AX.string(element, "AXMenuItemCmdChar")?.uppercased()
        if key == nil, let code = AX.attribute(element, "AXMenuItemCmdVirtualKey") as? Int {
            key = specialKeys[code]
        }
        guard let key else { return nil }
        let modifiers = (AX.attribute(element, "AXMenuItemCmdModifiers") as? Int) ?? 0
        var prefix = ""
        if modifiers & 4 != 0 { prefix += "⌃" }
        if modifiers & 2 != 0 { prefix += "⌥" }
        if modifiers & 1 != 0 { prefix += "⇧" }
        if modifiers & 8 == 0 { prefix += "⌘" }
        return prefix + key
    }

    static func normalize(_ text: String?) -> String {
        (text ?? "").replacingOccurrences(of: "…", with: "...").trimmingCharacters(in: .whitespaces).lowercased()
    }
}
