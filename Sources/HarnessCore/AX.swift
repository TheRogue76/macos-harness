import AppKit
import ApplicationServices

/// Helpers over the C accessibility API.
public enum AX {
    public static func application(_ pid: pid_t) -> AXUIElement {
        AXUIElementCreateApplication(pid)
    }

    public static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    public static func string(_ element: AXUIElement, _ name: String) -> String? {
        guard let value = attribute(element, name) as? String, !value.isEmpty else { return nil }
        return value
    }

    public static func elements(_ element: AXUIElement, _ name: String) -> [AXUIElement] {
        (attribute(element, name) as? [AXUIElement]) ?? []
    }

    public static func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    public static func children(_ element: AXUIElement) -> [AXUIElement] {
        elements(element, "AXChildren")
    }

    public static func role(_ element: AXUIElement) -> String {
        string(element, "AXRole") ?? "?"
    }

    /// AXValue as text, whatever its underlying type.
    public static func value(_ element: AXUIElement) -> String? {
        switch attribute(element, "AXValue") {
        case let text as String: text
        case let number as NSNumber: number.stringValue
        default: nil
        }
    }

    /// The best human-readable name: title, then description, then placeholder or help.
    public static func label(_ element: AXUIElement) -> String? {
        string(element, "AXTitle") ?? string(element, "AXDescription")
            ?? string(element, "AXPlaceholderValue") ?? string(element, "AXHelp")
    }

    /// The element's frame in global screen coordinates, top-left origin; nil when missing or not
    /// finite.
    public static func frame(_ element: AXUIElement) -> CGRect? {
        guard let position = attribute(element, "AXPosition"), let size = attribute(element, "AXSize"),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &origin)
        AXValueGetValue(size as! AXValue, .cgSize, &extent)
        guard [origin.x, origin.y, extent.width, extent.height].allSatisfy(\.isFinite) else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    public static func actions(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    /// Scrolls `element` into view: through the nearest ancestor that can scroll itself into view,
    /// else by moving the enclosing scroll area's scroll bars.
    @discardableResult
    public static func scrollIntoView(_ element: AXUIElement) -> AXError {
        var current: AXUIElement? = element
        while let node = current, role(node) != "AXWindow" {
            if actions(node).contains("AXScrollToVisible") { return perform(node, "AXScrollToVisible") }
            current = self.element(node, "AXParent")
        }
        return scrollWithScrollBars(element)
    }

    /// Centers `element` in its nearest scroll area by setting the scroll bars' values.
    static func scrollWithScrollBars(_ element: AXUIElement) -> AXError {
        guard let target = frame(element) else { return .failure }
        var current = self.element(element, "AXParent")
        while let node = current, role(node) != "AXWindow" {
            if role(node) == "AXScrollArea", let visible = frame(node),
               let content = children(node).first(where: { role($0) != "AXScrollBar" }), let document = frame(content) {
                let vertical = scroll(node, bar: "AXVerticalScrollBar", by: target.midY - visible.midY, range: document.height - visible.height)
                let horizontal = scroll(node, bar: "AXHorizontalScrollBar", by: target.midX - visible.midX, range: document.width - visible.width)
                if vertical || horizontal { return .success }
            }
            current = self.element(node, "AXParent")
        }
        return .actionUnsupported
    }

    static func scroll(_ area: AXUIElement, bar name: String, by offset: CGFloat, range: CGFloat) -> Bool {
        guard range > 1, abs(offset) >= 1, let bar = element(area, name) else { return false }
        let position = (attribute(bar, "AXValue") as? Double) ?? 0
        let target = min(1, max(0, position + Double(offset / range)))
        return set(bar, "AXValue", NSNumber(value: target)) == .success
    }

    @discardableResult
    public static func perform(_ element: AXUIElement, _ action: String) -> AXError {
        AXUIElementPerformAction(element, action as CFString)
    }

    @discardableResult
    public static func set(_ element: AXUIElement, _ name: String, _ value: CFTypeRef) -> AXError {
        AXUIElementSetAttributeValue(element, name as CFString, value)
    }

    /// Caps how long one AX call may block on an unresponsive app.
    public static func setTimeout(_ element: AXUIElement, seconds: Float) {
        AXUIElementSetMessagingTimeout(element, seconds)
    }

    /// The first element under `root` that matches, searching depth-first.
    public static func first(
        under root: AXUIElement, maxDepth: Int = 40, where matches: (AXUIElement) -> Bool
    ) -> AXUIElement? {
        if matches(root) { return root }
        guard maxDepth > 0 else { return nil }
        for child in children(root) {
            if let found = first(under: child, maxDepth: maxDepth - 1, where: matches) { return found }
        }
        return nil
    }

    public static let interactiveRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXTextField", "AXTextArea", "AXPopUpButton",
        "AXMenuButton", "AXSlider", "AXComboBox", "AXLink", "AXIncrementor", "AXDisclosureTriangle",
        "AXSearchField", "AXSecureTextField", "AXColorWell", "AXSegmentedControl", "AXStepper",
    ]
}

public enum RunningApps {
    /// Finds a running app by bundle ID or name, case-insensitively.
    @MainActor
    public static func find(_ query: String) -> (pid: pid_t, name: String)? {
        let needle = query.lowercased()
        let app = NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier?.lowercased() == needle || $0.localizedName?.lowercased() == needle
        }
        guard let app else { return nil }
        return (app.processIdentifier, app.localizedName ?? query)
    }
}
