import AppKit
import ApplicationServices
import Foundation
import HarnessProtocol

/// Reads an app's menu bar, one menu path at a time.
public enum MenuService {
    public static func menu(_ params: MenuMethod.Params) async throws -> MenuMethod.Result {
        let app = try await TargetResolver.app(Target(app: params.app))
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
        let frontmost = await AppControl.frontmostPID()
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

    /// Symbols for the private-use and control characters AX reports for special keys.
    static let specialCharacters: [UInt32: String] = [
        0xF700: "↑", 0xF701: "↓", 0xF702: "←", 0xF703: "→", 0xF728: "⌦", 0xF729: "↖", 0xF72B: "↘",
        0xF72C: "⇞", 0xF72D: "⇟", 0x08: "⌫", 0x7F: "⌫", 0x03: "↩", 0x0D: "↩", 0x1B: "⎋", 0x09: "⇥", 0x20: "Space",
    ]

    /// The item's keyboard shortcut, like "⌃⌥⇧⌘K".
    static func shortcut(_ element: AXUIElement) -> String? {
        var key = AX.attribute(element, "AXMenuItemCmdChar").flatMap { ($0 as? String) }.flatMap { raw -> String? in
            guard let scalar = raw.unicodeScalars.first else { return nil }
            if let symbol = specialCharacters[scalar.value] { return symbol }
            if (0xF704...0xF70F).contains(scalar.value) { return "F\(scalar.value - 0xF703)" }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed.uppercased()
        }
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
