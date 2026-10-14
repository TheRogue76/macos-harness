import CoreGraphics
import Foundation

/// Where a real-input step has put the cursor, used to tell the user's mouse apart from the
/// step's own events and from the system putting the cursor back.
struct CursorTrail {
    /// Where the cursor is, compared with where the step put it.
    enum Place: Equatable {
        /// Where the step last put it.
        case placed
        /// At a point the step put it at moments before: the window server hasn't caught up.
        case behind
        /// Back where it rested before the step, or where the harness last warped it to.
        case resting
        /// Somewhere none of the above explains: the user moved the mouse.
        case moved
    }

    /// How far, in points, the cursor can be from a point and still count as there.
    static let tolerance: CGFloat = 3
    /// How long after the step put the cursor at a point that point still explains it.
    static let lag: TimeInterval = 0.25

    /// Where the cursor rested before the step, and where the harness last warped it to.
    let resting: [CGPoint]
    private var posted: [(point: CGPoint, time: Date)] = []

    init(resting: [CGPoint]) {
        self.resting = resting
    }

    /// Where the step last put the cursor; nil before its first event.
    var latest: CGPoint? { posted.last?.point }

    /// Records that the step put the cursor at `point`.
    mutating func post(_ point: CGPoint, at time: Date = Date()) {
        posted.removeAll { time.timeIntervalSince($0.time) > Self.lag }
        posted.append((point, time))
    }

    /// Where `cursor` is, read at `now`, compared with where the step put it.
    func place(of cursor: CGPoint, at now: Date = Date()) -> Place {
        if let latest, Self.near(cursor, latest) { return .placed }
        if posted.dropLast().contains(where: { now.timeIntervalSince($0.time) <= Self.lag && Self.near(cursor, $0.point) }) {
            return .behind
        }
        if resting.contains(where: { Self.near(cursor, $0) }) { return .resting }
        return .moved
    }

    private static func near(_ a: CGPoint, _ b: CGPoint) -> Bool {
        hypot(a.x - b.x, a.y - b.y) <= tolerance
    }
}
