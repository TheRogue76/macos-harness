import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import HarnessCore
import HarnessProtocol

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

/// `permissions` on macOS: Accessibility and Screen Recording for the helper.
public enum MacPermissions {
    public static func status(appName: String) -> [PermissionsMethod.Item] {
        [
            PermissionsMethod.Item(
                id: "accessibility", name: "Accessibility", state: Permissions.accessibility ? .granted : .missing,
                detail: Permissions.accessibility ? "macOS lets the helper read and operate apps." : "The helper needs it to read and operate apps.",
                prompt: "macOS will ask, and System Settings opens at Privacy & Security > Accessibility: turn on \(appName)."
            ),
            PermissionsMethod.Item(
                id: "screen-recording", name: "Screen Recording", state: Permissions.screenRecording ? .granted : .missing,
                detail: Permissions.screenRecording ? "macOS lets the helper take screenshots." : "The helper needs it for screenshots; macOS applies it after the helper restarts.",
                prompt: "System Settings opens at Privacy & Security > Screen Recording: turn on \(appName), then restart the helper from the menu bar."
            ),
        ]
    }

    public static func run(_ params: PermissionsMethod.Params, bundleIdentifier: String, appName: String) async throws -> PermissionsMethod.Result {
        let items = status(appName: appName)
        if let wanted = params.item, !items.contains(where: { $0.id == wanted }) {
            throw RPCError(
                code: RPCErrorCode.invalidParams,
                message: "There's no permission called \(wanted); there are \(items.map(\.id).joined(separator: ", "))."
            )
        }
        let chosen = items.filter { params.item == nil || $0.id == params.item }
        var performed: [String] = []
        var notices: [String] = []
        switch params.action {
        case .status:
            break
        case .grant:
            for item in chosen where item.state == .missing {
                if item.id == "accessibility" {
                    Permissions.requestAccessibility()
                    await Permissions.openSettings(.accessibility)
                    performed.append("Opened Accessibility in System Settings.")
                } else {
                    Permissions.requestScreenRecording()
                    await Permissions.openSettings(.screenRecording)
                    performed.append("Opened Screen Recording in System Settings.")
                    notices.append("Once Screen Recording is on, restart the helper from the menu bar: macOS applies it after a restart.")
                }
            }
        case .reset:
            for item in chosen {
                let service = item.id == "accessibility" ? "Accessibility" : "ScreenCapture"
                let output = try await ToolRunner.run("/usr/bin/tccutil", ["reset", service, bundleIdentifier], timeout: 15)
                guard output.status == 0 else {
                    throw RPCError(code: RPCErrorCode.failed, message: "tccutil couldn't reset \(item.name): \(output.stderr)")
                }
                performed.append("macOS forgot \(item.name) for \(appName); it will ask again.")
            }
        }
        return PermissionsMethod.Result(items: status(appName: appName), performed: performed, notices: notices)
    }
}
