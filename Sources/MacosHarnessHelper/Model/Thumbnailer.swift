import AppKit
@preconcurrency import ScreenCaptureKit

/// Small pictures of agents' windows for the session cards.
@MainActor
enum Thumbnailer {
    static func capture(windowID: UInt32, maxEdge: CGFloat = 200) async -> NSImage? {
        guard CGPreflightScreenCaptureAccess(),
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false),
              let window = content.windows.first(where: { $0.windowID == windowID }) else { return nil }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let frame = window.frame
        let scale = maxEdge / max(frame.width, frame.height, 1)
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(frame.width * scale))
        configuration.height = max(1, Int(frame.height * scale))
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) else {
            return nil
        }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}
