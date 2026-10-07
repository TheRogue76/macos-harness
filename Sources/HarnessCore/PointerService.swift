import AppKit
import ApplicationServices
import Foundation
import HarnessProtocol

/// Real mouse actions: click, double-click, right-click, hover, drag, scroll.
public enum PointerService {
    public static func pointer(_ params: PointerMethod.Params, context: ActionContext) async throws -> ActionResult {
        let app = try await MainActor.run { try AppResolver.resolve(params.target.app) }
        let treeNotice = await HiddenTrees.shared.prepare(app)
        let window = try WindowService.resolve(params.target, app: app)
        let before = params.diff ? Settle.Capture.take(window: window, app: app) : nil
        let flags = try modifierFlags(params.modifiers)

        var target = try await place(params.element, point: params.point, window: window, app: app, role: "target")
        var destination: Placement?
        if params.action == .drag {
            destination = try await place(params.to, point: params.toPoint, window: window, app: app, role: "drag destination")
        }
        let what = describe(target, window: window)
        let performed: String
        switch params.action {
        case .click: performed = "clicked \(what)"
        case .doubleClick: performed = "double-clicked \(what)"
        case .rightClick: performed = "right-clicked \(what)"
        case .hover: performed = "hovered over \(what)"
        case .scroll: performed = "scrolled \(what) by \(Int(params.dx)),\(Int(params.dy))"
        case .drag: performed = "dragged \(what) to \(destination.map { describe($0, window: window) } ?? "?")"
        }

        let frame = window.info.frame.cgRect
        await RealInputHooks.shared.willAct?(target.point ?? CGPoint(x: frame.midX, y: frame.midY), performed, context.owner, context.ownerName)
        let session = try await RealInputSession.begin(app: app, window: window, context: context, keyboard: false)
        let point: CGPoint
        do {
            target = try await bringOnScreen(target, session: session, window: window)
            point = target.point ?? CGPoint(x: frame.midX, y: frame.midY)
            switch params.action {
            case .click: try await session.click(at: point, flags: flags)
            case .doubleClick: try await session.click(at: point, count: 2, flags: flags)
            case .rightClick: try await session.click(at: point, button: .right, flags: flags)
            case .hover: try await session.hover(at: point, dwell: max(params.hold, 0.3))
            case .scroll: try await session.scroll(at: point, dx: params.dx, dy: params.dy)
            case .drag:
                guard let placed = destination else { throw RPCError(code: RPCErrorCode.invalidParams, message: "drag needs a destination") }
                let end = try await bringOnScreen(placed, session: session, window: window)
                try await session.drag(from: point, to: end.point ?? point, hold: params.hold, duration: params.duration, flags: flags)
            }
        } catch {
            await session.end()
            throw error
        }
        await session.end(restoreCursor: params.action != .hover)

        var result = ActionResult(
            app: app, window: window.info, element: target.node, performed: performed, via: "real input",
            notices: [treeNotice].compactMap { $0 } + session.notices, screenPoint: Point(x: point.x, y: point.y)
        )
        if params.action == .hover {
            result.notices.append(Notice(kind: "cursor", message: "The cursor stays over the target so tooltips and hover states remain visible."))
        }
        if let before {
            await Settle.finish(&result, before: before, window: window, app: app)
        }
        if params.action == .rightClick {
            let seen = Set(result.changes.map(\.node.ref))
            result.changes += contextMenuItems(app: app, window: window).filter { !seen.contains($0.node.ref) }
        }
        return result
    }

    /// Where a pointer action lands: a global point, or the element still to bring on screen.
    struct Placement {
        var point: CGPoint?
        var node: UINode?
        var element: AXUIElement?
    }

    /// An element's on-screen center (scrolling it into view through AX if it can), or a
    /// window-relative point, as a global point.
    static func place(
        _ selector: ElementSelector?, point: Point?, window: WindowService.Window, app: AppRef, role: String
    ) async throws -> Placement {
        if let selector, selector.ocr == true {
            return try await placeByText(selector, window: window, app: app)
        }
        if let selector, !selector.isEmpty {
            var target = try ElementResolver.resolve(selector, window: window, app: app, allowFocused: false)
            if onScreen(target.visible) == nil, AX.scrollIntoView(target.element) == .success {
                target = ElementResolver.single(target.element, clip: window.info.frame.cgRect)
            }
            let shaper = TreeShaper(window: window.info.frame.cgRect, maxNodes: 1, maxDepth: 0, ref: Snapshotter.registrar(for: app))
            let node = shaper.makeNode(target.raw, visible: target.visible)
            let visible = onScreen(target.visible)
            return Placement(point: visible.map { CGPoint(x: $0.midX, y: $0.midY) }, node: node, element: target.element)
        }
        if let point {
            guard point.x >= 0, point.y >= 0, point.x <= window.info.frame.width, point.y <= window.info.frame.height else {
                throw RPCError(code: RPCErrorCode.invalidParams, message: "(\(Int(point.x)), \(Int(point.y))) is outside the window (\(Int(window.info.frame.width))x\(Int(window.info.frame.height))).")
            }
            return Placement(point: CGPoint(x: window.info.frame.x + point.x, y: window.info.frame.y + point.y))
        }
        throw RPCError(code: RPCErrorCode.invalidParams, message: "Give the \(role) as a ref, --text/--role/--id, or window-relative --x and --y.")
    }

