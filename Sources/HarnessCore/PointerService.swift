import AppKit
import ApplicationServices
import Foundation
import HarnessProtocol

/// Real mouse actions: click, double-click, right-click, hover, drag, scroll.
public enum PointerService {
    public static func pointer(_ params: PointerMethod.Params, context: ActionContext) async throws -> ActionResult {
        let app = try await MainActor.run { try AppResolver.resolve(params.target.app) }
        let window = try WindowService.resolve(params.target, app: app)
        let before = params.diff ? Settle.Capture.take(window: window, app: app) : nil
        let flags = try modifierFlags(params.modifiers)

        let (point, node) = try resolve(params.element, point: params.point, window: window, app: app, role: "target")
        let place = "(\(Int(point.x - window.info.frame.x)), \(Int(point.y - window.info.frame.y)))"
        let what = node.map(ActionService.describe) ?? "point \(place)"
        var destination: (CGPoint, UINode?)?
        if params.action == .drag {
            destination = try resolve(params.to, point: params.toPoint, window: window, app: app, role: "drag destination")
        }

        let performed: String
        switch params.action {
        case .click: performed = "clicked \(what)"
        case .doubleClick: performed = "double-clicked \(what)"
        case .rightClick: performed = "right-clicked \(what)"
        case .hover: performed = "hovered over \(what)"
        case .scroll: performed = "scrolled \(what) by \(Int(params.dx)),\(Int(params.dy))"
        case .drag:
            let to = destination.map { $0.1.map(ActionService.describe) ?? "(\(Int($0.0.x - window.info.frame.x)), \(Int($0.0.y - window.info.frame.y)))" } ?? "?"
            performed = "dragged \(what) to \(to)"
        }

        await RealInputHooks.shared.willAct?(point, performed, context.owner, context.ownerName)
        let session = try await RealInputSession.begin(app: app, window: window, context: context, keyboard: false)
        do {
            switch params.action {
            case .click: try await session.click(at: point, flags: flags)
            case .doubleClick: try await session.click(at: point, count: 2, flags: flags)
            case .rightClick: try await session.click(at: point, button: .right, flags: flags)
            case .hover: try await session.hover(at: point, dwell: max(params.hold, 0.3))
            case .scroll: try await session.scroll(at: point, dx: params.dx, dy: params.dy)
            case .drag:
                guard let destination else { throw RPCError(code: RPCErrorCode.invalidParams, message: "drag needs a destination") }
                try await session.drag(from: point, to: destination.0, hold: params.hold, duration: params.duration, flags: flags)
            }
        } catch {
            await session.end()
            throw error
        }
        // Leave the cursor over the target for hovers (tooltips need it); otherwise put it back.
        await session.end(restoreCursor: params.action != .hover)

        var result = ActionResult(
            app: app, window: window.info, element: node, performed: performed, via: "real input",
            notices: session.notices, screenPoint: Point(x: point.x, y: point.y)
        )
        if params.action == .hover {
            result.notices.append(Notice(kind: "cursor", message: "The cursor stays over the target so tooltips and hover states remain visible."))
        }
        if let before {
            await Settle.finish(&result, before: before, window: window, app: app)
        }
        if params.action == .rightClick {
            // Some apps (Finder) hang the menu inside the window, so the diff already has it.
            let seen = Set(result.changes.map(\.node.ref))
            result.changes += contextMenuItems(app: app, window: window).filter { !seen.contains($0.node.ref) }
        }
        return result
    }

    /// An element's visible center, or a window-relative point, as a global point.
    static func resolve(
        _ selector: ElementSelector?, point: Point?, window: WindowService.Window, app: AppRef, role: String
    ) throws -> (CGPoint, UINode?) {
        if let selector, !selector.isEmpty {
            var target = try ElementResolver.resolve(selector, window: window, app: app, allowFocused: false)
            if target.visible == nil, target.raw.actions.contains("AXScrollToVisible") {
                _ = AX.perform(target.element, "AXScrollToVisible")
                target = ElementResolver.single(target.element, clip: window.info.frame.cgRect)
            }
            let shaper = TreeShaper(window: window.info.frame.cgRect, maxNodes: 1, maxDepth: 0, ref: Snapshotter.registrar(for: app))
            let node = shaper.makeNode(target.raw, visible: target.visible)
            guard let visible = target.visible else {
                throw RPCError(code: RPCErrorCode.failed, message: "\(ActionService.describe(node)) isn't visible in the window; use scroll-to or scroll first.")
            }
            return (CGPoint(x: visible.midX, y: visible.midY), node)
        }
        if let point {
            guard point.x >= 0, point.y >= 0, point.x <= window.info.frame.width, point.y <= window.info.frame.height else {
                throw RPCError(code: RPCErrorCode.invalidParams, message: "(\(Int(point.x)), \(Int(point.y))) is outside the window (\(Int(window.info.frame.width))x\(Int(window.info.frame.height))).")
            }
            return (CGPoint(x: window.info.frame.x + point.x, y: window.info.frame.y + point.y), nil)
        }
        throw RPCError(code: RPCErrorCode.invalidParams, message: "Give the \(role) as a ref, --text/--role/--id, or window-relative --x and --y.")
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

    /// Context menus aren't part of the window; list the open one's items so they can be pressed.
    static func contextMenuItems(app: AppRef, window: WindowService.Window) -> [UIChange] {
        let appElement = AX.application(app.pid)
        let menus = AX.children(appElement).filter { AX.role($0) == "AXMenu" }
        guard let menu = menus.last else { return [] }
        let raw = AXReader(maxNodes: 200, maxDepth: 3, timeBudget: 1).read(menu)
        let shaper = TreeShaper(window: window.info.frame.cgRect, maxNodes: 1, maxDepth: 0, ref: Snapshotter.registrar(for: app))
        // Menu items live outside the window, so they get refs but no window-relative click points.
        return TreeShaper.visibleMenuItems(raw.children).filter { $0.role == "AXMenuItem" }.map { item in
            UIChange(kind: "added", node: shaper.makeNode(item, visible: nil))
        }
    }
}
