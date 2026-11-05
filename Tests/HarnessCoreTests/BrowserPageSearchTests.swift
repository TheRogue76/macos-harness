#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import HarnessProtocol
import Testing
@testable import HarnessCore

struct BrowserPageSearchTests {
    private let clip = CGRect(x: 0, y: 0, width: 1200, height: 900)

    private func window(pageText: String?) -> RawNode {
        let address = RawNode(key: "address", role: "AXTextField", title: "Address and search bar", value: "dash.cloudflare.com/dns/dmarc", frame: CGRect(x: 200, y: 40, width: 600, height: 30))
        let toolbar = RawNode(key: "toolbar", role: "AXToolbar", frame: CGRect(x: 0, y: 30, width: 1200, height: 50), children: [address])
        let content = pageText.map { [RawNode(key: "heading", role: "AXStaticText", value: $0, frame: CGRect(x: 40, y: 200, width: 300, height: 30))] } ?? []
        let page = RawNode(key: "page", role: "AXWebArea", title: "DNS", frame: CGRect(x: 0, y: 90, width: 1200, height: 800), children: content)
        return RawNode(key: "window", role: "AXWindow", frame: clip, children: [toolbar, page])
    }

    @Test func thePageIsTheWebArea() {
        #expect(ElementSearch.page(in: window(pageText: nil))?.key == AnyHashable("page"))
        #expect(ElementSearch.page(in: RawNode(role: "AXWindow")) == nil)
    }

    @Test func matchesAreSplitIntoPageAndToolbar() {
        let root = window(pageText: "DMARC record")
        let hits = ElementSearch.search(root, for: ElementSelector(text: "dmarc"), clip: clip, limit: 10)
        let split = ElementSearch.split(hits, page: ElementSearch.page(in: root)!)
        #expect(split.page.map(\.raw.key) == [AnyHashable("heading")])
        #expect(split.toolbar.map(\.raw.key) == [AnyHashable("address")])
    }

    @Test func anAddressBarMatchAloneIsOnlyInTheToolbar() {
        let root = window(pageText: nil)
        let page = ElementSearch.page(in: root)!
        #expect(ElementSearch.search(page, for: ElementSelector(text: "dmarc"), clip: clip, limit: 1).isEmpty)
        let split = ElementSearch.split(ElementSearch.search(root, for: ElementSelector(text: "dmarc"), clip: clip, limit: 10), page: page)
        #expect(split.page.isEmpty && split.toolbar.count == 1)
    }
}
