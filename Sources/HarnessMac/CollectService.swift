import ApplicationServices
import CoreGraphics
import Foundation
import HarnessCore
import HarnessProtocol

/// `collect`: every item of a list that shows only part of itself at a time, scrolled through
/// without the real mouse, each item once.
public enum CollectService {
    /// Most items one call returns.
    static let ceiling = 500

    public static func collect(_ params: CollectMethod.Params, context: ActionContext = .unattended) async throws -> CollectMethod.Result {
        try check(params)
        if params.target.androidDevice != nil { return try await AndroidService.collect(params, context: context) }
        let (app, window) = try await TargetResolver.resolve(TargetResolver.target(params.target, holding: params.within))
        try OwnUI.refuse(app)
        try await context.claim(window, app: app)
        let treeNotice = try await Snapshotter.prepare(window, app: app)
        let container = try params.within.map { try Snapshotter.element(for: $0, app: app) } ?? window.content
        AX.setTimeout(container, seconds: window.isSimulator ? 8 : 2)
        let memory = CollectMemory.key(owner: context.owner, place: "\(app.pid)|\(window.info.id)", params: params)
        var collector = try await collector(params, memory: memory)
        collector.patience = window.isSimulator ? 6 : 2
        let outcome = try await collector.run(
            read: { AXReader(maxNodes: 8000, maxDepth: 80, timeBudget: 4, valueLimit: 20_000).read(container) },
            scroll: { last in
                window.isSimulator
                    ? await scrollSimulator(from: last, window: window)
                    : await scrollMac(from: last, container: container, window: window, app: app)
            },
            aborted: context.shouldAbort
        )
        await CollectMemory.shared.remember(memory, seen: collector.seen)
        let shaper = TreeShaper(space: window.space, maxNodes: 1, maxDepth: 0, ref: Snapshotter.registrar(for: app))
        let notices = await Notices.collect(for: window.info) + [treeNotice].compactMap { $0 }
        return result(outcome, app: app, window: window.info, ref: shaper.ref, notices: notices)
    }

    /// Refuses items named by a ref or OCR text, which can't repeat down a list.
    static func check(_ params: CollectMethod.Params) throws {
        guard !params.item.isEmpty, params.item.ref == nil, params.item.ocr != true else {
            throw RPCError(
                code: RPCErrorCode.invalidParams,
                message: "Say which elements are the items with a role (article, row, cell…), text or an identifier, not a ref."
            )
        }
    }

    /// The collector for a call, carrying on from what this session already got when asked.
    static func collector(_ params: CollectMethod.Params, memory: String) async throws -> Collector {
        let seen: Set<String> = params.continue == true ? await CollectMemory.shared.seen(memory) : []
        return Collector(
            selector: params.item, key: params.key, max: min(max(params.max, 1), ceiling), until: params.until,
            deadline: Date().addingTimeInterval(max(params.maxSeconds, 1)), seen: seen
        )
    }

    /// The result for what the collector found, with refs for the items and their links.
    static func result(
        _ outcome: (items: [Collector.Found], stop: Collector.Stop), app: AppRef, window: WindowInfo, ref: (RawNode) -> String,
        notices: [Notice]
    ) -> CollectMethod.Result {
        let items = outcome.items.map { found in
            CollectMethod.Item(
                ref: ref(found.raw), text: found.text,
                links: found.links.map { ReadMethod.Link(ref: ref($0.node), label: $0.label, url: $0.url) }
            )
        }
        return CollectMethod.Result(app: app, window: window, items: items, stopped: outcome.stop.rawValue, notices: notices)
    }

