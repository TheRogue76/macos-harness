#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import HarnessProtocol
import Synchronization

/// Image work a platform does for device screenshots: scaling, cropping and marking them up, and
/// reading the text in them.
public protocol ScreenImaging: Sendable {
    /// The screenshot `png` rendered as `request` asks.
    func render(_ png: Data, request: ScreenRender) throws -> RenderedScreen
    /// Where `query` appears in the screenshot `png` of a screen `size` points across (each line
    /// once), or every line when `query` is nil.
    func findText(_ query: String?, exact: Bool, inPNG png: Data, size: CGSize) throws -> [TextMatch]
}

/// Why a platform couldn't work with a screenshot.
public enum ScreenImagingError: Error, Sendable {
    /// The image data couldn't be decoded.
    case unreadable
}

/// How to render a device screenshot.
public struct ScreenRender: Sendable {
    /// The longest side in pixels, scaling down to fit; 0 keeps the screenshot's size.
    public var maxSize: Int
    /// The screen's size in points.
    public var screenSize: CGSize
    /// The part of the screen to keep, in points; nil keeps it all.
    public var crop: CGRect?
    /// Grid line spacing in points; nil draws no grid.
    public var grid: Double?
    /// Elements to number on the image; nil draws no labels.
    public var labels: [UINode]?

    public init(maxSize: Int, screenSize: CGSize, crop: CGRect? = nil, grid: Double? = nil, labels: [UINode]? = nil) {
        self.maxSize = maxSize
        self.screenSize = screenSize
        self.crop = crop
        self.grid = grid
        self.labels = labels
    }
}

/// A rendered screenshot.
public struct RenderedScreen: Sendable {
    public var png: Data
    public var width: Int
    public var height: Int
    /// Image pixels per screen point.
    public var scale: Double
    /// The part of the screen the image shows when it was cropped, in points.
    public var crop: Rect?

    public init(png: Data, width: Int, height: Int, scale: Double, crop: Rect?) {
        self.png = png
        self.width = width
        self.height = height
        self.scale = scale
        self.crop = crop
    }
}

/// Text found by text recognition: what was asked for, where it is in the target's points, and
/// the line it's in.
public struct TextMatch: Sendable, Equatable {
    public var text: String
    public var line: String
    public var frame: CGRect

    public init(text: String, line: String, frame: CGRect) {
        self.text = text
        self.line = line
        self.frame = frame
    }

    /// The text as an element without a ref: it can't be pressed, but its click point can be.
    public func node(index: Int) -> UINode {
        UINode(
            ref: "o\(index)", role: "AXStaticText", subrole: "AXOCRText", label: text,
            value: line == text ? nil : line, frame: Rect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height),
            hit: Point(x: frame.midX.rounded(), y: frame.midY.rounded())
        )
    }
}

/// The platform's `ScreenImaging`, set once by the helper at start.
public enum ScreenImagingProvider {
    private static let current = Mutex<(any ScreenImaging)?>(nil)

    /// Makes `imaging` the one device screenshots use.
    public static func use(_ imaging: any ScreenImaging) {
        current.withLock { $0 = imaging }
    }

    /// The platform's imaging, or an error saying this platform has none yet.
    package static func imaging() throws -> any ScreenImaging {
        guard let imaging = current.withLock({ $0 }) else {
            throw RPCError(code: RPCErrorCode.failed, message: "Screenshots and text recognition aren't available on this platform yet.")
        }
        return imaging
    }
}
