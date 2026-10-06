import AppKit
import CoreText
import Foundation
import HarnessProtocol
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Captures exactly one window (never other apps' pixels), optionally cropped and labeled.
public enum ScreenshotService {
    public static func capture(_ params: ScreenshotMethod.Params) async throws -> ScreenshotMethod.Result {
        guard CGPreflightScreenCaptureAccess() else {
            throw RPCError(code: RPCErrorCode.permissionMissing, message: "macOS Harness doesn't have Screen Recording permission. Run `macos-harness doctor`.")
        }
        let app = try await MainActor.run { try AppResolver.resolve(params.target.app) }
        let window = try WindowService.resolve(params.target, app: app)
        var notices = await Notices.collect(for: window.info)

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let scWindow = content.windows.first(where: { $0.windowID == window.info.id }) else {
            throw RPCError(code: RPCErrorCode.failed, message: "Window \(window.info.id) of \(app.name) can't be captured right now (it may be closing).")
        }
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let nativeScale = CGFloat(filter.pointPixelScale)
        let frame = window.info.frame
        var scale = nativeScale
        let longest = max(frame.width, frame.height) * nativeScale
        if params.maxSize > 0, longest > CGFloat(params.maxSize) {
            scale = nativeScale * CGFloat(params.maxSize) / longest
        }
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int((frame.width * scale).rounded()))
        configuration.height = max(1, Int((frame.height * scale).rounded()))
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        var image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        scale = CGFloat(image.width) / frame.width

        if window.info.minimized || !window.info.onScreen, isBlank(image) {
            notices.append(Notice(kind: "blank", message: "The image is blank: the window is minimized or on another Space."))
        }

        var crop: Rect? = nil
        if let ref = params.element {
            let element = try Snapshotter.element(for: ref, app: app)
            guard let global = AX.frame(element)?.intersection(frame.cgRect), !global.isNull, global.width >= 1 else {
                throw RPCError(code: RPCErrorCode.failed, message: "\(ref) isn't visible in the window, so there's nothing to crop to.")
            }
            let relative = Rect(x: global.minX - frame.x, y: global.minY - frame.y, width: global.width, height: global.height)
            let pixels = CGRect(x: relative.x * scale, y: relative.y * scale, width: relative.width * scale, height: relative.height * scale).integral
            if let cropped = image.cropping(to: pixels) {
                image = cropped
                crop = relative
            }
        }

        var labeled: [String] = []
        if params.labels {
            let snapshot = try await Snapshotter.snapshot(.init(target: Target(app: params.target.app, window: window.info.id), maxNodes: 400))
            let targets = labelTargets(snapshot.root)
            image = draw(labels: targets, on: image, scale: scale, origin: crop.map { CGPoint(x: $0.x, y: $0.y) } ?? .zero)
            labeled = targets.map(\.ref)
        }

        return ScreenshotMethod.Result(
            window: window.info, pngBase64: try png(image).base64EncodedString(), width: image.width,
            height: image.height, scale: (Double(scale) * 1000).rounded() / 1000, crop: crop,
            labeledRefs: labeled, notices: notices
        )
    }

    /// Elements worth a label: anything you can act on.
    static func labelTargets(_ root: UINode) -> [UINode] {
        var result: [UINode] = []
        func visit(_ node: UINode) {
            if node.frame != nil, !node.actions.isEmpty || AX.interactiveRoles.contains(node.role), node.role != "AXWindow" {
                result.append(node)
            }
            node.children.forEach(visit)
        }
        visit(root)
        return Array(result.prefix(250))
    }

    static func draw(labels nodes: [UINode], on image: CGImage, scale: CGFloat, origin: CGPoint) -> CGImage {
        let width = image.width
        let height = image.height
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        // Flip so drawing uses the same top-left origin as window coordinates.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)

        let accent = CGColor(red: 1, green: 0.16, blue: 0.55, alpha: 1)
        let font = CTFontCreateWithName("Menlo-Bold" as CFString, max(10, 8 * scale), nil)
        for node in nodes {
            guard let frame = node.frame else { continue }
            let box = CGRect(
                x: (frame.x - origin.x) * scale, y: (frame.y - origin.y) * scale,
                width: frame.width * scale, height: frame.height * scale
            )
            context.setStrokeColor(accent)
            context.setLineWidth(max(1, scale * 0.75))
            context.stroke(box)

            let text = NSAttributedString(string: node.ref, attributes: [
                .font: font, .foregroundColor: CGColor(red: 1, green: 1, blue: 1, alpha: 1),
            ])
            let line = CTLineCreateWithAttributedString(text)
            let bounds = CTLineGetImageBounds(line, context)
            let padding = max(3, 2 * scale)
            let tag = CGRect(x: box.minX, y: box.minY, width: bounds.width + 2 * padding, height: bounds.height + 2 * padding)
            context.setFillColor(accent)
            context.fill(tag)
            context.saveGState()
            // Text draws upward from its baseline, so undo the flip locally.
            context.translateBy(x: tag.minX + padding, y: tag.maxY - padding)
            context.scaleBy(x: 1, y: -1)
            context.textPosition = .zero
            CTLineDraw(line, context)
            context.restoreGState()
        }
        return context.makeImage() ?? image
    }

    static func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw RPCError(code: RPCErrorCode.internalError, message: "can't encode PNG")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw RPCError(code: RPCErrorCode.internalError, message: "can't encode PNG")
        }
        return data as Data
    }

    /// A blank or solid capture downsamples to one or two colors.
    static func isBlank(_ image: CGImage) -> Bool {
        let side = 16
        var pixels = [UInt32](repeating: 0, count: side * side)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        return drawn && Set(pixels).count <= 2
    }
}
