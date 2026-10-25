import ApplicationServices
import Foundation
import HarnessCore

/// Hashable identity for AX elements: two AXUIElements for the same UI object compare equal.
public struct ElementKey: Hashable, @unchecked Sendable {
    public let element: AXUIElement

    public init(_ element: AXUIElement) {
        self.element = element
    }

    public static func == (lhs: ElementKey, rhs: ElementKey) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(element))
    }
}

/// Reads AX subtrees within node, depth and time limits.
public struct AXReader {
    public var maxNodes: Int
    public var maxDepth: Int
    public var deadline: Date
    /// Longest value kept, in characters; longer ones are cut and end in "…".
    public var valueLimit: Int

    public init(maxNodes: Int = 4000, maxDepth: Int = 60, timeBudget: TimeInterval = 3, valueLimit: Int = 300) {
        self.maxNodes = maxNodes
        self.maxDepth = maxDepth
        self.deadline = Date().addingTimeInterval(timeBudget)
        self.valueLimit = valueLimit
    }

    private static let attributeNames = [
        "AXRole", "AXSubrole", "AXTitle", "AXDescription", "AXPlaceholderValue", "AXValue",
        "AXIdentifier", "AXEnabled", "AXFocused", "AXSelected", "AXPosition", "AXSize", "AXChildren", "AXURL",
    ]
    private static let windowButtonAttributes = ["AXCloseButton", "AXMinimizeButton", "AXZoomButton", "AXFullScreenButton"]

    /// Nodes read so far in one read.
    private final class Budget {
        var nodes = 0
    }

    public func read(_ element: AXUIElement) -> RawNode {
        let budget = Budget()
        return read(element, depth: 0, budget: budget)
    }

    private func read(_ element: AXUIElement, depth: Int, budget: Budget) -> RawNode {
        budget.nodes += 1
        var values: CFArray?
        AXUIElementCopyMultipleAttributeValues(element, Self.attributeNames as CFArray, AXCopyMultipleAttributeOptions(), &values)
        let list = (values as? [AnyObject]) ?? []
        func at(_ index: Int) -> AnyObject? {
            guard index < list.count else { return nil }
            let value = list[index]
            if CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .axError {
                return nil
            }
            return value
        }

        var node = RawNode(
            key: AnyHashable(ElementKey(element)),
            role: Self.text(at(0)) ?? "AXUnknown",
            subrole: Self.text(at(1)),
            title: Self.text(at(2)),
            details: Self.text(at(3)),
            placeholder: Self.text(at(4)),
            value: Self.valueText(at(5), limit: valueLimit),
            identifier: Self.text(at(6)),
            url: Self.urlText(at(13)),
            enabled: at(7) as? Bool,
            focused: at(8) as? Bool,
            selected: at(9) as? Bool,
            actions: AX.actions(element),
            frame: Self.frame(position: at(10), size: at(11))
        )

        let children = (at(12) as? [AXUIElement]) ?? []
        guard depth < maxDepth else {
            node.unread = children.count
            return node
        }
        for (index, child) in children.enumerated() {
            if budget.nodes >= maxNodes || Date() > deadline {
                let rest = Array(children[index...])
                let buttons = node.role == "AXWindow" ? Self.windowButtons(of: element, among: rest) : []
                node.children += buttons.map { read($0, depth: depth + 1, budget: budget) }
                node.unread = rest.count - buttons.count
                break
            }
            node.children.append(read(child, depth: depth + 1, budget: budget))
        }
        return node
    }

    /// The window's close, minimize, zoom and full screen buttons among `children`, in their order.
    static func windowButtons(of window: AXUIElement, among children: [AXUIElement]) -> [AXUIElement] {
        var values: CFArray?
        AXUIElementCopyMultipleAttributeValues(window, windowButtonAttributes as CFArray, AXCopyMultipleAttributeOptions(), &values)
        let buttons = ((values as? [AnyObject]) ?? []).filter { CFGetTypeID($0) == AXUIElementGetTypeID() }
        return children.filter { child in buttons.contains { CFEqual($0, child) } }
    }

    static func text(_ value: AnyObject?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// An `AXURL` as text: an absolute URL, or nil when there's none.
    static func urlText(_ value: AnyObject?) -> String? {
        switch value {
        case let url as URL: url.absoluteString
        case let string as String: string.isEmpty ? nil : string
        default: nil
        }
    }

    /// An AXValue as display text, capped at `limit` characters.
    static func valueText(_ value: AnyObject?, limit: Int = 300) -> String? {
        let text: String?
        switch value {
        case let string as String: text = string
        case let attributed as NSAttributedString: text = attributed.string
        case let number as NSNumber:
            guard number.doubleValue.isFinite else { return nil }
            text = number.stringValue
        case let url as URL: text = url.absoluteString
        default: text = nil
        }
        guard let text, !text.isEmpty else { return nil }
        return text.count > limit ? String(text.prefix(limit)) + "…" : text
    }

    static func frame(position: AnyObject?, size: AnyObject?) -> CGRect? {
        guard let position, let size,
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        let rect = CGRect(origin: origin, size: extent)
        return rect.isSane ? rect : nil
    }
}

extension RawNode {
    /// The AX element this node was read from; nil for nodes read some other way, and in tests.
    public var element: AXUIElement? { (key?.base as? ElementKey)?.element }
}
