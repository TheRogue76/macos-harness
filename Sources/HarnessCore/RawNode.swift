#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

/// One element of an app's accessibility tree as read, before pruning, in the AX vocabulary
/// whatever the platform.
public struct RawNode {
    /// Identity used by the ref registry: the platform's element key in production, anything Hashable in tests.
    public var key: AnyHashable?
    public var role: String
    public var subrole: String?
    public var title: String?
    public var details: String?
    public var placeholder: String?
    public var value: String?
    public var identifier: String?
    /// Where a link goes, or a web page's address.
    public var url: String?
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
        key: AnyHashable? = nil, role: String, subrole: String? = nil,
        title: String? = nil, details: String? = nil, placeholder: String? = nil, value: String? = nil,
        identifier: String? = nil, url: String? = nil, enabled: Bool? = nil, focused: Bool? = nil, selected: Bool? = nil,
        actions: [String] = [], frame: CGRect? = nil, children: [RawNode] = [], unread: Int = 0
    ) {
        self.key = key
        self.role = role
        self.subrole = subrole
        self.title = title
        self.details = details
        self.placeholder = placeholder
        self.value = value
        self.identifier = identifier
        self.url = url
        self.enabled = enabled
        self.focused = focused
        self.selected = selected
        self.actions = actions
        self.frame = frame
        self.children = children
        self.unread = unread
    }

    /// Names for a window's close, minimize, zoom and full screen buttons, by subrole.
    public static let windowButtonNames: [String: String] = [
        "AXCloseButton": "close", "AXMinimizeButton": "minimize",
        "AXZoomButton": "zoom", "AXFullScreenButton": "full screen",
    ]

    /// `close`, `minimize`, `zoom` or `full screen` for a window button; nil for anything else.
    public var windowButtonName: String? { subrole.flatMap { Self.windowButtonNames[$0] } }

    /// The best human-readable name: a window button's name, else the title, description or
    /// placeholder.
    public var label: String? { windowButtonName ?? title ?? details ?? placeholder }

    /// Total nodes in this subtree, including itself.
    public var count: Int { 1 + children.reduce(0) { $0 + $1.count } }
}
