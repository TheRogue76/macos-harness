import AppKit
import CoreGraphics
import HarnessProtocol

public enum AppsService {
    @MainActor
    public static func runningApps(includeBackground: Bool) -> [AppsMethod.App] {
        let windows = normalWindowCounts()
        // NSRunningApplication.isActive reads false for every app inside this accessory helper;
        // frontmostApplication is reliable.
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        return NSWorkspace.shared.runningApplications
            .filter { includeBackground || $0.activationPolicy == .regular }
            .map { app in
                AppsMethod.App(
                    name: app.localizedName ?? app.bundleIdentifier ?? "pid \(app.processIdentifier)",
                    bundleIdentifier: app.bundleIdentifier,
                    pid: app.processIdentifier,
                    active: app.processIdentifier == frontmost,
                    hidden: app.isHidden,
                    activationPolicy: policyName(app.activationPolicy),
                    windowCount: windows[app.processIdentifier, default: 0]
                )
            }
            .sorted { ($0.active ? 0 : 1, $0.name.lowercased()) < ($1.active ? 0 : 1, $1.name.lowercased()) }
    }

    /// Counts layer-0 windows per owner. Works without Screen Recording (titles are hidden, owners aren't).
    static func normalWindowCounts() -> [pid_t: Int] {
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return [:] }
        var counts: [pid_t: Int] = [:]
        for window in list {
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  let owner = window[kCGWindowOwnerPID as String] as? pid_t else { continue }
            if let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
               (bounds["Width"] ?? 0) < 50 || (bounds["Height"] ?? 0) < 50 {
                continue  // skip invisible helper windows
            }
            counts[owner, default: 0] += 1
        }
        return counts
    }

    static func policyName(_ policy: NSApplication.ActivationPolicy) -> String {
        switch policy {
        case .regular: "regular"
        case .accessory: "accessory"
        case .prohibited: "prohibited"
        @unknown default: "unknown"
        }
    }
}
