import Foundation

/// A rectangle in points. Window-relative unless a field says otherwise.
public struct Rect: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
}

public struct Point: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// The running app a command acted on.
public struct AppRef: Codable, Sendable, Equatable {
    public var name: String
    public var bundleIdentifier: String?
    public var pid: Int32

    public init(name: String, bundleIdentifier: String?, pid: Int32) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.pid = pid
    }
}

public struct WindowInfo: Codable, Sendable, Equatable {
    /// The CGWindowID; stable for the window's lifetime and accepted by `--window`.
    public var id: UInt32
    public var app: AppRef
    public var title: String
    /// Global screen coordinates in points, top-left origin.
    public var frame: Rect
    public var onScreen: Bool
    public var minimized: Bool
    /// The app's focused window (keyboard input goes here when the app is frontmost).
    public var focused: Bool
    public var main: Bool
    /// AX subrole, e.g. AXStandardWindow, AXDialog, AXFloatingWindow.
    public var subrole: String?
    /// Whether a sheet is attached to the window.
    public var hasSheet: Bool
    /// The iOS Simulator this window shows, for `sim:` targets. Coordinates are then the
    /// device's own points, with the screen's top-left corner at 0,0.
    public var simulator: SimulatorInfo?
    /// The Android device this target is, for `android:` targets. Coordinates are then the
    /// screen's pixels.
    public var android: AndroidDeviceInfo?

    public init(
        id: UInt32, app: AppRef, title: String, frame: Rect, onScreen: Bool, minimized: Bool,
        focused: Bool, main: Bool, subrole: String?, hasSheet: Bool, simulator: SimulatorInfo? = nil,
        android: AndroidDeviceInfo? = nil
    ) {
        self.id = id
        self.app = app
        self.title = title
        self.frame = frame
        self.onScreen = onScreen
        self.minimized = minimized
        self.focused = focused
        self.main = main
        self.subrole = subrole
        self.hasSheet = hasSheet
        self.simulator = simulator
        self.android = android
    }
}

/// One element in a pruned accessibility tree.
public struct UINode: Codable, Sendable, Equatable {
    /// Handle for later commands (`e12`). Stable while the element exists.
    public var ref: String
    /// Raw AX role, e.g. AXButton.
    public var role: String
    public var subrole: String?
    /// Title, description, placeholder or help, whichever the element has.
    public var label: String?
    public var value: String?
    public var identifier: String?
    /// nil means the element doesn't report it (treat as enabled).
    public var enabled: Bool?
    public var focused: Bool?
    public var selected: Bool?
    /// Meaningful actions only (AXPress, AXIncrement, custom action names, …).
    public var actions: [String]
    /// Window-relative frame, clipped to what's visible.
    public var frame: Rect?
    /// Window-relative point to click: the center of the visible frame.
    public var hit: Point?
    public var children: [UINode]
    /// Descendants left out because of limits; `snapshot --root <ref>` shows them.
    public var omitted: Int

    public init(
        ref: String, role: String, subrole: String? = nil, label: String? = nil, value: String? = nil,
        identifier: String? = nil, enabled: Bool? = nil, focused: Bool? = nil, selected: Bool? = nil,
        actions: [String] = [], frame: Rect? = nil, hit: Point? = nil, children: [UINode] = [], omitted: Int = 0
    ) {
        self.ref = ref
        self.role = role
        self.subrole = subrole
        self.label = label
        self.value = value
        self.identifier = identifier
        self.enabled = enabled
        self.focused = focused
        self.selected = selected
        self.actions = actions
        self.frame = frame
        self.hit = hit
        self.children = children
        self.omitted = omitted
    }
}

/// Something outside the target window that affects what an agent can do right now.
public struct Notice: Codable, Sendable, Equatable {
    /// `systemDialog`, `sheet`, `secureInput`, `notFrontmost`, `truncated`, …
    public var kind: String
    public var message: String

    public init(kind: String, message: String) {
        self.kind = kind
        self.message = message
    }
}

/// Which app (and optionally window) a command targets.
public struct Target: Codable, Sendable, Equatable {
    /// App name, bundle ID or pid.
    public var app: String
    /// CGWindowID; nil picks the focused window, then the main one, then the first.
    public var window: UInt32?

    public init(app: String, window: UInt32? = nil) {
        self.app = app
        self.window = window
    }
}
