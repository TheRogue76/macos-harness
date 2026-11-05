#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import HarnessCore
import HarnessProtocol

/// `window` on desktop apps: activating, moving, resizing, minimizing, restoring, full-screening
/// and closing a window, through the compositor, as the Mac does through accessibility. Bringing
/// a window forward takes a turn with the input and is refused when the user is typing elsewhere;
/// the harness's own windows are left alone.
extension LinuxDesktop {
    public static func window(_ params: WindowActionMethod.Params, context: ActionContext) async throws -> ActionResult {
        let (compositor, place) = try await placedWindow(params.target, needs: "window \(params.action.rawValue)")
        let placed = place.placed!
        if (placed.appID ?? "").hasPrefix(HarnessProduct.linuxAppID) {
            throw RPCError(code: RPCErrorCode.failed, message: "That's one of the harness's own windows, which agents can't rearrange.")
        }
        try await context.claim(WindowClaims.key(window: place.info.id), place: "\(place.ref.name)'s window “\(place.info.title)”")
        let name = "window \(place.info.id) “\(place.info.title)”"
        var notices = place.notices
        let performed: String
        switch params.action {
        case .activate:
            if context.backgroundOnly {
                throw PolicyEnforcer.backgroundOnly("step brings a window to the front, which takes focus from the user")
            }
            let (token, waited) = try await context.takeTurn()
            if let waited { notices.append(waited) }
            do {
                if !placed.visible { try await compositor.arrange(placed, .restore) }
                try await bringForward(placed, of: place.ref.name, with: compositor)
            } catch {
                await context.endTurn(token, holdingMenuWhile: nil)
                throw error
            }
            await context.endTurn(token, holdingMenuWhile: nil)
            performed = "brought \(place.ref.name) \(name) to the front"
        case .move:
            guard let x = params.x, let y = params.y else {
                throw RPCError(code: RPCErrorCode.invalidParams, message: "move needs --x and --y (global points, top-left).")
            }
            try await compositor.arrange(placed, .move(CGPoint(x: x, y: y)))
            performed = "moved \(name) to (\(Int(x)), \(Int(y)))"
        case .resize:
            guard let width = params.width, let height = params.height, width > 0, height > 0 else {
                throw RPCError(code: RPCErrorCode.invalidParams, message: "resize needs --width and --height (points).")
            }
            try await compositor.arrange(placed, .resize(CGSize(width: width, height: height)))
            performed = "resized \(name) to \(Int(width))x\(Int(height))"
        case .minimize:
            try await compositor.arrange(placed, .minimize)
            performed = "minimized \(name)"
        case .restore:
            try await compositor.arrange(placed, .restore)
            performed = "restored \(name)"
        case .fullscreen, .exitFullscreen:
            let on = params.action == .fullscreen
            try await compositor.arrange(placed, .fullscreen(on))
            performed = on ? "made \(name) full screen" : "took \(name) out of full screen"
        case .close:
            try await compositor.arrange(placed, .close)
            performed = "closed \(name)"
        }
        if [.move, .resize].contains(params.action), compositor is SwayCompositor {
            notices.append(Notice(kind: "floated", message: "Sway only moves and resizes floating windows, so the window floats now if it was tiled."))
        }
        if params.action == .minimize, compositor is SwayCompositor {
            notices.append(Notice(kind: "scratchpad", message: "Sway has no minimizing, so the window went to its scratchpad; `window restore` brings it back."))
        }
        try? await Task.sleep(for: .milliseconds(300))
        let now = try? await Self.place(params.target).info
        if params.action == .close, let now, now.id == place.info.id {
            notices.append(Notice(kind: "stillOpen", message: "The window is still open; it may be asking to save changes. Take a snapshot to see."))
        }
        return ActionResult(app: place.ref, window: now ?? place.info, element: nil, performed: performed, via: compositor.name, notices: notices)
    }
}
