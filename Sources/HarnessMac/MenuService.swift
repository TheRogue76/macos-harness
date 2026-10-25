import AppKit
import ApplicationServices
import Foundation
import HarnessCore
import HarnessProtocol

/// Reads an app's menu bar, one menu path at a time.
public enum MenuService {
    /// Why a menu item can't be chosen while it's disabled; when the app isn't frontmost, that apps
    /// often enable commands for their windows only in front, and what works instead.
    static func disabledMessage(_ path: [String], appName: String, frontmost: Bool) -> String {
        let joined = path.joined(separator: " › ")
        guard !frontmost else { return "\(joined) is disabled in \(appName) right now." }
        let reason = "\(joined) is disabled in \(appName) right now. The app isn't frontmost, and apps often enable commands for their windows only while in front: choose it with the app brought forward (leave out --no-activate; activate=true over MCP)"
        guard let action = path.last.flatMap(windowAction(for:)) else { return reason + "." }
        return reason + ", or use `window \(action)` (the `window` tool with action=\(action)), which works without bringing it forward."
    }

    /// The `window` action that does what a menu item titled `title` does, if there is one.
    static func windowAction(for title: String) -> String? {
        switch title.trimmingCharacters(in: .whitespaces).lowercased() {
        case "close window", "close": "close"
        case "minimize", "minimise": "minimize"
        case "enter full screen", "toggle full screen", "full screen": "fullscreen"
        case "exit full screen": "exit-fullscreen"
        default: nil
        }
    }

    public static func menu(_ params: MenuMethod.Params, context: ActionContext = .unattended) async throws -> MenuMethod.Result {
        let app = try await TargetResolver.app(Target(app: params.app))
        try WindowService.requireAccessibility()
        let appElement = AX.application(app.pid)
        AX.setTimeout(appElement, seconds: 1.5)
        if params.extras == true {
            guard !params.path.isEmpty else { return try await MenuExtras.menu(params, app: app, appElement: appElement, context: context) }
            if params.real == true { return try await MenuExtras.menu(params, app: app, appElement: appElement, context: context) }
            let turn = try await context.takeTurn()
            do {
                var result = try await MenuExtras.menu(params, app: app, appElement: appElement, context: context)
                if let notice = turn.notice { result.notices.insert(notice, at: 0) }
                await context.endTurn(turn.token)
                return result
            } catch {
                await context.endTurn(turn.token)
                throw error
            }
        }
        guard let menuBar = AX.element(appElement, "AXMenuBar") else {
            throw RPCError(
                code: RPCErrorCode.failed,
                message: "\(app.name) has no menu bar. If it's a menu bar app, read its menu bar extras instead (`menu --extras`, or extras=true over MCP)."
            )
        }
        let current = try items(at: params.path, from: AX.children(menuBar), in: app.name)
        let frontmost = await AppControl.frontmostPID()
        let notices = frontmost == app.pid ? [] : [Notice(
            kind: "notFrontmost",
            message: "\(app.name) isn't frontmost, so items that act on its key window show as disabled until it is."
        )]
        return MenuMethod.Result(app: app, items: current.map { item($0, depth: max(params.depth, 1)) }, notices: notices)
    }

    /// The items of the menu at `path`, descending from `items` (a menu bar's or an open menu's);
    /// `place` names where they are in errors.
    static func items(at path: [String], from items: [AXUIElement], in place: String) throws -> [AXUIElement] {
        var current = items
        for title in path {
            guard let match = current.first(where: { normalize(AX.string($0, "AXTitle")) == normalize(title) }) else {
                let available = current.compactMap { AX.string($0, "AXTitle") }.joined(separator: ", ")
                throw RPCError(code: RPCErrorCode.notFound, message: "No menu item \"\(title)\" in \(place). Available: \(available)")
            }
            guard let submenu = AX.children(match).first(where: { AX.role($0) == "AXMenu" }) else {
                throw RPCError(code: RPCErrorCode.failed, message: "\"\(title)\" isn't a menu.")
            }
            current = AX.children(submenu)
        }
        return current
    }

    /// The menu item at the end of `path`, descending through submenus from `items` (a menu bar's
    /// or an open menu's); `place` names where they are in errors.
    static func item(at path: [String], from items: [AXUIElement], in place: String) throws -> AXUIElement {
        var current = items
        for (index, title) in path.enumerated() {
            guard let match = current.first(where: { normalize(AX.string($0, "AXTitle")) == normalize(title) }) else {
                let available = current.compactMap { AX.string($0, "AXTitle") }.filter { !$0.isEmpty }.joined(separator: ", ")
                throw RPCError(code: RPCErrorCode.notFound, message: "No menu item “\(title)” in \(place). Available here: \(available)")
            }
            if index == path.count - 1 { return match }
            guard let submenu = AX.children(match).first(where: { AX.role($0) == "AXMenu" }) else {
                throw RPCError(code: RPCErrorCode.failed, message: "“\(title)” has no submenu.")
            }
            current = AX.children(submenu)
        }
        throw RPCError(code: RPCErrorCode.invalidParams, message: "Give the menu path, e.g. File \"Export as PDF…\".")
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

    /// Typographic characters in menu titles and their plain forms, so "Wi-Fi" finds "Wi‑Fi" and
    /// "Don't Save" finds "Don’t Save".
    static let plainForms: [(String, String)] = [
        ("…", "..."), ("\u{2010}", "-"), ("\u{2011}", "-"), ("\u{2018}", "'"), ("\u{2019}", "'"), ("\u{00A0}", " "),
    ]

    static func normalize(_ text: String?) -> String {
        var plain = text ?? ""
        for (typographic, replacement) in plainForms {
            plain = plain.replacingOccurrences(of: typographic, with: replacement)
        }
        return plain.trimmingCharacters(in: .whitespaces).lowercased()
    }
}
