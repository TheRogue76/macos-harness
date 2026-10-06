import CoreGraphics
import Foundation
import HarnessProtocol

/// Turns a raw AX tree into what an agent should see: pruned, clipped to what's visible,
/// window-relative, with refs. Pure, so it's unit-tested without AX.
public struct TreeShaper {
    public struct Result {
        public var root: UINode
        public var shown: Int
        /// Elements left out because they're scrolled or clipped out of view.
        public var offscreen: Int
        /// Elements left out because of the node or depth limit.
        public var omitted: Int
    }

    /// Global frame of the window everything is relative to.
    public let window: CGRect
    public let maxNodes: Int
    public let maxDepth: Int
    public let ref: (RawNode) -> String

    public init(window: CGRect, maxNodes: Int, maxDepth: Int, ref: @escaping (RawNode) -> String) {
        self.window = window
        self.maxNodes = maxNodes
        self.maxDepth = maxDepth
        self.ref = ref
    }

    static let noiseRoles: Set<String> = [
        "AXScrollBar", "AXValueIndicator", "AXIncrementArrow", "AXDecrementArrow",
        "AXIncrementPage", "AXDecrementPage", "AXGrowArea", "AXSplitter",
    ]
    /// Containers that only matter if they carry a name, value, identifier or action.
    static let collapsibleRoles: Set<String> = [
        "AXGroup", "AXUnknown", "AXGenericElement", "AXScrollArea", "AXSplitGroup",
        "AXLayoutArea", "AXLayoutItem", "AXMatte",
    ]
    static let clippingRoles: Set<String> = ["AXScrollArea", "AXWindow"]
    static let noisyActions: Set<String> = [
        "AXCancel", "AXShowMenu", "AXScrollToVisible", "AXRaise", "AXConfirm", "AXZoomWindow",
        "AXScrollLeftByPage", "AXScrollRightByPage", "AXScrollUpByPage", "AXScrollDownByPage",
    ]
    static let chromeLabels: [String: String] = [
        "AXCloseButton": "close", "AXMinimizeButton": "minimize",
        "AXZoomButton": "zoom", "AXFullScreenButton": "full screen",
    ]

    private final class Counters {
        var shown = 0
        var offscreen = 0
        var omitted = 0
    }

    public func shape(_ root: RawNode) -> Result {
        let counters = Counters()
        var node = makeNode(root, visible: root.frame.map { $0.intersection(window) } ?? window)
        counters.shown = 1
        let clip = Self.clippingRoles.contains(root.role) ? (root.frame ?? window).intersection(window) : window
        for child in root.children {
            let (nodes, omitted) = shape(child, clip: clip, depth: 1, counters: counters)
            node.children += nodes
            node.omitted += omitted
        }
        node.omitted += root.unread
        counters.omitted += root.unread
        node.children = Self.dropRedundantText(node.children, parentLabel: node.label)
        return Result(root: node, shown: counters.shown, offscreen: counters.offscreen, omitted: counters.omitted)
    }

    /// Returns the nodes this raw node becomes (none, itself, or its children when collapsed)
    /// plus how many descendants the limits left out.
    private func shape(_ raw: RawNode, clip: CGRect, depth: Int, counters: Counters) -> ([UINode], Int) {
        if Self.noiseRoles.contains(raw.role) { return ([], 0) }

        var visible: CGRect? = nil
        if let frame = raw.frame, frame.width >= 1, frame.height >= 1 {
            let intersection = frame.intersection(clip)
            guard !intersection.isNull, intersection.width >= 1, intersection.height >= 1 else {
                counters.offscreen += raw.count
                return ([], 0)
            }
            visible = intersection
        }
        let childClip = Self.clippingRoles.contains(raw.role) ? (visible ?? clip) : clip

        if shouldCollapse(raw) {
            var nodes: [UINode] = []
            var omitted = raw.unread
            for child in raw.children {
                let (childNodes, childOmitted) = shape(child, clip: childClip, depth: depth, counters: counters)
                nodes += childNodes
                omitted += childOmitted
            }
            counters.omitted += raw.unread
            return (nodes, omitted)
        }

        guard counters.shown < maxNodes, depth <= maxDepth else {
            counters.omitted += raw.count
            return ([], raw.count)
        }
        counters.shown += 1
        var node = makeNode(raw, visible: visible)
        if let chrome = raw.subrole.flatMap({ Self.chromeLabels[$0] }) {
            node.label = chrome
            return ([node], 0)
        }
        for child in raw.children {
            let (childNodes, childOmitted) = shape(child, clip: childClip, depth: depth + 1, counters: counters)
            node.children += childNodes
            node.omitted += childOmitted
        }
        node.omitted += raw.unread
        counters.omitted += raw.unread
        node.children = Self.dropRedundantText(node.children, parentLabel: node.label)
        return ([node], 0)
    }

    func shouldCollapse(_ raw: RawNode) -> Bool {
        Self.collapsibleRoles.contains(raw.role)
            && raw.label == nil && raw.value == nil
            && Self.meaningfulIdentifier(raw.identifier) == nil
            && Self.meaningfulActions(raw.actions).isEmpty
    }

    func makeNode(_ raw: RawNode, visible: CGRect?) -> UINode {
        let isText = raw.role == "AXStaticText"
        return UINode(
            ref: ref(raw),
            role: raw.role,
            subrole: raw.subrole,
            label: isText ? nil : raw.label,
            value: raw.value ?? (isText ? raw.label : nil),
            identifier: Self.meaningfulIdentifier(raw.identifier),
            enabled: raw.enabled == false ? false : nil,
            focused: raw.focused == true ? true : nil,
            selected: raw.selected == true ? true : nil,
            actions: Self.meaningfulActions(raw.actions),
            frame: visible.map(relative),
            hit: visible.map { Point(x: ($0.midX - window.minX).rounded(), y: ($0.midY - window.minY).rounded()) }
        )
    }

    func relative(_ rect: CGRect) -> Rect {
        Rect(
            x: (rect.minX - window.minX).rounded(), y: (rect.minY - window.minY).rounded(),
            width: rect.width.rounded(), height: rect.height.rounded()
        )
    }

    /// Identifiers the toolkit generates (`_NS:8`, `_TtGC7SwiftUI…`) mean nothing to an agent.
    static func meaningfulIdentifier(_ identifier: String?) -> String? {
        guard let identifier, !identifier.isEmpty else { return nil }
        if identifier.hasPrefix("_") || identifier.contains("SwiftUI.") || identifier.hasPrefix("NS") {
            return nil
        }
        return identifier
    }

    /// Drops scrolling and bookkeeping actions; turns UIKit custom actions
    /// ("Name:Delete\nTarget:0x0\nSelector:(null)") into their names.
    static func meaningfulActions(_ actions: [String]) -> [String] {
        var result: [String] = []
        for action in actions where !noisyActions.contains(action) {
            if let range = action.range(of: "Name:") {
                let name = action[range.upperBound...].prefix { $0 != "\n" }.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty, !result.contains(name) { result.append(name) }
            } else if !result.contains(action) {
                result.append(action)
            }
        }
        return result
    }

    /// A text child that only repeats its parent's label adds nothing.
    static func dropRedundantText(_ children: [UINode], parentLabel: String?) -> [UINode] {
        guard let parentLabel else { return children }
        return children.filter { !($0.role == "AXStaticText" && $0.children.isEmpty && $0.value == parentLabel) }
    }
}
