import Foundation
import HarnessProtocol

/// Compact text views of helper results for agents: one element per line, refs first, coordinates
/// last.
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

extension Render {
    /// `pressed button “7” (k11) via AX · settled in 280 ms`, notices, then what changed.
    public static func action(_ result: ActionResult) -> String {
        var lines = ["\(result.performed) via \(result.via)" + (result.settledMilliseconds > 0 ? " · settled in \(result.settledMilliseconds) ms" : "")]
        lines += result.notices.filter { $0.kind != "notFrontmost" || result.via != "AX" }.map(notice)
        if result.settledMilliseconds > 0 {
            if result.changes.isEmpty {
                lines.append("No visible change in the window (take a snapshot if you expected one).")
            } else {
                lines.append("Changes:")
                lines += result.changes.map { "  " + change($0) }
                if result.moreChanges > 0 { lines.append("  (+\(result.moreChanges) more; take a snapshot)") }
            }
        }
        return lines.joined(separator: "\n")
    }

    /// `~ k6 text "79" → "797"`, `+ k45 sheet "save"`, `- k12 button "OK"`.
    public static func change(_ change: UIChange) -> String {
        switch change.kind {
        case "added": return "+ " + node(change.node)
        case "removed": return "- " + node(change.node)
        default:
            guard let before = change.before else { return "~ " + node(change.node) }
            var parts: [String] = []
            if before.label != change.node.label {
                parts.append("\(quote(before.label ?? "", limit: 40)) → \(quote(change.node.label ?? "", limit: 40))")
            }
            if before.value != change.node.value {
                if toggleRoles.contains(change.node.role) {
                    func state(_ value: String?) -> String { value == "1" ? "on" : value == "0" ? "off" : quote(value ?? "", limit: 20) }
                    parts.append("\(state(before.value)) → \(state(change.node.value))")
                } else {
                    parts.append("\(quote(before.value ?? "", limit: 60)) → \(quote(change.node.value ?? "", limit: 60))")
                }
            }
            if before.enabled != change.node.enabled {
                parts.append(change.node.enabled == false ? "now disabled" : "now enabled")
            }
            if before.focused != change.node.focused {
                parts.append(change.node.focused == true ? "now focused" : "lost focus")
            }
            if before.selected != change.node.selected {
                parts.append(change.node.selected == true ? "now selected" : "deselected")
            }
            let role = shortRole(change.node.subrole.flatMap { subroleNames[$0] } ?? change.node.role)
            let name = (change.node.label ?? before.label).map { " \(quote($0, limit: 40))" } ?? ""
            let what = parts.contains { $0.contains("→") } ? "" : name
            return "~ \(change.node.ref) \(role)\(what) " + parts.joined(separator: ", ")
        }
    }

    public static func launch(_ result: LaunchMethod.Result) -> String {
        let head = result.alreadyRunning
            ? "\(result.app.name) (pid \(result.app.pid)) was already running"
            : "Launched \(result.app.name) (pid \(result.app.pid)) in \(result.milliseconds) ms"
        if result.windows.isEmpty {
            return head + "; no window yet (it may still be starting, or show none until asked)."
        }
        return ([head + ". Windows:"] + windows(WindowsMethod.Result(windows: result.windows)).split(separator: "\n").map { "  " + $0 })
            .joined(separator: "\n")
    }

    public static func wait(_ result: WaitMethod.Result, gone: Bool) -> String {
        let seconds = String(format: "%.1f s", Double(result.milliseconds) / 1000)
        guard result.satisfied else { return "Timed out after \(seconds)." }
        if gone { return "Gone after \(seconds)." }
        return "Found after \(seconds): " + (result.node.map(node) ?? "")
    }
}

extension Render {
    public static func isHealthy(_ report: DoctorMethod.Result) -> Bool {
        report.helperVersion == HarnessVersion.string
            && report.protocolVersion == HarnessVersion.protocolVersion
            && report.permissions.accessibility
            && report.permissions.screenRecording
    }

    public static func doctor(_ report: DoctorMethod.Result, socketPath: String) -> String {
        func line(_ ok: Bool, _ text: String) -> String { "\(ok ? "✓" : "✗") \(text)" }
        let appName = (report.bundlePath as NSString).lastPathComponent
        let versionsMatch = report.helperVersion == HarnessVersion.string
            && report.protocolVersion == HarnessVersion.protocolVersion
        let menuHint = "click the macOS Harness icon in the menu bar"
        let chain = report.caller.chain.map(\.name).joined(separator: " ← ")
        return [
            "\(appName) (pid \(report.helperPID)) on macOS \(report.macOSVersion)",
            "  socket: \(socketPath)",
            line(versionsMatch, versionsMatch
                ? "Helper and CLI versions match (\(report.helperVersion))"
                : "Helper is \(report.helperVersion), CLI is \(HarnessVersion.string): restart the helper"),
            line(report.permissions.accessibility, report.permissions.accessibility
                ? "Accessibility granted"
                : "Accessibility missing: \(menuHint) > Grant Accessibility…"),
            line(report.permissions.screenRecording, report.permissions.screenRecording
                ? "Screen Recording granted"
                : "Screen Recording missing: \(menuHint) > Grant Screen Recording…, then Restart Helper"),
            report.secureInputEnabled
                ? "! Secure Input is on (a password field has focus); typing will be blocked until it's off"
                : "✓ Secure Input off",
            report.caller.paired
                ? "✓ Caller: \(report.caller.displayName) (paired)"
                : "- Caller: \(report.caller.displayName) (not paired yet; you'll be asked on first use)",
            "  chain: \(chain)",
        ].joined(separator: "\n")
            + (report.caller.stopped
                ? "\n! The user stopped this agent; it can't act until they resume it from the menu bar panel."
                : "")
    }
}
