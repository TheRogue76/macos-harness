import Foundation
import HarnessCore
import Observation

/// The user's settings as the panel shows and changes them, saved through the settings store.
@MainActor
@Observable
package final class HelperSettings {
    @ObservationIgnored private let store: SettingsStore

    /// Clicks and scrolls may go to a window in the background; off, they always use the real mouse.
    package var backgroundRoute: Bool {
        didSet { store.backgroundRoute = backgroundRoute }
    }

    /// The outline and tab on the window an agent acts in.
    package var windowOutline: Bool {
        didSet { store.windowOutline = windowOutline }
    }

    /// The outline also on windows agents only read or capture.
    package var outlineReads: Bool {
        didSet { store.outlineReads = outlineReads }
    }

    /// The "is driving" panel and the ripple where an agent clicks.
    package var drivingPanel: Bool {
        didSet { store.drivingPanel = drivingPanel }
    }

    package init(store: SettingsStore = .shared) {
        self.store = store
        backgroundRoute = store.backgroundRoute
        windowOutline = store.windowOutline
        outlineReads = store.outlineReads
        drivingPanel = store.drivingPanel
    }
}
