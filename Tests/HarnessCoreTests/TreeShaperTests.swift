import CoreGraphics
import Foundation
import HarnessProtocol
import Testing
@testable import HarnessCore

private let window = CGRect(x: 100, y: 50, width: 400, height: 300)

private func node(
    _ role: String, _ label: String? = nil, subrole: String? = nil, value: String? = nil, id: String? = nil,
    actions: [String] = [], frame: CGRect? = nil, children: [RawNode] = []
) -> RawNode {
    RawNode(
        key: AnyHashable(UUID()), role: role, subrole: subrole, title: label, value: value, identifier: id,
        actions: actions, frame: frame, children: children
    )
}

private func shape(_ root: RawNode, maxNodes: Int = 100, maxDepth: Int = 40) -> TreeShaper.Result {
    var counter = 0
    return TreeShaper(window: window, maxNodes: maxNodes, maxDepth: maxDepth) { _ in
        counter += 1
        return "e\(counter)"
    }.shape(root)
}

private func roles(_ node: UINode) -> [String] {
    node.children.map(\.role)
}

struct TreeShaperTests {
    @Test func collapsesEmptyGroupsAndKeepsTheirChildren() {
        let root = node("AXWindow", "Doc", frame: window, children: [
            node("AXGroup", frame: window, children: [
                node("AXGroup", frame: window, children: [
                    node("AXButton", "OK", actions: ["AXPress"], frame: CGRect(x: 120, y: 70, width: 40, height: 20)),
                ]),
            ]),
        ])
        let result = shape(root)
        #expect(roles(result.root) == ["AXButton"])
        #expect(result.root.children[0].hit == Point(x: 40, y: 30))
    }

    @Test func keepsGroupsThatCarryMeaning() {
        let root = node("AXWindow", frame: window, children: [
            node("AXGroup", "Location List", frame: window),
            node("AXGroup", id: "TipView", frame: window),
            node("AXGroup", actions: ["Name:Delete\nTarget:0x0\nSelector:(null)"], frame: window),
        ])
        let children = shape(root).root.children
        #expect(children.count == 3)
        #expect(children[2].actions == ["Delete"])
    }

    @Test func dropsScrollBarsAndSplitters() {
        let root = node("AXWindow", frame: window, children: [
            node("AXScrollBar", frame: window, children: [node("AXValueIndicator", frame: window)]),
            node("AXSplitter", value: "-1", frame: window),
            node("AXButton", "Keep", frame: window),
        ])
        #expect(roles(shape(root).root) == ["AXButton"])
    }

    @Test func dropsMenuSeparatorsAndHiddenAlternates() {
        let row = { (y: CGFloat) in CGRect(x: 120, y: y, width: 200, height: 20) }
        let root = node("AXWindow", frame: window, children: [
            node("AXMenu", frame: CGRect(x: 120, y: 60, width: 200, height: 120), children: [
                node("AXMenuItem", "Paste Item", frame: row(60)),
                node("AXMenuItem", "Paste Item Exactly", frame: row(60)),
                node("AXMenuItem", frame: row(80)),
                node("AXMenuItem", "Get Info", frame: row(90)),
            ]),
        ])
        let menu = shape(root).root.children[0]
        #expect(menu.children.compactMap(\.label) == ["Paste Item", "Get Info"])
    }

    @Test func clipsToScrollAreasAndCountsWhatsHidden() {
        let scroll = CGRect(x: 100, y: 50, width: 400, height: 100)
        let root = node("AXWindow", frame: window, children: [
            node("AXScrollArea", frame: scroll, children: [
                node("AXButton", "Visible", frame: CGRect(x: 110, y: 60, width: 50, height: 20)),
                node("AXButton", "Below the fold", frame: CGRect(x: 110, y: 200, width: 50, height: 20)),
                node("AXButton", "Half shown", frame: CGRect(x: 110, y: 140, width: 50, height: 20)),
            ]),
        ])
        let result = shape(root)
        #expect(result.root.children.compactMap(\.label) == ["Visible", "Half shown"])
        #expect(result.offscreen == 1)
        #expect(result.root.children[1].frame == Rect(x: 10, y: 90, width: 50, height: 10))
    }

