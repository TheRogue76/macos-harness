import Foundation
@testable import HarnessClient
import HarnessProtocol
import Testing
@testable import HarnessCore
@testable import HarnessMac

/// A timeline that shows ten posts at a time and moves four further on each scroll.
private final class FakeTimeline {
    let total: Int
    var position = 0
    var scrolls = 0
    var reads = 0
    var likesGrow = false

    init(total: Int) {
        self.total = total
    }

    func post(_ index: Int) -> RawNode {
        let likes = likesGrow ? index + reads : index
        return RawNode(role: "AXGroup", subrole: "AXDocumentArticle", children: [
            RawNode(role: "AXLink", title: "User \(index % 3)", url: "https://example.com/user\(index % 3)"),
            RawNode(role: "AXLink", title: "\(index) h", url: "https://example.com/status/\(1000 + index)"),
            RawNode(role: "AXGroup", children: [RawNode(role: "AXStaticText", value: "Post \(index) says hello")]),
            RawNode(role: "AXStaticText", value: "\(likes) likes"),
        ])
    }

    func read() -> RawNode {
        reads += 1
        let shown = position..<min(total, position + 10)
        return RawNode(role: "AXWebArea", title: "Timeline", children: shown.map(post))
    }

    func scroll() -> Bool {
        scrolls += 1
        position = min(max(total - 10, 0), position + 4)
        return true
    }
}

struct CollectorTests {
    private let articles = ElementSelector(role: "article")

    private func collector(max: Int = 500, key: String? = nil, until: String? = nil, seen: Set<String> = []) -> Collector {
        Collector(selector: articles, key: key, max: max, until: until, deadline: .distantFuture, seen: seen)
    }

    private func run(_ collector: inout Collector, _ list: FakeTimeline) async throws -> (items: [Collector.Found], stop: Collector.Stop) {
        try await collector.run(read: { list.read() }, scroll: { _ in list.scroll() }, pause: { _ in })
    }

    private func numbers(_ items: [Collector.Found]) -> [Int] {
        items.compactMap { found in found.text.split(separator: "\n").first { $0.hasPrefix("Post ") }.flatMap { Int($0.split(separator: " ")[1]) } }
    }

    @Test func takesEveryItemOnceInOrderUntilNothingNewComes() async throws {
        let list = FakeTimeline(total: 40)
        var collector = collector()
        let outcome = try await run(&collector, list)
        #expect(numbers(outcome.items) == Array(0..<40))
        #expect(outcome.stop == .end)
        #expect(outcome.items[3].text == "User 0 3 h\nPost 3 says hello\n3 likes")
        #expect(outcome.items[3].links.map(\.url) == ["https://example.com/user0", "https://example.com/status/1003"])
    }

    @Test func stopsAtTheLimitAndCarriesOnWithoutRepeats() async throws {
        let list = FakeTimeline(total: 40)
        var first = collector(max: 15)
        let opening = try await run(&first, list)
        #expect(numbers(opening.items) == Array(0..<15))
        #expect(opening.stop == .max)
        var second = collector(max: 15, seen: first.seen)
        #expect(numbers(try await run(&second, list).items) == Array(15..<30))
    }

    @Test func stopsAfterTheItemWithTheUntilText() async throws {
        var collector = collector(until: "post 22 says")
        let outcome = try await run(&collector, FakeTimeline(total: 40))
        #expect(numbers(outcome.items).last == 22)
        #expect(outcome.stop == .until)
    }

    @Test func aKeyLinkKeepsChangingItemsFromRepeating() async throws {
        let list = FakeTimeline(total: 20)
        list.likesGrow = true
        var byText = collector()
        #expect(try await run(&byText, list).items.count > 20)
        list.position = 0
        var byLink = collector(key: "/status/")
        #expect(numbers(try await run(&byLink, list).items) == Array(0..<20))
    }

    @Test func stopsWhenItCantScrollOrTimeRunsOut() async throws {
        let list = FakeTimeline(total: 40)
        var stuck = collector()
        let blocked = try await stuck.run(read: { list.read() }, scroll: { _ in false }, pause: { _ in })
        #expect(blocked.stop == .stuck)
        #expect(blocked.items.count == 10)
        var late = Collector(selector: articles, key: nil, max: 500, until: nil, deadline: .distantPast, seen: [])
        let timedOut = try await run(&late, FakeTimeline(total: 40))
        #expect(timedOut.stop == .time)
        #expect(timedOut.items.count == 10)
    }

