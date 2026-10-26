import Foundation
import HarnessProtocol

/// Starting the helper when the user logs in, through an XDG autostart entry, so its icon is
/// there from the start, as a login item is on the Mac.
public enum StartAtLogin {
    static func path(appID: String, environment: [String: String]) -> String {
        let config = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? "\(HarnessPaths.homeDirectory)/.config"
        return "\(config)/autostart/\(appID).desktop"
    }

    public static func isOn(appID: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        FileManager.default.fileExists(atPath: path(appID: appID, environment: environment))
    }

    /// The autostart entry that starts `executable`.
    static func entry(appName: String, executable: String) -> String {
        """
        [Desktop Entry]
        Type=Application
        Name=\(appName)
        Comment=Lets coding agents see and operate your apps
        Exec=\(executable)
        NoDisplay=true
        X-GNOME-Autostart-enabled=true

        """
    }

    /// Turns starting at login on or off.
    public static func set(
        _ on: Bool, appID: String, appName: String, executable: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        let file = path(appID: appID, environment: environment)
        guard on else {
            try? FileManager.default.removeItem(atPath: file)
            return
        }
        try FileManager.default.createDirectory(atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(entry(appName: appName, executable: executable).utf8).write(to: URL(fileURLWithPath: file))
    }
}