    /// Scrolls a Mac window's list on from its last item: brings the item into view through
    /// accessibility, or, when that moves nothing, a background wheel scroll of most of the list's
    /// height. False when neither could move it.
    static func scrollMac(from last: RawNode, container: AXUIElement, window: WindowService.Window, app: AppRef) async -> Bool {
        if let element = last.element, let before = AX.frame(element), AX.scrollIntoView(element) == .success {
            try? await Task.sleep(for: .milliseconds(500))
            guard let after = AX.frame(element) else { return true }
            if abs(after.minY - before.minY) > 1 { return true }
        }
        guard let area = AX.frame(container)?.intersection(window.space.frame), !area.isNull, area.height > 40 else { return false }
        let center = CGPoint(x: area.midX, y: area.midY)
        guard BackgroundInput.routes(at: center, in: window) else { return false }
        let origin = CGPoint(x: window.space.frame.minX, y: window.space.frame.minY)
        guard await BackgroundClick.scroll(pid: app.pid, window: window.info.id, at: center, windowOrigin: origin, dx: 0, dy: -area.height * 0.8) else {
            return false
        }
        try? await Task.sleep(for: .milliseconds(500))
        return true
    }

    /// Pages a simulator's list down from its last item.
    static func scrollSimulator(from last: RawNode, window: WindowService.Window) async -> Bool {
        let moved = await SimulatorInput.scrollPages(from: last.element, direction: .down, pages: 1, window: window)
        try? await Task.sleep(for: .milliseconds(600))
        return moved > 0
    }
}

/// The loop behind `collect`: read the list, take the items not seen before, scroll on from the
/// last one, until a limit, the end of the list or the time runs out.
struct Collector {
    /// Why collecting stopped.
    enum Stop: String {
        case max, until, end, time, stuck
    }

    /// One item taken from the list.
    struct Found {
        var raw: RawNode
        var text: String
        var links: [(node: RawNode, label: String?, url: String)]
    }

    var selector: ElementSelector
    var key: String?
    var max: Int
    var until: String?
    var deadline: Date
    /// Identities of the items taken so far, earlier calls' included when continuing.
    var seen: Set<String>
    /// Scrolls in a row that bring nothing new before the list counts as ended.
    var idleLimit = 3
    /// How long the first read keeps trying when it finds no items, for a list still settling
    /// after a scroll (an Android dump taken mid-scroll can leave the list out).
    var patience: TimeInterval = 2

    /// The items inside `root` in reading order, without looking inside an item for more.
    static func items(in root: RawNode, matching selector: ElementSelector) -> [RawNode] {
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
    static func describe(_ raw: RawNode) -> Found {
        var links = ReadText.links(in: raw)
        if raw.role == "AXLink", let url = raw.url {
            let text = ReadText.text(of: raw)
            links.insert((raw, raw.label ?? (text.isEmpty ? nil : text), url), at: 0)
        }
        return Found(raw: raw, text: ReadText.text(of: raw), links: links)
    }

    /// What tells an item apart: the URL of its first link containing `key`, or else its text.
    func identity(of found: Found) -> String {
        if let key, let link = found.links.first(where: { $0.url.contains(key) }) { return "url " + link.url }
        return "text " + found.text
    }

    /// Reads, takes the new items and scrolls until a stop. `pause` waits after a scroll that
    /// brought nothing new, for lists that load more over the network.
    mutating func run(
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
actor CollectMemory {
    static let shared = CollectMemory()

    private var entries: [String: (seen: Set<String>, date: Date)] = [:]
    private let capacity = 50
    private let lifetime: TimeInterval = 3600

    /// The memory key for a session's collection from one list with one item selector.
    static func key(owner: String, place: String, params: CollectMethod.Params) -> String {
        let item = params.item
        return [owner, place, params.within ?? "", item.role ?? "", item.text ?? "", item.identifier ?? "", item.exact ? "exact" : "", params.key ?? ""]
            .joined(separator: "|")
    }

    func seen(_ key: String, now: Date = Date()) -> Set<String> {
        guard let entry = entries[key], now.timeIntervalSince(entry.date) < lifetime else { return [] }
        return entry.seen
    }

    func remember(_ key: String, seen: Set<String>, now: Date = Date()) {
        entries = entries.filter { now.timeIntervalSince($0.value.date) < lifetime }
        entries[key] = (seen, now)
        if entries.count > capacity, let oldest = entries.min(by: { $0.value.date < $1.value.date })?.key {
            entries[oldest] = nil
        }
    }
}
