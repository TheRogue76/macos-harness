import AppKit
import ApplicationServices
import Carbon
import CoreGraphics

/// The macOS privacy permissions the helper needs, checked for the helper process itself.
public enum Permissions {
    public static var accessibility: Bool { AXIsProcessTrusted() }

    public static var screenRecording: Bool { CGPreflightScreenCaptureAccess() }

    /// True while any app has Secure Input on (password fields); synthetic keys are blocked then.
    public static var secureInputEnabled: Bool { IsSecureEventInputEnabled() }

    /// Adds the helper to the Accessibility list and shows the system prompt. The user flips the switch.
    public static func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Adds the helper to the Screen Recording list and shows the system prompt.
    /// macOS applies the grant after the helper restarts.
    public static func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
    }

    public enum Pane: String {
        case accessibility = "Privacy_Accessibility"
        case screenRecording = "Privacy_ScreenCapture"
    }

    @MainActor
    public static func openSettings(_ pane: Pane) {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)")!
        NSWorkspace.shared.open(url)
    }
}