    /// Where text recognition finds the selector's text, preferring a line that is exactly that text.
    static func placeByText(_ selector: ElementSelector, window: WindowService.Window, app: AppRef) async throws -> Placement {
        guard let text = selector.text, !text.isEmpty else {
            throw RPCError(code: RPCErrorCode.invalidParams, message: "OCR needs the text to look for.")
        }
        let found = try await OCRService.find(text, exact: selector.exact, in: window, app: app)
        let exact = found.filter { $0.line.compare(text, options: .caseInsensitive) == .orderedSame }
        let candidates = exact.isEmpty ? found : exact
        guard let first = candidates.first else {
            throw RPCError(code: RPCErrorCode.failed, message: "Text recognition didn't find “\(text)” in the window.")
        }
        guard candidates.count == 1 else {
            let places = candidates.prefix(8).map { "“\($0.line)” @\(Int($0.frame.midX)),\(Int($0.frame.midY))" }.joined(separator: "; ")
            throw RPCError(code: RPCErrorCode.failed, message: "“\(text)” appears \(candidates.count) times: \(places). Click one with --x and --y, or be more specific.")
        }
        let origin = window.info.frame
        return Placement(
            point: CGPoint(x: origin.x + first.frame.midX, y: origin.y + first.frame.midY),
            node: OCRService.node(first, index: 1)
        )
    }

    /// The placement with its element scrolled on screen by the real wheel, for apps whose scroll
    /// areas can't be scrolled through AX (SwiftUI forms).
    static func bringOnScreen(_ placement: Placement, session: RealInputSession, window: WindowService.Window) async throws -> Placement {
        guard let element = placement.element else { return placement }
        var updated = placement
        for attempt in 0...3 {
            let refreshed = ElementResolver.single(element, clip: window.info.frame.cgRect)
            if let visible = onScreen(refreshed.visible) {
                updated.point = CGPoint(x: visible.midX, y: visible.midY)
                return updated
            }
            guard attempt < 3, try await wheelScroll(element, session: session, window: window) else { break }
            try await Task.sleep(for: .milliseconds(300))
        }
        let name = placement.node.map(ActionService.describe) ?? "The element"
        throw RPCError(
            code: RPCErrorCode.failed,
            message: "\(name) isn't on screen (scrolled out of view, or past the edge of the display), and scrolling didn't bring it into view; move the window or scroll first."
        )
    }

    /// Scrolls the innermost scroll area whose viewport the element is outside of, starting from
    /// the element and working outward. Returns false when no scroll area keeps it out of view.
    static func wheelScroll(_ element: AXUIElement, session: RealInputSession, window: WindowService.Window) async throws -> Bool {
        guard let target = AX.frame(element) else { return false }
        let windowFrame = window.info.frame.cgRect
        var current = AX.element(element, "AXParent")
        while let node = current, AX.role(node) != "AXWindow" {
            if AX.role(node) == "AXScrollArea", let area = AX.frame(node) {
                let viewport = area.intersection(windowFrame)
                let outsideY = target.minY < viewport.minY || target.maxY > viewport.maxY
                let outsideX = target.minX < viewport.minX || target.maxX > viewport.maxX
                if outsideX || outsideY,
                   let shown = onScreen(ElementResolver.visibleFrame(node, frame: area, clip: windowFrame)) {
                    try await session.scroll(
                        at: CGPoint(x: shown.midX, y: shown.midY),
                        dx: outsideX ? -(target.midX - viewport.midX) : 0,
                        dy: outsideY ? -(target.midY - viewport.midY) : 0
                    )
                    return true
                }
            }
            current = AX.element(node, "AXParent")
        }
        return false
    }

    static func describe(_ placement: Placement, window: WindowService.Window) -> String {
        if let node = placement.node { return ActionService.describe(node) }
        guard let point = placement.point else { return "?" }
        return "point (\(Int(point.x - window.info.frame.x)), \(Int(point.y - window.info.frame.y)))"
    }

    /// The part of `rect` on a display, or nil when none of it is.
    static func onScreen(_ rect: CGRect?) -> CGRect? {
        guard let rect else { return nil }
        return NSScreen.screens.lazy
            .map { rect.intersection(RealInputSession.cgFrame(of: $0)) }
            .first { !$0.isNull && $0.width >= 1 && $0.height >= 1 }
    }

    static func modifierFlags(_ names: [String]) throws -> CGEventFlags {
        var flags: CGEventFlags = []
        for name in names {
            guard let (flag, _) = KeyCombo.modifierNames[name.lowercased()] else {
                throw RPCError(code: RPCErrorCode.invalidParams, message: "Unknown modifier \(name); use cmd, shift, opt or ctrl.")
            }
            flags.insert(flag)
        }
        return flags
    }

    /// The open context menu's items, as added changes with refs.
    static func contextMenuItems(app: AppRef, window: WindowService.Window) -> [UIChange] {
        let appElement = AX.application(app.pid)
        let menus = AX.children(appElement).filter { AX.role($0) == "AXMenu" }
        guard let menu = menus.last else { return [] }
        let raw = AXReader(maxNodes: 200, maxDepth: 3, timeBudget: 1).read(menu)
        let shaper = TreeShaper(window: window.info.frame.cgRect, maxNodes: 1, maxDepth: 0, ref: Snapshotter.registrar(for: app))
        return TreeShaper.visibleMenuItems(raw.children).filter { $0.role == "AXMenuItem" }.map { item in
            UIChange(kind: "added", node: shaper.makeNode(item, visible: nil))
        }
    }
}
