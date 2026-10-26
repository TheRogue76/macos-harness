#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import HarnessCore
import HarnessProtocol
import HarnessWayland

/// Real input on Linux desktop apps: the pointer actions, keys and typed text, through the
/// compositor's virtual devices. They move the user's real pointer and type into the focused
/// window, so they take a turn with the input, bring the window forward, and are refused to
/// agents working in the background only.
extension LinuxDesktop {
    public static func pointer(_ params: PointerMethod.Params, context: ActionContext) async throws -> ActionResult {
        if context.backgroundOnly {
            throw PolicyEnforcer.backgroundOnly("step needs the real mouse, which it doesn't use")
        }
        let (compositor, place) = try await placedWindow(params.target, needs: params.action.rawValue)
        try await context.claim(WindowClaims.key(window: place.info.id), place: "\(place.ref.name)'s window “\(place.info.title)”")
        let before = try await tree(of: place, limit: 4000)
        let (start, node) = try await point(params.element, or: params.point, in: place, tree: before)
        let shaper = TreeShaper(window: place.frame, maxNodes: 1, maxDepth: 0, ref: registrar(place))
        let name = node.map { ActionService.describe(shaper.makeNode($0, visible: $0.frame)) } ?? "the point \(Int(start.x)),\(Int(start.y))"
        var end: CGPoint?
        if params.action == .drag {
            if params.toTarget != nil {
                throw RPCError(code: RPCErrorCode.failed, message: "Dragging into another window isn't supported on Linux yet.")
            }
            end = try await point(params.to, or: params.toPoint, in: place, tree: before).point
        }
        let modifiers = try xkbModifiers(KeyChord.modifiers(named: params.modifiers))
        let (token, waited) = try await context.takeTurn()
        let performed: String
        do {
            try await compositor.activate(place.placed!)
            let input = try await compositor.input()
            defer { Task { await input.release() } }
            let origin = place.placed!.frame.origin
            func screen(_ point: CGPoint) -> CGPoint { CGPoint(x: origin.x + point.x, y: origin.y + point.y) }
            if modifiers != 0 { try await input.hold(modifiers) }
            defer { if modifiers != 0 { try? await input.hold(0) } }
            try await input.move(to: screen(start))
            switch params.action {
            case .click, .doubleClick, .rightClick:
                let button = params.action == .rightClick ? WaylandPointer.right : WaylandPointer.left
                for _ in 0..<(params.action == .doubleClick ? 2 : 1) {
                    try await input.button(button, pressed: true)
                    try await input.button(button, pressed: false)
                }
                performed = "\(params.action == .rightClick ? "right-clicked" : params.action == .doubleClick ? "double-clicked" : "clicked") \(name)"
            case .hover:
                try await Task.sleep(for: .seconds(max(params.hold, 0.3)))
                performed = "hovered over \(name)"
            case .longPress:
                try await input.button(WaylandPointer.left, pressed: true)
                try await Task.sleep(for: .seconds(params.hold > 0 ? params.hold : 0.8))
                try await input.button(WaylandPointer.left, pressed: false)
                performed = "long-pressed \(name)"
            case .scroll:
                try await input.scroll(dx: params.dx, dy: params.dy)
                performed = "scrolled \(name) by \(Int(params.dx)),\(Int(params.dy))"
            case .drag, .swipe:
                let target = end ?? CGPoint(x: start.x + params.dx, y: start.y + params.dy)
                try await input.button(WaylandPointer.left, pressed: true)
                if params.hold > 0 { try await Task.sleep(for: .seconds(params.hold)) }
                let steps = 20
                let duration = params.duration > 0 ? params.duration : 0.3
                for step in 1...steps {
                    let fraction = Double(step) / Double(steps)
                    try await input.move(to: screen(CGPoint(x: start.x + (target.x - start.x) * fraction, y: start.y + (target.y - start.y) * fraction)))
                    try await Task.sleep(for: .seconds(duration / Double(steps)))
                }
                try await input.button(WaylandPointer.left, pressed: false)
                performed = "\(params.action == .swipe ? "swiped" : "dragged") from \(name) to \(Int(target.x)),\(Int(target.y))"
            }
            if modifiers != 0 { try await input.hold(0) }
            try await input.flush()
        } catch {
            await context.endTurn(token, holdingMenuWhile: nil)
            throw error
        }
        await context.endTurn(token, holdingMenuWhile: nil)
        let point = Point(x: place.placed!.frame.minX + start.x, y: place.placed!.frame.minY + start.y)
        var result = ActionResult(
            app: place.ref, window: place.info, element: node.map { shaper.makeNode($0, visible: $0.frame) }, performed: performed,
            via: "virtual-pointer", notices: place.notices + [waited].compactMap { $0 }
        )
        result.screenPoint = point
        if params.diff { await settle(&result, before: before, place: place) }
        return result
    }

