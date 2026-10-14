import Foundation
import HarnessProtocol

/// Each session's last snapshot of each window, so the next one can report only what changed.
actor SnapshotMemory {
    static let shared = SnapshotMemory()

    private struct Entry {
        var limits: String
        var nodes: [(ref: String, node: UINode)]
        var date: Date
    }

    private var entries: [String: Entry] = [:]
    private let capacity = 200
    private let lifetime: TimeInterval = 3600

    /// Remembers `nodes` as the last snapshot of `window` for `owner`, and returns the previous
    /// one's nodes when it was read with the same `limits`, or why there's none to compare with.
    func replace(
        owner: String, window: String, limits: String, with nodes: [(ref: String, node: UINode)], now: Date = Date()
    ) -> (previous: [(ref: String, node: UINode)]?, reason: String?) {
        entries = entries.filter { now.timeIntervalSince($0.value.date) < lifetime }
        let key = owner + "|" + window
        let earlier = entries[key]
        entries[key] = Entry(limits: limits, nodes: nodes, date: now)
        if entries.count > capacity, let oldest = entries.min(by: { $0.value.date < $1.value.date })?.key {
            entries[oldest] = nil
        }
        guard let earlier else { return (nil, "There's no earlier snapshot of this window from this session, so this is the whole tree.") }
        guard earlier.limits == limits else {
            return (nil, "The last snapshot of this window used a different root or limits, so this is the whole tree.")
        }
        return (earlier.nodes, nil)
    }
}
