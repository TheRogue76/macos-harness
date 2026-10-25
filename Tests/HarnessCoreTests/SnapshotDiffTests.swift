import Foundation
import HarnessClient
import HarnessProtocol
import Testing
@testable import HarnessCore

struct SnapshotDiffTests {
    private let app = AppRef(name: "Fixture", bundleIdentifier: nil, pid: 9)

    private var window: WindowInfo {
        WindowInfo(
            id: 3, app: app, title: "Fixture", frame: Rect(x: 0, y: 0, width: 400, height: 300), onScreen: true,
            minimized: false, focused: true, main: true, subrole: nil, hasSheet: false
        )
    }

    private func tree(count: String, greeting: String, extra: Bool = false) -> UINode {
        var children = [
            UINode(ref: "k2", role: "AXStaticText", value: count, identifier: "count-value"),
            UINode(ref: "k3", role: "AXButton", label: "Increment", identifier: "increment-button"),
            UINode(ref: "k4", role: "AXGroup", label: "Greeting", children: [UINode(ref: "k5", role: "AXStaticText", value: greeting)]),
        ]
        if extra { children.append(UINode(ref: "k6", role: "AXSheet", label: "A sheet")) }
        return UINode(ref: "k1", role: "AXWindow", label: "Fixture", children: children)
    }

    private func result(_ root: UINode) -> SnapshotMethod.Result {
        SnapshotMethod.Result(window: window, root: root, notices: [], shownCount: SnapshotNarrowing.count(root), readCount: 10, milliseconds: 5)
    }

    @Test func memoryComparesOnlyLikeWithLike() async {
        let memory = SnapshotMemory()
        let nodes = SnapshotNarrowing.flatten(tree(count: "0", greeting: "Hi"))
        let start = Date()
        let first = await memory.replace(owner: "a", window: "w", limits: "|250|40", with: nodes, now: start)
        #expect(first.previous == nil)
        #expect(first.reason?.contains("no earlier snapshot") == true)
        let second = await memory.replace(owner: "a", window: "w", limits: "|250|40", with: nodes, now: start.addingTimeInterval(1))
        #expect(second.previous?.count == nodes.count)
        let otherLimits = await memory.replace(owner: "a", window: "w", limits: "|50|40", with: nodes, now: start.addingTimeInterval(2))
        #expect(otherLimits.previous == nil)
        #expect(otherLimits.reason?.contains("different root or limits") == true)
        let otherSession = await memory.replace(owner: "b", window: "w", limits: "|50|40", with: nodes, now: start.addingTimeInterval(3))
        #expect(otherSession.previous == nil)
        let expired = await memory.replace(owner: "a", window: "w", limits: "|50|40", with: nodes, now: start.addingTimeInterval(7200))
        #expect(expired.previous == nil)
    }

    @Test func sinceReportsOnlyWhatChanged() {
        let before = SnapshotNarrowing.flatten(tree(count: "0", greeting: "Hi"))
        let narrowed = SnapshotNarrowing.narrow(
            result(tree(count: "2", greeting: "Hi", extra: true)), since: true, previous: (before, nil), query: nil
        )
        let changes = narrowed.changes ?? []
        #expect(changes.map(\.kind) == ["changed", "added"])
        #expect(changes.first?.before?.value == "0")
        #expect(changes.first?.node.value == "2")
        #expect(narrowed.root.children.isEmpty)
        #expect(Render.snapshot(narrowed).contains("Changes since your last snapshot of this window:"))

        let unchanged = SnapshotNarrowing.narrow(result(tree(count: "0", greeting: "Hi")), since: true, previous: (before, nil), query: nil)
        #expect(unchanged.changes == [])
        #expect(Render.snapshot(unchanged).contains("No changes since your last snapshot"))
    }

    @Test func sinceWithoutAnEarlierSnapshotGivesTheWholeTree() {
        let narrowed = SnapshotNarrowing.narrow(
            result(tree(count: "0", greeting: "Hi")), since: true, previous: (nil, "There's no earlier snapshot."), query: nil
        )
        #expect(narrowed.changes == nil)
        #expect(narrowed.root.children.count == 3)
        #expect(narrowed.notices.map(\.kind) == ["fullSnapshot"])
    }

    @Test func queryKeepsMatchesAndTheirAncestors() {
        let narrowed = SnapshotNarrowing.narrow(result(tree(count: "0", greeting: "Hello, Ada")), since: false, previous: (nil, nil), query: "ada")
        #expect(narrowed.root.children.map(\.ref) == ["k4"])
        #expect(narrowed.root.children.first?.children.map(\.ref) == ["k5"])
        #expect(narrowed.shownCount == 3)
        #expect(narrowed.notices.map(\.kind) == ["query"])

        let nothing = SnapshotNarrowing.narrow(result(tree(count: "0", greeting: "Hi")), since: false, previous: (nil, nil), query: "zebra")
        #expect(nothing.root.children.isEmpty)
        #expect(nothing.notices.first?.message.contains("Nothing in the tree matches") == true)
    }

    @Test func sinceAndQueryTogetherFilterTheChanges() {
        let before = SnapshotNarrowing.flatten(tree(count: "0", greeting: "Hi"))
        let narrowed = SnapshotNarrowing.narrow(
            result(tree(count: "2", greeting: "Hello", extra: true)), since: true, previous: (before, nil), query: "hello"
        )
        #expect(narrowed.changes?.map(\.node.ref) == ["k5"])
    }
}
