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
        if params.target.androidDevice != nil { return try await AndroidService.screenshot(params) }
        if params.target.simulatorDevice == nil, !CGPreflightScreenCaptureAccess() {
            throw RPCError(code: RPCErrorCode.permissionMissing, message: "macOS Harness doesn't have Screen Recording permission. Run `macos-harness doctor`.")
        }
        let (app, window) = try await TargetResolver.resolve(params.target)
        var notices = await Notices.collect(for: window.info)
        let space = window.space
        var image = try await image(of: window, app: app, maxSize: params.maxSize)
        let scale = CGFloat(image.width) / max(space.size.width, 1)

        if !window.isSimulator, window.info.minimized || !window.info.onScreen, isBlank(image) {
            notices.append(Notice(kind: "blank", message: "The image is blank: the window is minimized or on another Space."))
        }

        var crop: Rect? = nil
        if let ref = params.element {
            let element = try Snapshotter.element(for: ref, app: app)
            guard let global = AX.frame(element)?.intersection(space.frame), !global.isNull, global.width >= 1 else {
                throw RPCError(code: RPCErrorCode.failed, message: "\(ref) isn't visible in the window, so there's nothing to crop to.")
            }
            let relative = space.local(global)
            let pixels = CGRect(x: relative.x * scale, y: relative.y * scale, width: relative.width * scale, height: relative.height * scale).integral
            if let cropped = image.cropping(to: pixels) {
                image = cropped
                crop = relative
            }
        }

        if let spacing = params.grid, spacing >= 10 {
            image = draw(grid: CGFloat(spacing), on: image, scale: scale, origin: crop.map { CGPoint(x: $0.x, y: $0.y) } ?? .zero)
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

    /// The window's pixels (and nothing else), at most `maxSize` pixels on the longest edge (0: native).
    static func image(of window: WindowService.Window, app: AppRef, maxSize: Int) async throws -> CGImage {
        if let device = window.info.simulator {
            return try await simulatorImage(device, maxSize: maxSize)
        }
        guard CGPreflightScreenCaptureAccess() else {
            throw RPCError(code: RPCErrorCode.permissionMissing, message: "macOS Harness doesn't have Screen Recording permission. Run `macos-harness doctor`.")
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let scWindow = content.windows.first(where: { $0.windowID == window.info.id }) else {
            throw RPCError(code: RPCErrorCode.failed, message: "Window \(window.info.id) of \(app.name) can't be captured right now (it may be closing).")
        }
        let frame = window.info.frame
        let configuration = SCStreamConfiguration()
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        let filter: SCContentFilter
        if window.info.onScreen, !window.info.minimized,
           let display = content.displays.max(by: { $0.frame.intersection(frame.cgRect).area < $1.frame.intersection(frame.cgRect).area }),
           display.frame.intersects(frame.cgRect) {
            filter = SCContentFilter(display: display, including: [scWindow])
            configuration.sourceRect = frame.cgRect.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        } else {
            filter = SCContentFilter(desktopIndependentWindow: scWindow)
        }
        let nativeScale = CGFloat(filter.pointPixelScale)
        var scale = nativeScale
        let longest = max(frame.width, frame.height) * nativeScale
        if maxSize > 0, longest > CGFloat(maxSize) {
            scale = nativeScale * CGFloat(maxSize) / longest
        }
        configuration.width = max(1, Int((frame.width * scale).rounded()))
        configuration.height = max(1, Int((frame.height * scale).rounded()))
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    /// The simulator's screen in its own pixels, at most `maxSize` pixels on the longest edge.
    static func simulatorImage(_ device: SimulatorInfo, maxSize: Int) async throws -> CGImage {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("macos-harness-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try await Simctl.run(["io", device.udid, "screenshot", "--type=png", url.path], timeout: 30)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw RPCError(code: RPCErrorCode.failed, message: "simctl wrote a screenshot of \(device.name) that couldn't be read.")
        }
        let longest = max(image.width, image.height)
        guard maxSize > 0, longest > maxSize else { return image }
        return resized(image, by: CGFloat(maxSize) / CGFloat(longest)) ?? image
    }

    static func resized(_ image: CGImage, by factor: CGFloat) -> CGImage? {
        let width = max(1, Int((CGFloat(image.width) * factor).rounded()))
        let height = max(1, Int((CGFloat(image.height) * factor).rounded()))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
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
            context.translateBy(x: tag.minX + padding, y: tag.maxY - padding)
            context.scaleBy(x: 1, y: -1)
            context.textPosition = .zero
            CTLineDraw(line, context)
            context.restoreGState()
        }
        return context.makeImage() ?? image
    }

    /// Lines every `spacing` window points, labeled with their window coordinates.
    static func draw(grid spacing: CGFloat, on image: CGImage, scale: CGFloat, origin: CGPoint) -> CGImage {
        let width = image.width
        let height = image.height
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)

        let line = CGColor(red: 0, green: 0.75, blue: 1, alpha: 0.45)
        let font = CTFontCreateWithName("Menlo-Bold" as CFString, max(9, 7 * scale), nil)
        let visible = CGSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale)
        func label(_ text: String, at point: CGPoint) {
            let attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: CGColor(red: 1, green: 1, blue: 1, alpha: 1)])
            let rendered = CTLineCreateWithAttributedString(attributed)
            let bounds = CTLineGetImageBounds(rendered, context)
            let padding = max(2, 1.5 * scale)
            let tag = CGRect(x: point.x, y: point.y, width: bounds.width + 2 * padding, height: bounds.height + 2 * padding)
            context.setFillColor(CGColor(red: 0, green: 0.45, blue: 0.75, alpha: 0.85))
            context.fill(tag)
            context.saveGState()
            context.translateBy(x: tag.minX + padding, y: tag.maxY - padding)
            context.scaleBy(x: 1, y: -1)
            context.textPosition = .zero
            CTLineDraw(rendered, context)
            context.restoreGState()
        }
        context.setStrokeColor(line)
        context.setLineWidth(max(1, scale * 0.5))
        var x = (origin.x / spacing).rounded(.up) * spacing
        while x - origin.x < visible.width {
            let pixel = (x - origin.x) * scale
            context.strokeLineSegments(between: [CGPoint(x: pixel, y: 0), CGPoint(x: pixel, y: CGFloat(height))])
            label("\(Int(x))", at: CGPoint(x: pixel + 2, y: 2))
            x += spacing
        }
        var y = (origin.y / spacing).rounded(.up) * spacing
        while y - origin.y < visible.height {
            let pixel = (y - origin.y) * scale
            context.strokeLineSegments(between: [CGPoint(x: 0, y: pixel), CGPoint(x: CGFloat(width), y: pixel)])
            if y > 0 { label("\(Int(y))", at: CGPoint(x: 2, y: pixel + 2)) }
            y += spacing
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

    /// Whether the image is blank or one solid color.
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

