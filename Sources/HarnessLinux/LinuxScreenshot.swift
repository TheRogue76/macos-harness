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
        guard let compositor = await Compositors.current() else {
            throw RPCError(
                code: RPCErrorCode.failed,
                message: "Screenshots of Linux desktop apps need a compositor the harness can ask for pixels; so far that's Sway and other wlroots compositors."
            )
        }
        let place = try await place(params.target)
        guard let placed = place.placed else {
            throw RPCError(code: RPCErrorCode.failed, message: "\(compositor.name) doesn't show \(place.ref.name)'s window, so there's nothing to capture.")
        }
        let (png, _) = try await compositor.capture(placed)
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
        if let spacing = params.grid, spacing >= 10 {
            request.grid = Double(spacing)
        }
        var labeled: [String] = []
        if params.labels {
            let current: RawNode
            if let tree { current = tree } else { current = try await self.tree(of: place, limit: 8000) }
            let shaped = TreeShaper(window: place.frame, maxNodes: 400, maxDepth: 40, ref: registrar(place)).shape(current)
            let targets = TreeShaper.labelTargets(shaped.root)
            request.labels = targets
            labeled = targets.map(\.ref)
        }
        let rendered = try imaging.render(png, request: request)
        return ScreenshotMethod.Result(
            window: place.info, pngBase64: rendered.png.base64EncodedString(), width: rendered.width, height: rendered.height,
            scale: (rendered.scale * 1000).rounded() / 1000, crop: rendered.crop, labeledRefs: labeled, notices: place.notices
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
