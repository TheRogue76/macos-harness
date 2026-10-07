import Foundation

/// Picks one element: by ref from an earlier snapshot, or by what it says and is.
public struct ElementSelector: Codable, Sendable, Equatable {
    public var ref: String?
    /// Label, value or identifier contains this (or equals it with `exact`).
    public var text: String?
    public var role: String?
    public var identifier: String?
    public var exact: Bool
    /// Find `text` in the window's pixels with text recognition instead of the accessibility tree.
    public var ocr: Bool?

    public init(
        ref: String? = nil, text: String? = nil, role: String? = nil, identifier: String? = nil, exact: Bool = false, ocr: Bool? = nil
    ) {
        self.ref = ref
        self.text = text
        self.role = role
        self.identifier = identifier
        self.exact = exact
        self.ocr = ocr
    }

    public var isEmpty: Bool { ref == nil && text == nil && role == nil && identifier == nil }
}

public enum ElementAction: String, Codable, Sendable, CaseIterable {
    case press
    case setValue = "set-value"
    case focus
    case select
    case increment
    case decrement
    case scrollTo = "scroll-to"
    /// Inserts text at the focused element's cursor (or the selected element's).
    case type
    /// A key combination such as cmd+s or return, sent to the app without moving the cursor.
    case key
}

/// One difference between the UI before and after an action.
public struct UIChange: Codable, Sendable, Equatable {
    /// `added`, `removed` or `changed`.
    public var kind: String
    public var node: UINode
    /// The element before the change, for `changed`.
    public var before: UINode?

    public init(kind: String, node: UINode, before: UINode? = nil) {
        self.kind = kind
        self.node = node
        self.before = before
    }
}

/// What an action did and what it changed.
public struct ActionResult: Codable, Sendable {
    public var app: AppRef
    public var window: WindowInfo?
    /// The element acted on, as it looked before the action.
    public var element: UINode?
    /// What was done, e.g. `pressed button "7"`.
    public var performed: String
    /// How: `AX`, `background keys` or `real input`.
    public var via: String
    public var changes: [UIChange]
    /// Changes left out of `changes` for length.
    public var moreChanges: Int
    public var settledMilliseconds: Int
    public var notices: [Notice]
    /// Global screen point acted on, for the on-screen ripple.
    public var screenPoint: Point?

    public init(
        app: AppRef, window: WindowInfo?, element: UINode?, performed: String, via: String,
        changes: [UIChange] = [], moreChanges: Int = 0, settledMilliseconds: Int = 0, notices: [Notice] = [],
        screenPoint: Point? = nil
    ) {
        self.app = app
        self.window = window
        self.element = element
        self.performed = performed
        self.via = via
        self.changes = changes
        self.moreChanges = moreChanges
        self.settledMilliseconds = settledMilliseconds
        self.notices = notices
        self.screenPoint = screenPoint
    }
}

public enum ActMethod: RPCMethod {
    public static let name = "act"

    public struct Params: Codable, Sendable {
        public var target: Target
        /// Nil acts on the app's focused element (useful for `type` and `key`).
        public var element: ElementSelector?
        public var action: ElementAction
        /// The value for `set-value`, the text for `type`, the combination for `key`.
        public var value: String?
        /// How many times for `increment` and `decrement`.
        public var count: Int
        /// Wait for the UI to settle and report what changed.
        public var diff: Bool
        /// For type and key: send real keystrokes to the frontmost app instead of background events.
        public var real: Bool

        public init(
            target: Target, element: ElementSelector?, action: ElementAction, value: String? = nil,
            count: Int = 1, diff: Bool = true, real: Bool = false
        ) {
            self.target = target
            self.element = element
            self.action = action
            self.value = value
            self.count = count
            self.diff = diff
            self.real = real
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            target = try container.decode(Target.self, forKey: .target)
            element = try container.decodeIfPresent(ElementSelector.self, forKey: .element)
            action = try container.decode(ElementAction.self, forKey: .action)
            value = try container.decodeIfPresent(String.self, forKey: .value)
            count = try container.decodeIfPresent(Int.self, forKey: .count) ?? 1
            diff = try container.decodeIfPresent(Bool.self, forKey: .diff) ?? true
            real = try container.decodeIfPresent(Bool.self, forKey: .real) ?? false
        }
    }

    public typealias Result = ActionResult
}

public enum MenuSelectMethod: RPCMethod {
    public static let name = "menu-select"

    public struct Params: Codable, Sendable {
        public var app: String
        /// Menu titles down to the item, e.g. ["File", "Export as PDF…"].
        public var path: [String]
        /// Bring the app to the front first.
        public var activate: Bool
        public var diff: Bool

        public init(app: String, path: [String], activate: Bool = true, diff: Bool = true) {
            self.app = app
            self.path = path
            self.activate = activate
            self.diff = diff
        }
    }

    public typealias Result = ActionResult
}

public enum WindowActionMethod: RPCMethod {
    public static let name = "window"

    public enum Action: String, Codable, Sendable, CaseIterable {
        case activate, move, resize, minimize, restore, fullscreen
        case exitFullscreen = "exit-fullscreen"
        case close
    }

