import Foundation
import HarnessCore
import Testing
@testable import HarnessLinux

struct LinuxMenusTests {
    private func key(_ path: String) -> AnyHashable { AnyHashable(ATSPIKey(bus: ":1.5", path: path)) }

    private func item(_ title: String, value: String? = nil, enabled: Bool = true, children: [RawNode] = []) -> RawNode {
        RawNode(key: key("/\(title)"), role: "AXMenuItem", title: title, value: value, enabled: enabled, actions: ["AXPress"], children: children)
    }

    private var menuButton: RawNode {
        RawNode(key: key("/more"), role: "AXButton", title: "More More", children: [
            RawNode(key: key("/toggle"), role: "AXCheckBox", subrole: "AXToggle", title: "More More", value: "1", actions: ["AXPress"], children: [
                RawNode(key: key("/label"), role: "AXStaticText", value: "More"),
            ]),
            RawNode(key: key("/popover"), role: "AXMenu", title: "More", children: [
                RawNode(key: key("/box"), role: "AXGroup", children: [item("Reset Count")]),
            ]),
        ])
    }

    private var window: RawNode {
        RawNode(key: key("/window"), role: "AXWindow", title: "Fixture", children: [
            RawNode(key: key("/bar"), role: "AXMenuBar", children: [
                RawNode(key: key("/file"), role: "AXMenu", title: "_File", children: [
                    item("New"),
                    item("Open Recent", children: [RawNode(key: key("/recent"), role: "AXMenu", children: [item("Report.txt")])]),
                    item("Wrap", value: "1"),
                    item("Paste", enabled: false),
                ]),
            ]),
            menuButton,
            RawNode(key: key("/plain"), role: "AXButton", title: "Increment", actions: ["AXPress"]),
        ])
    }

    @Test func findsMenuBarItemsThenMenuButtons() {
        let tops = LinuxDesktop.topMenus(in: window, items: [])
        #expect(tops.map(\.title) == ["_File", "More"])
        #expect(tops.map(\.isButton) == [false, true])
    }

    @Test func knowsAnOpenMenuButtonAndItsMenu() throws {
        #expect(LinuxDesktop.isOpen(menuButton))
        let menu = try #require(LinuxDesktop.buttonMenu(menuButton))
        #expect(LinuxDesktop.menuItems(of: menu).map(\.label) == ["Reset Count"])
        var closed = menuButton
        closed.children[0].value = "0"
        #expect(!LinuxDesktop.isOpen(closed))
    }

    @Test func describesMenuItems() throws {
        let file = try #require(LinuxDesktop.topMenus(in: window, items: []).first?.node)
        let items = LinuxDesktop.menuItems(of: try #require(LinuxDesktop.submenu(of: file)))
        let described = items.map { LinuxDesktop.menuItem($0, depth: 1) }
        #expect(described.map(\.title) == ["New", "Open Recent", "Wrap", "Paste"])
        #expect(described[1].hasSubmenu)
        #expect(described[1].children.map(\.title) == ["Report.txt"])
        #expect(described[2].mark == "✓")
        #expect(described[3].enabled == false)
    }

    @Test func matchesTitlesLoosely() {
        #expect(LinuxDesktop.titleMatches("_File", "file"))
        #expect(LinuxDesktop.titleMatches("Save As…", "Save As"))
        #expect(LinuxDesktop.titleMatches("Export...", "export…"))
        #expect(!LinuxDesktop.titleMatches("Save", "Save As"))
        #expect(!LinuxDesktop.titleMatches(nil, "Save"))
    }
}
