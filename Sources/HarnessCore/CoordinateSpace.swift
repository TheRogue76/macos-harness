#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import HarnessProtocol

/// How a target's coordinates map to the screen: the global rectangle they start from, and how
/// many target points one screen point is (1 for Mac windows, the zoom factor for a simulator).
public struct CoordinateSpace: Sendable, Equatable {
    public var frame: CGRect
    public var scale: CGFloat

    public init(frame: CGRect, scale: CGFloat = 1) {
        self.frame = frame
        self.scale = scale
    }

    /// The space's size in target points.
    public var size: CGSize { CGSize(width: frame.width * scale, height: frame.height * scale) }

    /// A global rectangle in target points.
    public func local(_ rect: CGRect) -> Rect {
        Rect(
            x: ((rect.minX - frame.minX) * scale).rounded(), y: ((rect.minY - frame.minY) * scale).rounded(),
            width: (rect.width * scale).rounded(), height: (rect.height * scale).rounded()
        )
    }

    /// A global point in target points.
    public func local(_ point: CGPoint) -> Point {
        Point(x: ((point.x - frame.minX) * scale).rounded(), y: ((point.y - frame.minY) * scale).rounded())
    }

    /// A point in target points as a global point.
    public func global(_ point: Point) -> CGPoint {
        CGPoint(x: frame.minX + point.x / scale, y: frame.minY + point.y / scale)
    }

    /// Whether a point in target points lies inside the space.
    public func contains(_ point: Point) -> Bool {
        point.x >= 0 && point.y >= 0 && point.x <= size.width.rounded() && point.y <= size.height.rounded()
    }
}