    public struct Params: Codable, Sendable {
        public var target: Target
        public var action: Action
        /// Global top-left position for `move`, in points.
        public var x: Double?
        public var y: Double?
        /// Size for `resize`, in points.
        public var width: Double?
        public var height: Double?

        public init(target: Target, action: Action, x: Double? = nil, y: Double? = nil, width: Double? = nil, height: Double? = nil) {
            self.target = target
            self.action = action
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    public typealias Result = ActionResult
}

public enum LaunchMethod: RPCMethod {
    public static let name = "launch"

    public struct Params: Codable, Sendable {
        /// App name, bundle ID or path to an .app.
        public var app: String
        public var arguments: [String]
        public var environment: [String: String]
        /// Files to open with the app.
        public var open: [String]
        /// Bring it to the front.
        public var activate: Bool
        /// Seconds to wait for its first window.
        public var timeout: Double
        /// Start another copy even if the app is running (a browser with its own profile).
        public var newInstance: Bool?

        public init(
            app: String, arguments: [String] = [], environment: [String: String] = [:], open: [String] = [],
            activate: Bool = false, timeout: Double = 15, newInstance: Bool? = nil
        ) {
            self.app = app
            self.arguments = arguments
            self.environment = environment
            self.open = open
            self.activate = activate
            self.timeout = timeout
            self.newInstance = newInstance
        }
    }

    public struct Result: Codable, Sendable {
        public var app: AppRef
        public var windows: [WindowInfo]
        public var alreadyRunning: Bool
        public var milliseconds: Int

        public init(app: AppRef, windows: [WindowInfo], alreadyRunning: Bool, milliseconds: Int) {
            self.app = app
            self.windows = windows
            self.alreadyRunning = alreadyRunning
            self.milliseconds = milliseconds
        }
    }
}

public enum QuitMethod: RPCMethod {
    public static let name = "quit"

    public struct Params: Codable, Sendable {
        public var app: String
        /// Kill it instead of asking it to quit (unsaved work is lost).
        public var force: Bool
        public var timeout: Double

        public init(app: String, force: Bool = false, timeout: Double = 5) {
            self.app = app
            self.force = force
            self.timeout = timeout
        }
    }

    public struct Result: Codable, Sendable {
        public var app: AppRef
        public var quit: Bool
        public var message: String

        public init(app: AppRef, quit: Bool, message: String) {
            self.app = app
            self.quit = quit
            self.message = message
        }
    }
}

public enum WaitMethod: RPCMethod {
    public static let name = "wait"

    public struct Params: Codable, Sendable {
        public var target: Target
        public var element: ElementSelector
        /// Wait for it to disappear instead.
        public var gone: Bool
        public var timeout: Double

        public init(target: Target, element: ElementSelector, gone: Bool = false, timeout: Double = 10) {
            self.target = target
            self.element = element
            self.gone = gone
            self.timeout = timeout
        }
    }

    public struct Result: Codable, Sendable {
        public var satisfied: Bool
        public var node: UINode?
        public var window: WindowInfo?
        public var milliseconds: Int

        public init(satisfied: Bool, node: UINode?, window: WindowInfo?, milliseconds: Int) {
            self.satisfied = satisfied
            self.node = node
            self.window = window
            self.milliseconds = milliseconds
        }
    }
}

public enum PointerAction: String, Codable, Sendable, CaseIterable {
    case click
    case doubleClick = "double-click"
    case rightClick = "right-click"
    case hover
    case drag
    case scroll
}

/// Real mouse input. It moves the user's cursor (put back afterwards) and needs the app in front.
public enum PointerMethod: RPCMethod {
    public static let name = "pointer"

    public struct Params: Codable, Sendable {
        public var target: Target
        public var action: PointerAction
        /// Where: an element (its click point) or `point`.
        public var element: ElementSelector?
        /// Window-relative point, used when no element is given.
        public var point: Point?
        /// Drag destination: an element or `toPoint`.
        public var to: ElementSelector?
        public var toPoint: Point?
        /// cmd, shift, opt, ctrl held during the action.
        public var modifiers: [String]
        /// Scroll amounts in pixels (positive dy scrolls content up, like a trackpad).
        public var dx: Double
        public var dy: Double
        /// Drag: seconds to hold before moving; hover: seconds to stay.
        public var hold: Double
        /// Drag: seconds the move takes.
        public var duration: Double
        public var diff: Bool

        public init(
            target: Target, action: PointerAction, element: ElementSelector? = nil, point: Point? = nil,
            to: ElementSelector? = nil, toPoint: Point? = nil, modifiers: [String] = [], dx: Double = 0, dy: Double = 0,
            hold: Double = 0.3, duration: Double = 0.6, diff: Bool = true
        ) {
            self.target = target
            self.action = action
            self.element = element
            self.point = point
            self.to = to
            self.toPoint = toPoint
            self.modifiers = modifiers
            self.dx = dx
            self.dy = dy
            self.hold = hold
            self.duration = duration
            self.diff = diff
        }
    }

    public typealias Result = ActionResult
}
