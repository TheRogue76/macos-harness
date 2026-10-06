import Foundation

public enum WindowsMethod: RPCMethod {
    public static let name = "windows"

    public struct Params: Codable, Sendable {
        /// nil lists windows of every regular app.
        public var app: String?

        public init(app: String? = nil) {
            self.app = app
        }
    }

    public struct Result: Codable, Sendable {
        public var windows: [WindowInfo]

        public init(windows: [WindowInfo]) {
            self.windows = windows
        }
    }
}

public enum SnapshotMethod: RPCMethod {
    public static let name = "snapshot"

    public struct Params: Codable, Sendable {
        public var target: Target
        /// Start from this ref instead of the window (to expand an omitted subtree).
        public var root: String?
        public var maxNodes: Int
        public var maxDepth: Int

        public init(target: Target, root: String? = nil, maxNodes: Int = 250, maxDepth: Int = 40) {
            self.target = target
            self.root = root
            self.maxNodes = maxNodes
            self.maxDepth = maxDepth
        }
    }

    public struct Result: Codable, Sendable {
        public var window: WindowInfo
        public var root: UINode
        public var notices: [Notice]
        /// Elements printed, and elements read in total before pruning.
        public var shownCount: Int
        public var readCount: Int
        public var milliseconds: Int

        public init(
            window: WindowInfo, root: UINode, notices: [Notice], shownCount: Int, readCount: Int, milliseconds: Int
        ) {
            self.window = window
            self.root = root
            self.notices = notices
            self.shownCount = shownCount
            self.readCount = readCount
            self.milliseconds = milliseconds
        }
    }
}

public enum FindMethod: RPCMethod {
    public static let name = "find"

    public struct Params: Codable, Sendable {
        public var target: Target
        /// Matches label, value or identifier, case-insensitively.
        public var text: String?
        /// AX role with or without the AX prefix (`button`, `AXButton`).
        public var role: String?
        public var identifier: String?
        /// Require the whole label/value/identifier to equal `text`.
        public var exact: Bool
        public var limit: Int

        public init(
            target: Target, text: String? = nil, role: String? = nil, identifier: String? = nil,
            exact: Bool = false, limit: Int = 20
        ) {
            self.target = target
            self.text = text
            self.role = role
            self.identifier = identifier
            self.exact = exact
            self.limit = limit
        }
    }

    public struct Match: Codable, Sendable, Equatable {
        public var node: UINode
        /// Labels of the nearest labeled ancestors, outermost first.
        public var path: [String]

        public init(node: UINode, path: [String]) {
            self.node = node
            self.path = path
        }
    }

    public struct Result: Codable, Sendable {
        public var window: WindowInfo
        public var matches: [Match]
        public var notices: [Notice]

        public init(window: WindowInfo, matches: [Match], notices: [Notice]) {
            self.window = window
            self.matches = matches
            self.notices = notices
        }
    }
}

public enum ScreenshotMethod: RPCMethod {
    public static let name = "screenshot"

    public struct Params: Codable, Sendable {
        public var target: Target
        /// Crop to this element.
        public var element: String?
        /// Longest edge in pixels; 0 keeps full resolution.
        public var maxSize: Int
        /// Draw ref labels on interactive elements.
        public var labels: Bool

        public init(target: Target, element: String? = nil, maxSize: Int = 1600, labels: Bool = false) {
            self.target = target
            self.element = element
            self.maxSize = maxSize
            self.labels = labels
        }
    }

    public struct Result: Codable, Sendable {
        public var window: WindowInfo
        public var pngBase64: String
        public var width: Int
        public var height: Int
        /// Pixels per window point. Window-relative point = pixel / scale (+ crop origin).
        public var scale: Double
        /// Window-relative area the image shows, when cropped to an element.
        public var crop: Rect?
        public var labeledRefs: [String]
        public var notices: [Notice]

        public init(
            window: WindowInfo, pngBase64: String, width: Int, height: Int, scale: Double, crop: Rect?,
            labeledRefs: [String], notices: [Notice]
        ) {
            self.window = window
            self.pngBase64 = pngBase64
            self.width = width
            self.height = height
            self.scale = scale
            self.crop = crop
            self.labeledRefs = labeledRefs
            self.notices = notices
        }
    }
}

public enum MenuMethod: RPCMethod {
    public static let name = "menu"

    public struct Params: Codable, Sendable {
        public var app: String
        /// Menu titles to descend through, e.g. ["File", "Open Recent"]. Empty lists the menu bar.
        public var path: [String]
        /// Levels to show below the path.
        public var depth: Int

        public init(app: String, path: [String] = [], depth: Int = 1) {
            self.app = app
            self.path = path
            self.depth = depth
        }
    }

    public struct Item: Codable, Sendable, Equatable {
        public var title: String
        public var enabled: Bool
        /// Keyboard shortcut as shown in the menu, e.g. ⇧⌘S.
        public var shortcut: String?
        /// ✓ or • when the item is checked.
        public var mark: String?
        public var isSeparator: Bool
        public var hasSubmenu: Bool
        public var children: [Item]

        public init(
            title: String, enabled: Bool, shortcut: String?, mark: String?, isSeparator: Bool,
            hasSubmenu: Bool, children: [Item]
        ) {
            self.title = title
            self.enabled = enabled
            self.shortcut = shortcut
            self.mark = mark
            self.isSeparator = isSeparator
            self.hasSubmenu = hasSubmenu
            self.children = children
        }
    }

    public struct Result: Codable, Sendable {
        public var app: AppRef
        public var items: [Item]
        public var notices: [Notice]

        public init(app: AppRef, items: [Item], notices: [Notice] = []) {
            self.app = app
            self.items = items
            self.notices = notices
        }
    }
}
