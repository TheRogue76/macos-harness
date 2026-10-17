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
    static var isAvailable: Bool { SkyLight.missing.isEmpty }

    /// The background gesture for a pointer action, or nil when it needs the real mouse: hovers,
    /// drags, held keys, other windows, or `real`.
    static func gesture(for params: PointerMethod.Params) -> Gesture? {
        guard params.real != true, params.modifiers.isEmpty, params.toTarget == nil else { return nil }
        switch params.action {
        case .click: return .click(count: 1, button: .left)
        case .doubleClick: return .click(count: 2, button: .left)
        case .rightClick: return .click(count: 1, button: .right)
        case .scroll where params.dx != 0 || params.dy != 0: return .scroll(dx: params.dx, dy: params.dy)
        default: return nil
        }
    }

    /// The gesture a pointer action at `point` tries in the background first, or nil when it goes
    /// straight to real input, as it always does while the user has the route turned off.
    static func route(
        for params: PointerMethod.Params, at point: CGPoint?, in window: WindowService.Window,
        settings: SettingsStore = .shared, isOnScreen: (UInt32) -> Bool = BackgroundInput.isOnScreen
    ) -> Gesture? {
        guard let gesture = gesture(for: params), let point, routes(at: point, in: window, settings: settings, isOnScreen: isOnScreen) else {
            return nil
        }
        return gesture
    }

    /// Whether a click or scroll at `point` goes to the window in the background first: the user
    /// lets it, and the window can take it there.
    static func routes(
        at point: CGPoint, in window: WindowService.Window, settings: SettingsStore = .shared,
        isOnScreen: (UInt32) -> Bool = BackgroundInput.isOnScreen
    ) -> Bool {
        settings.backgroundRoute && reachable(point, in: window, isOnScreen: isOnScreen)
    }

    /// Says a pointer action used the real mouse because the user turned the background route
    /// off; nil when the route is on or the action wouldn't have tried it.
    static func turnedOffNotice(
        for params: PointerMethod.Params, at point: CGPoint?, in window: WindowService.Window,
        settings: SettingsStore = .shared, isOnScreen: (UInt32) -> Bool = BackgroundInput.isOnScreen
    ) -> Notice? {
        guard let gesture = gesture(for: params), let point else { return nil }
        return turnedOffNotice(gesture, at: point, in: window, settings: settings, isOnScreen: isOnScreen)
    }

    /// Says the gesture used the real mouse because the user turned the background route off;
    /// nil when the route is on or the window couldn't have taken it in the background anyway.
    static func turnedOffNotice(
        _ gesture: Gesture, at point: CGPoint, in window: WindowService.Window, settings: SettingsStore = .shared,
        isOnScreen: (UInt32) -> Bool = BackgroundInput.isOnScreen
    ) -> Notice? {
        guard !settings.backgroundRoute, reachable(point, in: window, isOnScreen: isOnScreen) else { return nil }
        return Notice(
            kind: "backgroundOff",
            message: "The user turned off clicks and scrolls in the background (macOS Harness settings), so the \(gesture.noun) used the real mouse."
        )
    }

    /// Whether a Mac window on the current Space holds `point` (global) and the private calls
    /// resolve.
    static func reachable(_ point: CGPoint, in window: WindowService.Window, isOnScreen: (UInt32) -> Bool = BackgroundInput.isOnScreen) -> Bool {
        guard isAvailable, !window.isSimulator, window.info.android == nil, !window.info.minimized,
              window.space.frame.contains(point) else { return false }
        return window.info.otherSpace == true || isOnScreen(window.info.id)
    }

    /// Whether the window server shows the window on the current Space.
    static func isOnScreen(_ window: UInt32) -> Bool {
        OnScreenWindow.current(of: window, ignoring: getpid()) != nil
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
    /// What happened to a gesture sent in the background.
    enum Outcome: Equatable {
        /// Something changed: the tree, a window, a context menu or the pixels.
        case effect
        /// It was sent but nothing visible changed; it may still have worked out of sight.
        case noEffect
        /// A right-click that opened no menu: repeating it with the real mouse is safe, since a
        /// right-click only opens a menu.
        case noMenu
        /// It couldn't be sent.
        case notSent
        /// It was sent without looking at what changed, since the caller asked for no diff.
        case unchecked
    }

    static func attempt(
        _ gesture: Gesture, app: AppRef, window: WindowService.Window, at point: CGPoint,
        before: Settle.Capture?, result: inout ActionResult
    ) async -> Outcome {
        var baseline = before
        if case .click = gesture, SkyLight.focusWithoutRaise(pid: app.pid, window: window.info.id) {
            try? await Task.sleep(for: .milliseconds(150))
            if before != nil { baseline = Settle.Capture.take(window: window, app: app) }
        }
        var picture: CGImage?
        if case .click = gesture {
            picture = await steady(await look(window, app: app), window: window, app: app)
        } else if before != nil {
            picture = await look(window, app: app)
        }
        guard let baseline else { return await sendUnchecked(gesture, app: app, window: window, at: point, result: &result) }
        guard await send(gesture, app: app, window: window, at: point) else { return .notSent }
        await Settle.finish(&result, before: baseline, window: window, app: app)
        if !result.changes.isEmpty || result.notices.contains(where: { ["windowOpened", "windowClosed", "changedOutOfView"].contains($0.kind) }) {
            return .effect
        }
        if case .click(_, .right) = gesture {
            let items = PointerService.contextMenuItems(app: app, window: window)
            guard items.isEmpty else {
                result.changes += items
                return .effect
            }
            return .noMenu
        }
        let settled = await look(window, app: app)
        guard differs(picture, settled), !turnedActive(picture, settled, closeButton: closeButton(of: window, in: picture)) else {
            result.notices.append(unconfirmedNotice(gesture))
            return .noEffect
        }
        result.notices.append(Notice(kind: "pixelsOnly", message: "Only the window's pixels changed; its accessibility tree shows no change."))
        return .effect
    }

    /// Sends the gesture without judging it, for a caller that asked for no diff. A right-click
    /// still waits up to a second for its context menu, since the menu is its result.
    static func sendUnchecked(
        _ gesture: Gesture, app: AppRef, window: WindowService.Window, at point: CGPoint, result: inout ActionResult
    ) async -> Outcome {
        guard await send(gesture, app: app, window: window, at: point) else { return .notSent }
        guard case .click(_, .right) = gesture else { return .unchecked }
        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(100))
            let items = PointerService.contextMenuItems(app: app, window: window)
            if !items.isEmpty {
                result.changes += items
                return .effect
            }
        }
        return .noMenu
    }

    /// Roles of the AppKit text inputs, which don't take the first click in an inactive window.
    static let textInputRoles: Set<String> = ["AXTextArea", "AXTextField", "AXComboBox"]

    /// Why a click on an element with this role, inside elements with `ancestorRoles`, goes
    /// straight to the real mouse; nil when it can try the background.
    static func skipReason(role: String, ancestorRoles: [String]) -> String? {
        if textInputRoles.contains(role) { return "Text fields and text views" }
        if ancestorRoles.contains("AXSheet") { return "Sheets" }
        return nil
    }

    /// Why a click gesture on `element` (or, without one, on whatever is at `point`) skips the
    /// background, as a notice; nil when it can try it.
    static func skipNotice(_ gesture: Gesture, element: AXUIElement?, at point: CGPoint, app: AppRef) -> Notice? {
        guard case .click = gesture else { return nil }
        var target = element
        if target == nil {
            var hit: AXUIElement?
            var pid: pid_t = 0
            if AXUIElementCopyElementAtPosition(AX.application(app.pid), Float(point.x), Float(point.y), &hit) == .success,
               let hit, AXUIElementGetPid(hit, &pid) == .success, pid == app.pid {
                target = hit
            }
        }
        guard let target else { return nil }
        var ancestors: [String] = []
        var current = AX.element(target, "AXParent")
        while let parent = current, ancestors.count < 30 {
            let role = AX.role(parent)
            ancestors.append(role)
            if role == "AXWindow" || role == "AXApplication" { break }
            current = AX.element(parent, "AXParent")
        }
        guard let reason = skipReason(role: AX.role(target), ancestorRoles: ancestors) else { return nil }
        return Notice(kind: "backgroundSkipped", message: "\(reason) don't take clicks in the background, so the real mouse was used.")
    }

    /// Says a gesture went in the background without a visible effect, and how to repeat it.
    static func unconfirmedNotice(_ gesture: Gesture) -> Notice {
        Notice(
            kind: "backgroundUnconfirmed",
            message: "The \(gesture.noun) went to the window in the background, but nothing visible changed; it may have worked out of sight. It wasn't repeated with the real mouse, which could do it twice: if it didn't take, repeat it with real=true (--real)."
        )
    }

    /// The notice for a gesture that changed nothing, before the real mouse takes over.
    static func fallbackNotice(_ gesture: Gesture, outcome: Outcome = .notSent) -> Notice {
        let why = outcome == .noMenu ? "opened no menu in the background" : "couldn't be sent in the background"
        return Notice(kind: "backgroundNoEffect", message: "The \(gesture.noun) \(why), so the real mouse was used.")
    }

    /// Whether an outcome stands as the action's result, or the real mouse should try instead.
    static func stands(_ outcome: Outcome) -> Bool {
        outcome == .effect || outcome == .noEffect || outcome == .unchecked
    }

    /// A small picture of the window, for changes the accessibility tree doesn't show.
    static func look(_ window: WindowService.Window, app: AppRef) async -> CGImage? {
        try? await ScreenshotService.image(of: window, app: app, maxSize: 480)
    }

    /// The window's picture once it stops changing (it redraws as active after the focus record),
    /// looking again every 100 ms for up to 400 ms.
    static func steady(_ first: CGImage?, window: WindowService.Window, app: AppRef) async -> CGImage? {
        var picture = first
        for _ in 0..<4 {
            try? await Task.sleep(for: .milliseconds(100))
            let next = await look(window, app: app)
            guard differs(picture, next) else { return next ?? picture }
            picture = next
        }
        return picture
    }

    /// Whether two pictures of a window differ by more than a few pixels, in more than a hairline
    /// (a blinking text caret changes a strip a few pixels wide).
    static func differs(_ before: CGImage?, _ after: CGImage?) -> Bool {
        guard let before, let after else { return false }
        guard before.width == after.width, before.height == after.height else { return true }
        guard let change = change(before, after) else { return false }
        return isEffect(changed: change.count, width: change.width, height: change.height, of: before.width * before.height)
    }

    /// Whether the window's close button changed color between two pictures: the window went from
    /// looking inactive to active (or back), which recolors more than the button and isn't an effect
    /// of the click.
    static func turnedActive(_ before: CGImage?, _ after: CGImage?, closeButton: CGRect?) -> Bool {
        guard let before, let after, let closeButton, closeButton.width >= 2, closeButton.height >= 2,
              let change = change(before, after, in: closeButton) else { return false }
        return change.count * 4 > Int(closeButton.width * closeButton.height)
    }

    /// Where the window's close button is in a picture of the window, if it has one.
    static func closeButton(of window: WindowService.Window, in picture: CGImage?) -> CGRect? {
        guard let picture, window.info.frame.width > 0, let button = AX.element(window.element, "AXCloseButton"),
              let frame = AX.frame(button) else { return nil }
        let scale = CGFloat(picture.width) / window.info.frame.width
        return CGRect(
            x: (frame.minX - window.info.frame.x) * scale, y: (frame.minY - window.info.frame.y) * scale,
            width: frame.width * scale, height: frame.height * scale
        ).integral
    }

    /// How many pixels differ between two same-sized pictures (in `region` when given), and the
    /// size of the box around them.
    static func change(_ before: CGImage, _ after: CGImage, in region: CGRect? = nil) -> (count: Int, width: Int, height: Int)? {
        guard before.width == after.width, before.height == after.height,
              let old = pixels(of: before), let new = pixels(of: after) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: before.width, height: before.height)
        let area = (region ?? bounds).intersection(bounds)
        guard !area.isNull, area.width > 0, area.height > 0 else { return nil }
        var changed = 0
        var box: (minX: Int, minY: Int, maxX: Int, maxY: Int) = (.max, .max, -1, -1)
        for y in Int(area.minY)..<Int(area.maxY) {
            for x in Int(area.minX)..<Int(area.maxX) {
                let index = (y * before.width + x) * 4
                let delta = max(abs(Int(old[index]) - Int(new[index])), abs(Int(old[index + 1]) - Int(new[index + 1])), abs(Int(old[index + 2]) - Int(new[index + 2])))
                guard delta > 24 else { continue }
                changed += 1
                box = (min(box.minX, x), min(box.minY, y), max(box.maxX, x), max(box.maxY, y))
            }
        }
        guard changed > 0 else { return (0, 0, 0) }
        return (changed, box.maxX - box.minX + 1, box.maxY - box.minY + 1)
    }

    /// Whether `changed` pixels within a `width` × `height` box, out of `total`, look like an effect
    /// rather than noise or a caret.
    static func isEffect(changed: Int, width: Int, height: Int, of total: Int) -> Bool {
        changed > max(8, total / 5000) && width > 3 && height > 3
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
