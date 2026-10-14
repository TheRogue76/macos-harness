import AppKit
import CoreGraphics
import Foundation
import HarnessProtocol

/// Clicks and scrolls that reach a window in the background through SkyLight, without the
/// user's mouse, judged afterwards by what changed.
enum BackgroundInput {
    enum Gesture: Equatable {
        case click(count: Int, button: BackgroundClick.Button)
        case scroll(dx: Double, dy: Double)

        /// How a result names the route.
        var via: String {
            if case .scroll = self { return "background scroll" }
            return "background click"
        }

        var noun: String {
            switch self {
            case .click(_, .right): "right-click"
            case .click(let count, _): count > 1 ? "double-click" : "click"
            case .scroll: "scroll"
            }
        }
    }

    /// Whether the private calls resolve on this macOS.
    static let isAvailable: Bool = SkyLight.missing.isEmpty

    /// The background gesture for a pointer action, or nil when it needs the real mouse: hovers,
    /// drags, held keys, other windows, no diff to judge it by, or `real`.
    static func gesture(for params: PointerMethod.Params) -> Gesture? {
        guard params.real != true, params.modifiers.isEmpty, params.diff, params.toTarget == nil else { return nil }
        switch params.action {
        case .click: return .click(count: 1, button: .left)
        case .doubleClick: return .click(count: 2, button: .left)
        case .rightClick: return .click(count: 1, button: .right)
        case .scroll where params.dx != 0 || params.dy != 0: return .scroll(dx: params.dx, dy: params.dy)
        default: return nil
        }
    }

    /// Whether a Mac window on the current Space holds `point` (global).
    static func reachable(_ point: CGPoint, in window: WindowService.Window) -> Bool {
        guard isAvailable, !window.isSimulator, window.info.android == nil, !window.info.minimized,
              window.space.frame.contains(point) else { return false }
        return OnScreenWindow.current(of: window.info.id, ignoring: getpid()) != nil
    }

    /// Sends the gesture; false when it couldn't be posted.
    static func send(_ gesture: Gesture, app: AppRef, window: WindowService.Window, at point: CGPoint) async -> Bool {
        let origin = CGPoint(x: window.space.frame.minX, y: window.space.frame.minY)
        switch gesture {
        case .click(let count, let button):
            return await BackgroundClick.click(
                pid: app.pid, window: window.info.id, at: point, windowOrigin: origin, count: count, button: button,
                location: .window, focusFirst: false
            )
        case .scroll(let dx, let dy):
            return await BackgroundClick.scroll(pid: app.pid, window: window.info.id, at: point, windowOrigin: origin, dx: dx, dy: dy)
        }
    }

    /// Makes the window key without raising it, then sends the gesture and settles `result`; true
    /// when something changed after the window became key: the tree, a window, an opened context
    /// menu or, failing those, the window's pixels.
    static func attempt(
        _ gesture: Gesture, app: AppRef, window: WindowService.Window, at point: CGPoint,
        before: Settle.Capture, result: inout ActionResult
    ) async -> Bool {
        var baseline = before
        if case .click = gesture, SkyLight.focusWithoutRaise(pid: app.pid, window: window.info.id) {
            try? await Task.sleep(for: .milliseconds(150))
            baseline = Settle.Capture.take(window: window, app: app)
        }
        let picture = await look(window, app: app)
        guard await send(gesture, app: app, window: window, at: point) else { return false }
        await Settle.finish(&result, before: baseline, window: window, app: app)
        if !result.changes.isEmpty || result.notices.contains(where: { ["windowOpened", "windowClosed"].contains($0.kind) }) {
            return true
        }
        if case .click(_, .right) = gesture {
            let items = PointerService.contextMenuItems(app: app, window: window)
            if !items.isEmpty {
                result.changes += items
                return true
            }
        }
        guard differs(picture, await look(window, app: app)) else { return false }
        result.notices.append(Notice(kind: "pixelsOnly", message: "Only the window's pixels changed; its accessibility tree shows no change."))
        return true
    }

    /// The notice for a gesture that changed nothing, before the real mouse takes over.
    static func fallbackNotice(_ gesture: Gesture) -> Notice {
        Notice(kind: "backgroundNoEffect", message: "A \(gesture.noun) in the background changed nothing, so the real mouse was used.")
    }

    /// A small picture of the window, for changes the accessibility tree doesn't show.
    static func look(_ window: WindowService.Window, app: AppRef) async -> CGImage? {
        try? await ScreenshotService.image(of: window, app: app, maxSize: 480)
    }

    /// Whether two pictures of a window differ by more than a few pixels.
    static func differs(_ before: CGImage?, _ after: CGImage?) -> Bool {
        guard let before, let after else { return false }
        guard before.width == after.width, before.height == after.height else { return true }
        guard let old = pixels(of: before), let new = pixels(of: after) else { return false }
        var changed = 0
        for index in stride(from: 0, to: old.count, by: 4) {
            let delta = max(abs(Int(old[index]) - Int(new[index])), abs(Int(old[index + 1]) - Int(new[index + 1])), abs(Int(old[index + 2]) - Int(new[index + 2])))
            if delta > 24 { changed += 1 }
        }
        return changed > max(8, before.width * before.height / 5000)
    }

    private static func pixels(of image: CGImage) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        return drawn ? bytes : nil
    }
}