    @Test func aStopOrNoItemsIsAnError() async throws {
        var stopped = collector()
        await #expect(throws: RPCError.self) {
            _ = try await stopped.run(read: { FakeTimeline(total: 5).read() }, scroll: { _ in true }, aborted: { true }, pause: { _ in })
        }
        #expect(stopped.seen.isEmpty)
        var nothing = Collector(selector: ElementSelector(role: "row"), key: nil, max: 5, until: nil, deadline: .distantFuture, seen: [])
        nothing.patience = 0
        do {
            _ = try await run(&nothing, FakeTimeline(total: 5))
            Issue.record("expected notFound")
        } catch let error as RPCError {
            #expect(error.code == RPCErrorCode.notFound)
        }
    }

    @Test func aFirstReadWithoutItemsIsTriedAgain() async throws {
        let list = FakeTimeline(total: 12)
        var reads = 0
        var collector = collector()
        let outcome = try await collector.run(
            read: {
                reads += 1
                return reads == 1 ? RawNode(role: "AXWebArea") : list.read()
            },
            scroll: { _ in list.scroll() }, pause: { _ in }
        )
        #expect(outcome.items.count == 12)
    }

    @Test func itemsInsideItemsArentTakenTwice() {
        let quoted = RawNode(role: "AXGroup", subrole: "AXDocumentArticle", children: [RawNode(role: "AXStaticText", value: "Quoted")])
        let post = RawNode(role: "AXGroup", subrole: "AXDocumentArticle", children: [RawNode(role: "AXStaticText", value: "Post"), quoted])
        let items = Collector.items(in: RawNode(role: "AXWebArea", children: [post]), matching: articles)
        #expect(items.count == 1)
        #expect(Collector.describe(items[0]).text == "Post\nQuoted")
    }

    @Test func aLinkItemsOwnTargetComesFirst() {
        let link = RawNode(role: "AXLink", title: "Docs", url: "https://example.com/docs")
        #expect(Collector.describe(link).links.map(\.url) == ["https://example.com/docs"])
    }
}

struct CollectMemoryTests {
    @Test func remembersWhatASessionCollectedForAnHour() async {
        let memory = CollectMemory()
        let start = Date()
        await memory.remember("a", seen: ["text x"], now: start)
        #expect(await memory.seen("a", now: start.addingTimeInterval(60)) == ["text x"])
        #expect(await memory.seen("a", now: start.addingTimeInterval(3601)).isEmpty)
        #expect(await memory.seen("b", now: start).isEmpty)
    }

    @Test func keysTellSessionsListsAndItemsApart() {
        let params = CollectMethod.Params(target: Target(app: "Chrome"), item: ElementSelector(role: "article"), key: "/status/")
        let one = CollectMemory.key(owner: "s1", place: "1|2", params: params)
        #expect(one != CollectMemory.key(owner: "s2", place: "1|2", params: params))
        #expect(one != CollectMemory.key(owner: "s1", place: "1|3", params: params))
        var rows = params
        rows.item = ElementSelector(role: "row")
        #expect(one != CollectMemory.key(owner: "s1", place: "1|2", params: rows))
    }

    @Test func itemsAreNamedByWhatTheyAreNotARef() {
        #expect(throws: RPCError.self) { try CollectService.check(.init(target: Target(app: "Chrome"), item: ElementSelector(ref: "e1"))) }
        #expect(throws: RPCError.self) { try CollectService.check(.init(target: Target(app: "Chrome"), item: ElementSelector())) }
        #expect(throws: Never.self) { try CollectService.check(.init(target: Target(app: "Chrome"), item: ElementSelector(role: "row"))) }
    }
}

struct CollectRenderTests {
    @Test func listsEachItemWithItsTextAndLinks() {
        let app = AppRef(name: "Google Chrome", bundleIdentifier: "com.google.Chrome", pid: 30)
        let window = WindowInfo(
            id: 4163, app: app, title: "timeline", frame: Rect(x: 0, y: 0, width: 1200, height: 900), onScreen: true,
            minimized: false, focused: true, main: true, subrole: nil, hasSheet: false
        )
        let result = CollectMethod.Result(
            app: app, window: window,
            items: [CollectMethod.Item(ref: "c1", text: "User 0\nPost 0", links: [ReadMethod.Link(ref: "c2", label: "0 h", url: "https://example.com/status/1")])],
            stopped: "max", notices: []
        )
        let lines = Render.collect(result).split(separator: "\n").map(String.init)
        #expect(lines.dropFirst().elementsEqual([
            "Collected 1 item; stopped: reached the most items asked for; call again with --continue (continue=true) for the next ones.",
            "1. c1",
            "   User 0",
            "   Post 0",
            #"   c2 "0 h" → https://example.com/status/1"#,
        ]))
    }
}