    /// `key`, and `type` with real input: keys through the virtual keyboard into the window,
    /// which is brought forward first.
    static func realKeys(_ params: ActMethod.Params, context: ActionContext) async throws -> ActionResult {
        if context.backgroundOnly {
            throw PolicyEnforcer.backgroundOnly("step needs the real keyboard, which it doesn't use")
        }
        let (compositor, place) = try await placedWindow(params.target, needs: params.action.rawValue)
        try await context.claim(WindowClaims.key(window: place.info.id), place: "\(place.ref.name)'s window “\(place.info.title)”")
        let before = try await tree(of: place, limit: 4000)
        var node: RawNode?
        if let selector = params.element, !selector.isEmpty {
            node = try await resolve(selector, in: place, tree: before)
        }
        let value = try ActionService.required(params.value, params.action == .key ? "key needs a combination, e.g. enter" : "type needs text")
        let (token, waited) = try await context.takeTurn()
        let performed: String
        do {
            try await compositor.activate(place.placed!)
            if let node, let key = node.key?.base as? ATSPIKey, let item = place.items.first(where: { $0.path == key.path }) {
                try? await Element(bus: place.app.bus, item: item, connection: place.connection, name: "").focus()
            }
            let input = try await compositor.input()
            defer { Task { await input.release() } }
            if params.action == .key {
                let chord = try KeyChord.parse(value)
                try await input.tap(keysym(chord.key), modifiers: try xkbModifiers(chord.modifiers))
                performed = "pressed \(value) in \(place.ref.name)"
            } else {
                try await input.type(value)
                performed = "typed “\(value.count > 40 ? String(value.prefix(40)) + "…" : value)” with the keyboard"
            }
            try await input.flush()
        } catch {
            await context.endTurn(token, holdingMenuWhile: nil)
            throw error
        }
        await context.endTurn(token, holdingMenuWhile: nil)
        let shaper = TreeShaper(window: place.frame, maxNodes: 1, maxDepth: 0, ref: registrar(place))
        var result = ActionResult(
            app: place.ref, window: place.info, element: node.map { shaper.makeNode($0, visible: $0.frame) }, performed: performed,
            via: "virtual-keyboard", notices: place.notices + [waited].compactMap { $0 }
        )
        if params.diff { await settle(&result, before: before, place: place) }
        return result
    }

    /// Clicks a window-relative point with the real pointer, to give what's there focus.
    static func clickToFocus(at point: CGPoint, in place: Place, context: ActionContext) async throws {
        guard let compositor = await Compositors.current(), let placed = place.placed else { return }
        let (token, _) = try await context.takeTurn()
        do {
            try await compositor.activate(placed)
            let input = try await compositor.input()
            defer { Task { await input.release() } }
            try await input.move(to: CGPoint(x: placed.frame.minX + point.x, y: placed.frame.minY + point.y))
            try await input.button(WaylandPointer.left, pressed: true)
            try await input.button(WaylandPointer.left, pressed: false)
            try await input.flush()
        } catch {
            await context.endTurn(token, holdingMenuWhile: nil)
            throw error
        }
        await context.endTurn(token, holdingMenuWhile: nil)
    }

    /// The compositor and a window it places, or why real input can't reach it.
    static func placedWindow(_ target: Target, needs command: String) async throws -> (any Compositor, Place) {
        let compositor = try await Compositors.required(for: command)
        let place = try await place(target)
        guard place.placed != nil else {
            throw RPCError(code: RPCErrorCode.failed, message: "\(compositor.name) doesn't show \(place.ref.name)'s window, so input can't reach it.")
        }
        return (compositor, place)
    }

    /// A window-relative point: an element's center, or the point given.
    static func point(_ selector: ElementSelector?, or point: Point?, in place: Place, tree: RawNode) async throws -> (point: CGPoint, node: RawNode?) {
        if let selector, !selector.isEmpty {
            let node = try await resolve(selector, in: place, tree: tree)
            guard let frame = node.frame, frame.width > 0, frame.height > 0 else {
                throw RPCError(code: RPCErrorCode.failed, message: "That element has no size on screen, so there's nowhere to point at.")
            }
            return (CGPoint(x: frame.midX, y: frame.midY), node)
        }
        guard let point else {
            throw RPCError(code: RPCErrorCode.invalidParams, message: "Say where: an element (a ref, --text, --role or --id) or --x and --y.")
        }
        return (CGPoint(x: point.x, y: point.y), nil)
    }

    /// XKB's modifier masks for a chord's modifiers; ⌘ is Control, as Linux apps expect.
    static func xkbModifiers(_ modifiers: KeyModifiers) throws -> UInt32 {
        var mask: UInt32 = 0
        if modifiers.contains(.shift) { mask |= XKBKeymap.shift }
        if modifiers.contains(.control) || modifiers.contains(.command) { mask |= XKBKeymap.control }
        if modifiers.contains(.option) { mask |= XKBKeymap.alt }
        return mask
    }

    /// The XKB keysym name a chord's key types.
    static func keysym(_ key: KeyChord.Key) -> String {
        switch key {
        case .character(let character): return XKBKeymap.keysym(for: character)
        case .named(let named):
            switch named {
            case .return: return "Return"
            case .tab: return "Tab"
            case .space: return "space"
            case .delete: return "BackSpace"
            case .escape: return "Escape"
            case .forwardDelete: return "Delete"
            case .home: return "Home"
            case .end: return "End"
            case .pageUp: return "Prior"
            case .pageDown: return "Next"
            case .left: return "Left"
            case .right: return "Right"
            case .down: return "Down"
            case .up: return "Up"
            default: return named.rawValue.uppercased()
            }
        }
    }
}
