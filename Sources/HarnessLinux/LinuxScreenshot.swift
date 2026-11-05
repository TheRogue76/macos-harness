#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import HarnessCore
import HarnessProtocol

extension LinuxDesktop {
    /// `screenshot` of a desktop app's window, through the compositor: the window, or one element
    /// of it, with labels or a grid drawn as on the other platforms.
    public static func screenshot(_ params: ScreenshotMethod.Params) async throws -> ScreenshotMethod.Result {
        let compositor = try await Compositors.required(for: "screenshot")
        let place = try await place(params.target)
        guard let placed = place.placed else {
            throw RPCError(code: RPCErrorCode.failed, message: "\(compositor.name) doesn't show \(place.ref.name)'s window, so there's nothing to capture.")
        }
        let (png, _) = try await compositor.capture(placed)
        var notices = place.notices
        let covers = await compositor.covering(placed)
        if !covers.isEmpty {
            let names = covers.prefix(3).map { "“\($0.title)”" }.joined(separator: ", ")
            notices.append(Notice(
                kind: "covered",
                message: "\(names) \(covers.count == 1 ? "covers" : "cover") part of the window, and \(compositor.name) can only capture the screen, so the screenshot shows \(covers.count == 1 ? "it" : "them"). Bring the window forward with `window activate` first if that matters."
            ))
        }
        let imaging = try ScreenImagingProvider.imaging()
        var request = ScreenRender(maxSize: params.maxSize, screenSize: place.frame.size)
        var tree: RawNode?
        if let ref = params.element {
            let current = try await self.tree(of: place, limit: 8000)
            tree = current
            let path = try path(for: ref, in: place)
            guard let frame = find(path, in: current)?.frame?.intersection(place.frame), !frame.isNull else {
                throw RPCError(code: RPCErrorCode.failed, message: "\(ref) isn't in the window's visible part, so there's nothing to crop to.")
            }
            request.crop = frame
        }
        var grid = params.grid
        var labeled: [String] = []
        if params.labels {
            let current: RawNode
            if let tree { current = tree } else { current = try await self.tree(of: place, limit: 8000) }
            let shaped = TreeShaper(window: place.frame, maxNodes: 400, maxDepth: 40, ref: registrar(place)).shape(current)
            let targets = TreeShaper.labelTargets(shaped.root)
            request.labels = targets
            labeled = targets.map(\.ref)
            if grid == nil {
                if targets.isEmpty {
                    grid = 100
                    notices.append(Notice(
                        kind: "gridFallback",
                        message: "Nothing in the window has a label to draw, so a 100-point grid shows its coordinates instead; click by them with `pointer`."
                    ))
                } else if let bare = TreeShaper.unlabeledArea(shaped.root, targets: targets, width: place.frame.width, height: place.frame.height) {
                    grid = 100
                    let what = bare.role.hasPrefix("AX") ? String(bare.role.dropFirst(2)).lowercased() : bare.role
                    notices.append(Notice(
                        kind: "gridFallback",
                        message: "Nothing is labeled in a large \(what) (\(bare.ref)), so a 100-point grid shows its coordinates; click there by them with `pointer`."
                    ))
                }
            }
        }
        if let spacing = grid, spacing >= 10 {
            request.grid = Double(spacing)
        }
        let rendered = try imaging.render(png, request: request)
        return ScreenshotMethod.Result(
            window: place.info, pngBase64: rendered.png.base64EncodedString(), width: rendered.width, height: rendered.height,
            scale: (rendered.scale * 1000).rounded() / 1000, crop: rendered.crop, labeledRefs: labeled, notices: notices
        )
    }

    /// The node with an object path in a raw tree.
    static func find(_ path: String, in node: RawNode) -> RawNode? {
        if (node.key?.base as? ATSPIKey)?.path == path { return node }
        for child in node.children {
            if let found = find(path, in: child) { return found }
        }
        return nil
    }
}
