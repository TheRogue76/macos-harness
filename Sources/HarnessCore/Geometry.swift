#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

extension CGRect {
    /// Width times height; zero for the null rect.
    package var area: CGFloat { isNull ? 0 : width * height }

    /// The part of the rect inside `clip`, or nil when less than a point of it shows.
    package func visiblePart(in clip: CGRect) -> CGRect? {
        let part = intersection(clip)
        guard !part.isNull, part.width >= 1, part.height >= 1 else { return nil }
        return part
    }

    /// Whether the rect is finite and of plausible size.
    package var isSane: Bool {
        [origin.x, origin.y, size.width, size.height].allSatisfy { $0.isFinite && abs($0) < 1_000_000 }
    }
}
