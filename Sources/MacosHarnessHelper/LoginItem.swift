import Foundation
import ServiceManagement

/// The helper's login item, which macOS records with the app's path when it's registered.
@MainActor
enum LoginItem {
    private static let pathKey = "loginItemPath"

    /// Whether macOS opens the helper at login, which the user can also change in System Settings.
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Turns the login item on or off, remembering where the app was when it was turned on.
    static func setEnabled(_ on: Bool) throws {
        if on {
            try SMAppService.mainApp.register()
            UserDefaults.standard.set(Bundle.main.bundlePath, forKey: pathKey)
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    /// Registers the login item again when it was registered from another path, such as the app
    /// under its name before 2.0 or before the user moved it, so login opens the app where it is.
    static func follow() throws {
        guard isEnabled, UserDefaults.standard.string(forKey: pathKey) != Bundle.main.bundlePath else { return }
        try SMAppService.mainApp.unregister()
        try setEnabled(true)
    }
}
