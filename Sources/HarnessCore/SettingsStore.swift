import Foundation
import HarnessProtocol

/// The user's settings from the menu bar panel, kept in the helper's defaults (the dev and
/// release helpers have their own). Every setting is on until the user turns it off.
public final class SettingsStore: @unchecked Sendable {
    /// The defaults keys, kept stable across releases.
    public enum Key {
        public static let backgroundRoute = "backgroundRoute"
        public static let windowOutline = "showWindowOutline"
        public static let outlineReads = "showActivityOnScreen"
        public static let drivingPanel = "showDrivingPanel"
    }

    /// The helper's own settings.
    public static let shared = SettingsStore()

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Clicks and scrolls may go to a window in the background; off, they always use the real mouse.
    public var backgroundRoute: Bool {
        get { value(Key.backgroundRoute) }
        set { defaults.set(newValue, forKey: Key.backgroundRoute) }
    }

    /// The outline and tab on the window an agent acts in.
    public var windowOutline: Bool {
        get { value(Key.windowOutline) }
        set { defaults.set(newValue, forKey: Key.windowOutline) }
    }

    /// The outline also on windows agents only read or capture, while `windowOutline` is on.
    public var outlineReads: Bool {
        get { value(Key.outlineReads) }
        set { defaults.set(newValue, forKey: Key.outlineReads) }
    }

    /// The "is driving" panel with Pause and Stop, and the ripple where an agent clicks.
    public var drivingPanel: Bool {
        get { value(Key.drivingPanel) }
        set { defaults.set(newValue, forKey: Key.drivingPanel) }
    }

    /// The settings as `doctor` reports them.
    public var summary: DoctorMethod.Settings {
        DoctorMethod.Settings(
            backgroundRoute: backgroundRoute, windowOutline: windowOutline, outlineReads: outlineReads, drivingPanel: drivingPanel
        )
    }

    private func value(_ key: String) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }
}
