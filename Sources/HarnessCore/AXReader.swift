import ApplicationServices
import Foundation

/// One element as read from AX, before pruning. `element` is nil in tests.
public struct RawNode {
    public var element: AXUIElement?
    /// Identity used by the ref registry; AXUIElement in production, anything Hashable in tests.
    public var key: AnyHashable?
    public var role: String
    public var subrole: String?
    public var title: String?
    public var details: String?
    public var placeholder: String?
    public var value: String?
    public var identifier: String?
    public var enabled: Bool?
    public var focused: Bool?
    public var selected: Bool?
    public var actions: [String]
    /// Global screen coordinates, top-left origin. nil when missing or not finite.
    public var frame: CGRect?
    public var children: [RawNode]
    /// Children that weren't read because a limit was reached.
    public var unread: Int

    public init(
        element: AXUIElement? = nil, key: AnyHashable? = nil, role: String, subrole: String? = nil,
        title: String? = nil, details: String? = nil, placeholder: String? = nil, value: String? = nil,
        identifier: String? = nil, enabled: Bool? = nil, focused: Bool? = nil, selected: Bool? = nil,
        actions: [String] = [], frame: CGRect? = nil, children: [RawNode] = [], unread: Int = 0
    ) {
        self.element = element
        self.key = key
        self.role = role
        self.subrole = subrole
        self.title = title
        self.details = details
        self.placeholder = placeholder
        self.value = value
        self.identifier = identifier
        self.enabled = enabled
        self.focused = focused
        self.selected = selected
        self.actions = actions
        self.frame = frame
        self.children = children
        self.unread = unread
    }

    /// The best human-readable name.
    public var label: String? { title ?? details ?? placeholder }

    /// Total nodes in this subtree, including itself.
    public var count: Int { 1 + children.reduce(0) { $0 + $1.count } }
}

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

    public init(maxNodes: Int = 4000, maxDepth: Int = 60, timeBudget: TimeInterval = 3) {
        self.maxNodes = maxNodes
        self.maxDepth = maxDepth
        self.deadline = Date().addingTimeInterval(timeBudget)
    }

    private static let attributeNames = [
        "AXRole", "AXSubrole", "AXTitle", "AXDescription", "AXPlaceholderValue", "AXValue",
        "AXIdentifier", "AXEnabled", "AXFocused", "AXSelected", "AXPosition", "AXSize", "AXChildren",
    ]

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
            element: element,
            key: AnyHashable(ElementKey(element)),
            role: Self.text(at(0)) ?? "AXUnknown",
            subrole: Self.text(at(1)),
            title: Self.text(at(2)),
            details: Self.text(at(3)),
            placeholder: Self.text(at(4)),
            value: Self.valueText(at(5)),
            identifier: Self.text(at(6)),
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
                node.unread = children.count - index
                break
            }
            node.children.append(read(child, depth: depth + 1, budget: budget))
        }
        return node
    }

    static func text(_ value: AnyObject?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// An AXValue as display text, capped in length.
    static func valueText(_ value: AnyObject?) -> String? {
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
        return text.count > 300 ? String(text.prefix(300)) + "…" : text
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

extension CGRect {
    /// Whether the rect is finite and of plausible size.
    var isSane: Bool {
        [origin.x, origin.y, size.width, size.height].allSatisfy { $0.isFinite && abs($0) < 1_000_000 }
    }
}