    @Test func namesWindowButtonsFromTheirSubrole() {
        let root = node("AXWindow", frame: window, children: [
            node("AXButton", "this button also has an action to zoom the window", subrole: "AXFullScreenButton",
                 frame: CGRect(x: 150, y: 60, width: 16, height: 16),
                 children: [node("AXGroup", "inner", frame: CGRect(x: 150, y: 60, width: 14, height: 14))]),
        ])
        let button = shape(root).root.children[0]
        #expect(button.label == "full screen")
        #expect(button.children.isEmpty)
    }

    @Test func hidesToolkitIdentifiers() {
        #expect(TreeShaper.meaningfulIdentifier("_NS:8") == nil)
        #expect(TreeShaper.meaningfulIdentifier("_TtGC7SwiftUI32NavigationStackHosting") == nil)
        #expect(TreeShaper.meaningfulIdentifier("SwiftUI.ModifiedContent<…>") == nil)
        #expect(TreeShaper.meaningfulIdentifier("increment-button") == "increment-button")
    }

    @Test func dropsBookkeepingActions() {
        let actions = TreeShaper.meaningfulActions([
            "AXPress", "AXCancel", "AXShowMenu", "AXScrollDownByPage",
            "Name:Trash\nTarget:0x0\nSelector:(null)", "Name:Trash\nTarget:0x1\nSelector:(null)",
        ])
        #expect(actions == ["AXPress", "Trash"])
    }

    @Test func respectsTheNodeLimit() {
        let buttons = (0..<10).map { node("AXButton", "B\($0)", frame: CGRect(x: 110, y: 60 + $0 * 25, width: 30, height: 20)) }
        let result = shape(node("AXWindow", frame: window, children: buttons), maxNodes: 4)
        #expect(result.root.children.count == 3)
        #expect(result.root.omitted == 7)
        #expect(result.omitted == 7)
    }

    @Test func dropsTextThatRepeatsItsParent() {
        let root = node("AXWindow", frame: window, children: [
            node("AXButton", "Save", frame: window, children: [node("AXStaticText", value: "Save", frame: window)]),
        ])
        #expect(shape(root).root.children[0].children.isEmpty)
    }

    @Test func staticTextShowsItsValue() {
        let root = node("AXWindow", frame: window, children: [node("AXStaticText", "Count: 3", frame: window)])
        let text = shape(root).root.children[0]
        #expect(text.label == nil)
        #expect(text.value == "Count: 3")
    }

    @Test func rejectsInsaneGeometry() {
        #expect(!CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10).isSane)
        #expect(!CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 10).isSane)
        #expect(!CGRect(x: 0, y: 0, width: 1e30, height: 10).isSane)
        #expect(CGRect(x: -1920, y: 0, width: 300, height: 200).isSane)
    }

    @Test func registryKeepsRefsStable() {
        let registry = ElementRegistry(tag: "k")
        let first = registry.ref(for: AnyHashable("a"), element: nil, pid: 1)
        let second = registry.ref(for: AnyHashable("b"), element: nil, pid: 1)
        #expect(first == "k1")
        #expect(registry.ref(for: AnyHashable("a"), element: nil, pid: 1) == first)
        #expect(first != second)
        #expect(registry.ref(for: AnyHashable("a"), element: nil, pid: 2) == "k3")
    }

    @Test func refsFromAnotherLaunchAreStale() {
        let registry = ElementRegistry(tag: "k")
        if case .stale = registry.lookup("m12", pid: 1) {} else { Issue.record("m12 should be stale") }
        if case .unknown = registry.lookup("k99", pid: 1) {} else { Issue.record("k99 should be unknown") }
        if case .unknown = registry.lookup("save", pid: 1) {} else { Issue.record("save should be unknown") }
    }

    @Test func launchTagsCycle() {
        let defaults = UserDefaults(suiteName: "launch-tag-test-\(UUID())")!
        let first = ElementRegistry.launchTag(defaults: defaults)
        let second = ElementRegistry.launchTag(defaults: defaults)
        #expect(first != second)
    }
}
