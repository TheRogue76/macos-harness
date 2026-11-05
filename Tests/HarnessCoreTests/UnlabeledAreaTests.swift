import Foundation
import HarnessProtocol
import Testing
@testable import HarnessCore

struct UnlabeledAreaTests {
    private let back = UINode(ref: "b1", role: "AXButton", label: "Back", actions: ["AXPress"], frame: Rect(x: 10, y: 10, width: 30, height: 30), hit: Point(x: 25, y: 25))
    private let send = UINode(ref: "b2", role: "AXButton", label: "Send", actions: ["AXPress"], frame: Rect(x: 300, y: 500, width: 60, height: 30), hit: Point(x: 330, y: 515))

    @Test func aPageWithNothingLabeledInItIsFound() {
        let page = UINode(ref: "w1", role: "AXWebArea", frame: Rect(x: 0, y: 60, width: 800, height: 540))
        let root = UINode(ref: "r", role: "AXWindow", frame: Rect(x: 0, y: 0, width: 800, height: 600), children: [back, page])
        #expect(TreeShaper.unlabeledArea(root, targets: [back], width: 800, height: 600)?.ref == "w1")
    }

    @Test func aLargeAreaWithLabelsInsideIsFine() {
        let content = UINode(ref: "g1", role: "AXGroup", frame: Rect(x: 0, y: 60, width: 800, height: 540), children: [send])
        let root = UINode(ref: "r", role: "AXWindow", frame: Rect(x: 0, y: 0, width: 800, height: 600), children: [back, content])
        #expect(TreeShaper.unlabeledArea(root, targets: [back, send], width: 800, height: 600) == nil)
    }

    @Test func smallUnlabeledAreasAndTheWindowItselfDontCount() {
        let picture = UINode(ref: "i1", role: "AXImage", frame: Rect(x: 400, y: 100, width: 200, height: 200))
        let root = UINode(ref: "r", role: "AXWindow", frame: Rect(x: 0, y: 0, width: 800, height: 600), children: [back, picture])
        #expect(TreeShaper.unlabeledArea(root, targets: [back], width: 800, height: 600) == nil)
    }
}
