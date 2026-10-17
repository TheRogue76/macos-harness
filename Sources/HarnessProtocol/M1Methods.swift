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
        /// `last`: report only what changed since this session's previous snapshot of the window.
        public var since: String?
        /// Keep only elements whose label, value or identifier contains this, and their ancestors.
        public var query: String?
        /// Include where each link goes; a web page's own address is always included.
        public var links: Bool?

        public init(
            target: Target, root: String? = nil, maxNodes: Int = 250, maxDepth: Int = 40, since: String? = nil, query: String? = nil,
            links: Bool? = nil
        ) {
            self.target = target
            self.root = root
            self.maxNodes = maxNodes
            self.maxDepth = maxDepth
            self.since = since
            self.query = query
            self.links = links
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
        /// With `since`: what changed since the previous snapshot, and `root` holds only the window.
        /// Nil for a full snapshot.
        public var changes: [UIChange]?

        public init(
            window: WindowInfo, root: UINode, notices: [Notice], shownCount: Int, readCount: Int, milliseconds: Int,
            changes: [UIChange]? = nil
        ) {
            self.window = window
            self.root = root
            self.notices = notices
            self.shownCount = shownCount
            self.readCount = readCount
            self.milliseconds = milliseconds
            self.changes = changes
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

        /// Look for `text` in the window's pixels with text recognition instead of the accessibility tree.
        public var ocr: Bool?
        /// Include where each matching link goes.
        public var links: Bool?

        public init(
            target: Target, text: String? = nil, role: String? = nil, identifier: String? = nil,
            exact: Bool = false, limit: Int = 20, ocr: Bool? = nil, links: Bool? = nil
        ) {
            self.target = target
            self.text = text
            self.role = role
            self.identifier = identifier
            self.exact = exact
            self.limit = limit
            self.ocr = ocr
            self.links = links
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

        /// Draw a grid of window-relative coordinates every this many points (for canvases).
        public var grid: Int?

        public init(target: Target, element: String? = nil, maxSize: Int = 1600, labels: Bool = false, grid: Int? = nil) {
            self.target = target
            self.element = element
            self.maxSize = maxSize
            self.labels = labels
            self.grid = grid
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
        /// Read the app's menu bar extras (status items) instead of its menu bar; the path then
        /// starts at an extra's name.
        public var extras: Bool?

        public init(app: String, path: [String] = [], depth: Int = 1, extras: Bool? = nil) {
            self.app = app
            self.path = path
            self.depth = depth
            self.extras = extras
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
        /// The accessibility identifier of a menu bar extra, e.g. com.apple.menuextra.wifi.
        public var identifier: String?

        public init(
            title: String, enabled: Bool, shortcut: String?, mark: String?, isSeparator: Bool,
            hasSubmenu: Bool, children: [Item], identifier: String? = nil
        ) {
            self.title = title
            self.enabled = enabled
            self.shortcut = shortcut
            self.mark = mark
            self.isSeparator = isSeparator
            self.hasSubmenu = hasSubmenu
            self.children = children
            self.identifier = identifier
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

/// Reads one element in full, or the whole window: its label and value without shortening, all
/// the text inside it in reading order, and the links inside it with where they go.
public enum ReadMethod: RPCMethod {
    public static let name = "read"

    public struct Params: Codable, Sendable {
        public var target: Target
        /// The element to read; nil reads the window.
        public var element: ElementSelector?

        public init(target: Target, element: ElementSelector? = nil) {
            self.target = target
            self.element = element
        }
    }

    /// A link inside the element.
    public struct Link: Codable, Sendable, Equatable {
        public var ref: String
        public var label: String?
        public var url: String

        public init(ref: String, label: String?, url: String) {
            self.ref = ref
            self.label = label
            self.url = url
        }
    }

    public struct Result: Codable, Sendable, Equatable {
        public var app: AppRef
        public var window: WindowInfo
        /// The element, with its whole label and value.
        public var element: UINode
        /// All the text inside it, in reading order, one block per line; nil when it has none
        /// beyond its own label and value.
        public var text: String?
        public var links: [Link]
        public var notices: [Notice]

        public init(app: AppRef, window: WindowInfo, element: UINode, text: String?, links: [Link], notices: [Notice]) {
            self.app = app
            self.window = window
            self.element = element
            self.text = text
            self.links = links
            self.notices = notices
        }
    }
}
