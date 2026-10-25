import CoreGraphics
import Foundation
import HarnessCore
import HarnessProtocol
import ImageIO

/// Device screenshots rendered with Core Graphics and read with on-device text recognition.
public struct MacScreenImaging: ScreenImaging {
    public init() {}

    public func render(_ png: Data, request: ScreenRender) throws -> RenderedScreen {
        var image = try Self.decode(png)
        let longest = max(image.width, image.height)
        if request.maxSize > 0, longest > request.maxSize {
            image = ScreenshotService.resized(image, by: CGFloat(request.maxSize) / CGFloat(longest)) ?? image
        }
        let scale = CGFloat(image.width) / max(request.screenSize.width, 1)
        var crop: Rect?
        if let frame = request.crop {
            let pixels = CGRect(x: frame.minX * scale, y: frame.minY * scale, width: frame.width * scale, height: frame.height * scale).integral
            if let cropped = image.cropping(to: pixels) {
                image = cropped
                crop = Rect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height)
            }
        }
        let origin = crop.map { CGPoint(x: $0.x, y: $0.y) } ?? .zero
        if let spacing = request.grid {
            image = ScreenshotService.draw(grid: CGFloat(spacing), on: image, scale: scale, origin: origin)
        }
        if let labels = request.labels {
            image = ScreenshotService.draw(labels: labels, on: image, scale: scale, origin: origin)
        }
        return RenderedScreen(png: try ScreenshotService.png(image), width: image.width, height: image.height, scale: Double(scale), crop: crop)
    }

    public func findText(_ query: String?, exact: Bool, inPNG png: Data, size: CGSize) throws -> [TextMatch] {
        try OCRService.find(query, exact: exact, image: Self.decode(png), size: size)
    }

    static func decode(_ png: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ScreenImagingError.unreadable
        }
        return image
    }
}
