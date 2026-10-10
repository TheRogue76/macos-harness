import CoreGraphics
import Foundation

/// Where a window is on screen and which normal windows are in front of it, from the window
/// server's list.
public struct OnScreenWindow: Equatable, Sendable {
    /// The window's frame in global coordinates, origin at the top left of the main display.
    public var frame: CGRect
    /// Frames of the normal windows in front of it, other than the ignored process's.
    public var occluders: [CGRect]
    /// The normal window directly in front of it, whoever owns it.
    public var nearestAbove: UInt32?

    public init(frame: CGRect, occluders: [CGRect] = [], nearestAbove: UInt32? = nil) {
        self.frame = frame
        self.occluders = occluders
        self.nearestAbove = nearestAbove
    }

    /// The window's placement now, or nil when it isn't on the screen: minimized, hidden, closed
    /// or on another Space.
    public static func current(of id: UInt32, ignoring pid: pid_t) -> OnScreenWindow? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return placement(of: id, in: list, ignoring: pid)
    }

    /// The window's placement in a front-to-back window list, or nil when the list doesn't have it.
    public static func placement(of id: UInt32, in list: [[String: Any]], ignoring pid: pid_t) -> OnScreenWindow? {
        var occluders: [CGRect] = []
        var nearestAbove: UInt32?
        for entry in list {
            guard let number = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let bounds = (entry[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0 as CFDictionary) }) else {
                continue
            }
            if number == id {
                return OnScreenWindow(frame: bounds, occluders: occluders, nearestAbove: nearestAbove)
            }
            guard (entry[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0 == 0 else { continue }
            nearestAbove = number
            let owner = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
            let alpha = (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            if owner != pid, alpha > 0, bounds.width > 4, bounds.height > 4 {
                occluders.append(bounds)
            }
        }
        return nil
    }
}
