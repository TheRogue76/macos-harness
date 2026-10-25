import CoreGraphics
import Foundation
@testable import HarnessClient
import HarnessProtocol
import Testing
@testable import HarnessCore
@testable import HarnessMac

struct ReadTextTests {
    private func text(_ value: String) -> RawNode { RawNode(role: "AXStaticText", value: value) }

    private func link(_ title: String?, _ url: String, inner: String? = nil) -> RawNode {
        RawNode(role: "AXLink", title: title, url: url, children: [text(inner ?? title ?? "")])
    }

    private var post: RawNode {
        RawNode(role: "AXGroup", subrole: "AXDocumentArticle", title: "Post by User 0", children: [
            link("User 0", "https://example.com/user0"),
            text("·"),
            link("21 hours ago", "https://example.com/status/100000"),
            RawNode(role: "AXGroup", children: [text("Post 3 says:"), link(nil, "https://example.com/tag", inner: "#alpha"), text("!")]),
            text("9 likes"),
            RawNode(role: "AXButton", title: "Like"),
        ])
    }

    @Test func inlineTextRunsOnAndBlocksStartNewLines() {
        #expect(ReadText.text(of: post) == "User 0 · 21 hours ago\nPost 3 says: #alpha!\n9 likes\nLike")
    }

    @Test func aContainersLabelCountsOnlyWhenNothingInsideHasText() {
        #expect(!ReadText.text(of: post).contains("Post by"))
        let button = RawNode(role: "AXButton", title: "Reply", children: [RawNode(role: "AXImage")])
        #expect(ReadText.text(of: RawNode(role: "AXGroup", children: [button])) == "Reply")
    }

    @Test func inputsReadWhatWasTypedAndWindowButtonsAreLeftOut() {
        let typed = RawNode(role: "AXTextField", title: "Name", placeholder: "Your name", value: "Ada")
        let empty = RawNode(role: "AXTextField", title: "Email", placeholder: "you@example.com", value: "you@example.com")
        let close = RawNode(role: "AXButton", subrole: "AXCloseButton")
        #expect(ReadText.text(of: RawNode(role: "AXWindow", children: [close, typed, empty])) == "Ada")
    }

    @Test func linksAreListedOnceWithTheirTextAsLabel() {
        var root = post
        root.children.append(link("User 0", "https://example.com/user0"))
        let links = ReadText.links(in: root).map { [$0.label ?? "-", $0.url] }
        #expect(links == [
            ["User 0", "https://example.com/user0"],
            ["21 hours ago", "https://example.com/status/100000"],
            ["#alpha", "https://example.com/tag"],
        ])
        #expect(ReadText.links(in: link("Only", "https://example.com")).isEmpty)
    }

    @Test func unreadElementsAreCounted() {
        let root = RawNode(role: "AXGroup", children: [RawNode(role: "AXGroup", unread: 2)], unread: 1)
        #expect(ReadText.unread(in: root) == 3)
    }

    @Test func textThatRepeatsTheElementsOwnValueIsLeftOut() {
        let app = AppRef(name: "Notes", bundleIdentifier: nil, pid: 1)
        let window = WindowInfo(
            id: 7, app: app, title: "Note", frame: Rect(x: 0, y: 0, width: 400, height: 300), onScreen: true,
            minimized: false, focused: true, main: true, subrole: nil, hasSheet: false
        )
        let raw = text("A long note")
        let node = UINode(ref: "e1", role: "AXStaticText", value: "A long note")
        let result = ReadService.result(raw, node: node, app: app, window: window, ref: { _ in "e2" }, notices: [])
        #expect(result.text == nil)
        let long = ReadService.result(text(String(repeating: "a", count: 100_001)), node: node, app: app, window: window, ref: { _ in "e2" }, notices: [])
        #expect(long.text?.count == 100_001)
        #expect(long.notices.map(\.kind) == ["truncated"])
    }
}

struct LinkTargetTests {
    private let shaperFrame = CGRect(x: 0, y: 0, width: 800, height: 600)

    @Test func linksSayWhereTheyGoOnlyWhenAskedButPagesAlways() {
        let link = RawNode(role: "AXLink", title: "Docs", url: "https://example.com/docs")
        let page = RawNode(role: "AXWebArea", title: "Example", url: "https://example.com/")
        var shaper = TreeShaper(window: shaperFrame, maxNodes: 1, maxDepth: 0) { _ in "e1" }
        #expect(shaper.makeNode(link, visible: nil).url == nil)
        #expect(shaper.makeNode(page, visible: nil).url == "https://example.com/")
        shaper.links = true
        #expect(shaper.makeNode(link, visible: nil).url == "https://example.com/docs")
    }

    @Test func articlesShowAndCanBeNamed() {
        let article = RawNode(role: "AXGroup", subrole: "AXDocumentArticle", children: [RawNode(role: "AXStaticText", value: "Post")])
        let shaper = TreeShaper(window: shaperFrame, maxNodes: 10, maxDepth: 10) { _ in "e1" }
        #expect(!shaper.shouldCollapse(article))
        #expect(shaper.shouldCollapse(RawNode(role: "AXGroup")))
        #expect(ElementSearch.roleMatches("article", article))
        #expect(!ElementSearch.roleMatches("article", RawNode(role: "AXGroup")))
        #expect(Render.node(UINode(ref: "e1", role: "AXGroup", subrole: "AXDocumentArticle")) == "e1 article")
    }

    @Test func urlsComeFromURLsOrStrings() {
        #expect(AXReader.urlText(URL(string: "https://example.com/a") as AnyObject?) == "https://example.com/a")
        #expect(AXReader.urlText("" as AnyObject) == nil)
        #expect(AXReader.valueText(String(repeating: "x", count: 500) as AnyObject)?.count == 301)
        #expect(AXReader.valueText(String(repeating: "x", count: 500) as AnyObject, limit: 1000)?.count == 500)
    }

    @Test func linesShortenLongURLs() {
        let url = "https://example.com/" + String(repeating: "p", count: 200)
        let line = Render.node(UINode(ref: "e3", role: "AXLink", label: "More", url: url))
        #expect(line == "e3 link \"More\" url=\(url.prefix(100))…")
        #expect(Render.node(UINode(ref: "e4", role: "AXWebArea", label: "Example", url: "https://example.com/")) == "e4 webArea \"Example\" url=https://example.com/")
    }

    @Test func readShowsWhatTheLineShortenedThenTextAndLinks() {
        let app = AppRef(name: "Google Chrome", bundleIdentifier: "com.google.Chrome", pid: 30)
        let window = WindowInfo(
            id: 4163, app: app, title: "timeline", frame: Rect(x: 0, y: 0, width: 1200, height: 900), onScreen: true,
            minimized: false, focused: true, main: true, subrole: nil, hasSheet: false
        )
        let label = "Post by User 0: " + String(repeating: "alpha ", count: 20)
        let result = ReadMethod.Result(
            app: app, window: window, element: UINode(ref: "s1", role: "AXGroup", label: label),
            text: "User 0 · 21 hours ago\nPost 3 says: alpha",
            links: [ReadMethod.Link(ref: "s2", label: "21 hours ago", url: "https://example.com/status/100000")], notices: []
        )
        let lines = Render.read(result).split(separator: "\n").map(String.init)
        #expect(lines.dropFirst().elementsEqual([
            Render.node(result.element),
            "Label: " + label,
            "Text:",
            "User 0 · 21 hours ago",
            "Post 3 says: alpha",
            "Links:",
            #"  s2 "21 hours ago" → https://example.com/status/100000"#,
        ]))
    }
}
