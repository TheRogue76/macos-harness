#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import HarnessProtocol

/// The loop behind `collect`: read the list, take the items not seen before, scroll on from the
/// last one, until a limit, the end of the list or the time runs out.
package struct Collector {
    /// Why collecting stopped.
    package enum Stop: String {
        case max, until, end, time, stuck
    }

    /// One item taken from the list.
    package struct Found {
        package var raw: RawNode
        package var text: String
        package var links: [(node: RawNode, label: String?, url: String)]
    }

    package var selector: ElementSelector
    package var key: String?
    package var max: Int
    package var until: String?
    package var deadline: Date
    /// Identities of the items taken so far, earlier calls' included when continuing.
    package var seen: Set<String>
    /// Scrolls in a row that bring nothing new before the list counts as ended.
    package var idleLimit = 3
    /// How long the first read keeps trying when it finds no items, for a list still settling
    /// after a scroll (an Android dump taken mid-scroll can leave the list out).
    package var patience: TimeInterval = 2

    /// The items inside `root` in reading order, without looking inside an item for more.
    package static func items(in root: RawNode, matching selector: ElementSelector) -> [RawNode] {
        var found: [RawNode] = []
        func visit(_ node: RawNode) {
            if ElementSearch.matches(node, selector) {
                found.append(node)
                return
            }
            node.children.forEach(visit)
        }
        visit(root)
        return found
    }

    /// An item's text and links; a link item's own target comes first.
    package static func describe(_ raw: RawNode) -> Found {
        var links = ReadText.links(in: raw)
        if raw.role == "AXLink", let url = raw.url {
            let text = ReadText.text(of: raw)
            links.insert((raw, raw.label ?? (text.isEmpty ? nil : text), url), at: 0)
        }
        return Found(raw: raw, text: ReadText.text(of: raw), links: links)
    }

    /// What tells an item apart: the URL of its first link containing `key`, or else its text.
    package func identity(of found: Found) -> String {
        if let key, let link = found.links.first(where: { $0.url.contains(key) }) { return "url " + link.url }
        return "text " + found.text
    }

    /// Reads, takes the new items and scrolls until a stop. `pause` waits after a scroll that
    /// brought nothing new, for lists that load more over the network.
    package mutating func run(
        read: () async throws -> RawNode,
        scroll: (RawNode) async throws -> Bool,
        aborted: () async -> Bool = { false },
        pause: (Int) async -> Void = { idle in try? await Task.sleep(for: .milliseconds(400 * idle)) },
        now: () -> Date = Date.init
    ) async throws -> (items: [Found], stop: Stop) {
        var taken: [Found] = []
        var idle = 0
        var first = true
        while true {
            if await aborted() {
                throw RPCError(code: RPCErrorCode.stoppedByUser, message: "The user stopped this agent partway through collecting.")
            }
            var items = Self.items(in: try await read(), matching: selector)
            if first {
                let giveUp = now().addingTimeInterval(patience)
                while items.isEmpty, now() < giveUp {
                    await pause(1)
                    items = Self.items(in: try await read(), matching: selector)
                }
                guard !items.isEmpty else {
                    throw RPCError(code: RPCErrorCode.notFound, message: "Nothing in the list matches the items' role, text or identifier. Try `find` or `snapshot` to see what's there.")
                }
            }
            first = false
            var fresh = 0
            for item in items {
                let found = Self.describe(item)
                guard !found.text.isEmpty || !found.links.isEmpty, seen.insert(identity(of: found)).inserted else { continue }
                taken.append(found)
                fresh += 1
                if let until, found.text.localizedCaseInsensitiveContains(until) { return (taken, .until) }
                if taken.count >= max { return (taken, .max) }
            }
            idle = fresh == 0 ? idle + 1 : 0
            if idle >= idleLimit { return (taken, .end) }
            if now() >= deadline { return (taken, .time) }
            guard let last = items.last, try await scroll(last) else { return (taken, .stuck) }
            if idle > 0 { await pause(idle) }
        }
    }
}

/// What each session has collected from each list, so `continue` leaves it out.
package actor CollectMemory {
    package static let shared = CollectMemory()

    private var entries: [String: (seen: Set<String>, date: Date)] = [:]
    private let capacity = 50
    private let lifetime: TimeInterval = 3600

    /// The memory key for a session's collection from one list with one item selector.
    package static func key(owner: String, place: String, params: CollectMethod.Params) -> String {
        let item = params.item
        return [owner, place, params.within ?? "", item.role ?? "", item.text ?? "", item.identifier ?? "", item.exact ? "exact" : "", params.key ?? ""]
            .joined(separator: "|")
    }

    package func seen(_ key: String, now: Date = Date()) -> Set<String> {
        guard let entry = entries[key], now.timeIntervalSince(entry.date) < lifetime else { return [] }
        return entry.seen
    }

    package func remember(_ key: String, seen: Set<String>, now: Date = Date()) {
        entries = entries.filter { now.timeIntervalSince($0.value.date) < lifetime }
        entries[key] = (seen, now)
        if entries.count > capacity, let oldest = entries.min(by: { $0.value.date < $1.value.date })?.key {
            entries[oldest] = nil
        }
    }
}
