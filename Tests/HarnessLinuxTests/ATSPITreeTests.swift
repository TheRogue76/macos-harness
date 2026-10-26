import Foundation
import HarnessCore
import HarnessDBus
import Testing
@testable import HarnessLinux

struct ATSPITreeTests {
    private func states(_ states: ATSPIState...) -> ATSPIStates {
        ATSPIStates(bits: states.reduce(0) { $0 | 1 << $1.rawValue })
    }

    private func item(
        _ path: String, parent: String, index: Int, role: UInt32, name: String = "", childCount: Int = 0,
        states: ATSPIStates = ATSPIStates(bits: 1 << ATSPIState.showing.rawValue | 1 << ATSPIState.sensitive.rawValue)
    ) -> ATSPIItem {
        ATSPIItem(
            path: path, parent: parent, index: index, childCount: childCount, interfaces: [], name: name, role: role,
            description: "", states: states, children: nil
        )
    }

    @Test func readsStatesFromTheirTwoWords() {
        let set = ATSPIStates(words: [1 << 12 | 1 << 25, 1 << (43 - 32)])
        #expect(set.contains(.focused))
        #expect(set.contains(.showing))
        #expect(set.contains(.readOnly))
        #expect(!set.contains(.checked))
    }

    @Test func mapsRolesOntoTheAXVocabulary() {
        let none = ATSPIStates(bits: 0)
        #expect(ATSPIRoles.ax(43, states: none)! == ("AXButton", nil))
        #expect(ATSPIRoles.ax(130, states: none)! == ("AXCheckBox", "AXSwitch"))
        #expect(ATSPIRoles.ax(40, states: none)! == ("AXTextField", "AXSecureTextField"))
        #expect(ATSPIRoles.ax(61, states: none)! == ("AXStaticText", nil))
        #expect(ATSPIRoles.ax(61, states: states(.editable, .singleLine))! == ("AXTextField", nil))
        #expect(ATSPIRoles.ax(61, states: states(.editable))! == ("AXTextField", nil))
        #expect(ATSPIRoles.ax(61, states: states(.editable, .multiLine))! == ("AXTextArea", nil))
        #expect(ATSPIRoles.ax(23, states: none)! == ("AXWindow", "AXStandardWindow"))
        #expect(ATSPIRoles.ax(16, states: none)! == ("AXWindow", "AXDialog"))
        #expect(ATSPIRoles.ax(37, states: none)! == ("AXRadioButton", "AXTabButton"))
        #expect(ATSPIRoles.ax(999, states: none)! == ("AXGroup", nil))
        #expect(ATSPIRoles.ax(50, states: none) == nil)
    }

    @Test func keepsTheElementsOwnActionsOnce() {
        #expect(ATSPIRoles.actions(["click", "press", "win.close", "", "Expand or Contract", "showmenu"]) == ["AXPress", "AXShowMenu"])
        #expect(ATSPIRoles.actions(["increment", "custom"]) == ["AXIncrement", "custom"])
    }

    @Test func readsTodaysCacheEntries() throws {
        let entry = DBusValue.structure([
            .structure([.string(":1.5"), .objectPath("/a/2")]), .structure([.string(":1.5"), .objectPath("/org/a11y/atspi/accessible/root")]),
            .structure([.string(":1.5"), .objectPath("/a/1")]), .int32(3), .int32(0),
            .array(element: "s", [.string("org.a11y.atspi.Accessible"), .string("org.a11y.atspi.Action")]),
            .string("OK"), .uint32(43), .string("Confirms"), .array(element: "u", [.uint32(1 << 25), .uint32(0)]),
        ])
        let item = try #require(ATSPI.item(fromCache: entry))
        #expect(item.path == "/a/2")
        #expect(item.parent == "/a/1")
        #expect(item.index == 3)
        #expect(item.interfaces.contains("org.a11y.atspi.Action"))
        #expect(item.name == "OK")
        #expect(item.role == 43)
        #expect(item.states.contains(.showing))
        #expect(item.children == nil)
    }

    @Test func readsOlderCacheEntriesThatListChildren() throws {
        let entry = DBusValue.structure([
            .structure([.string(":1.5"), .objectPath("/a/1")]), .structure([.string(":1.5"), .objectPath("/root")]),
            .structure([.string(":1.5"), .objectPath("/root")]),
            .array(element: "(so)", [.structure([.string(":1.5"), .objectPath("/a/3")]), .structure([.string(":1.5"), .objectPath("/a/2")])]),
            .array(element: "s", []), .string("Panel"), .uint32(39), .string(""), .array(element: "u", [.uint32(0), .uint32(0)]),
        ])
        let item = try #require(ATSPI.item(fromCache: entry))
        #expect(item.children == ["/a/3", "/a/2"])
        #expect(ATSPI.children(of: [item])["/a/1"] == ["/a/3", "/a/2"])
    }

    @Test func ordersChildrenByTheirIndex() {
        let items = [
            item("/w", parent: "/root", index: 0, role: 23),
            item("/b", parent: "/w", index: 1, role: 43),
            item("/a", parent: "/w", index: 0, role: 43),
        ]
        #expect(ATSPI.children(of: items)["/w"] == ["/a", "/b"])
    }

    @Test func leavesOutWhatIsntShowing() {
        let hidden = ATSPIStates(bits: 1 << ATSPIState.sensitive.rawValue)
        let items = [
            item("/w", parent: "/root", index: 0, role: 23, childCount: 2),
            item("/page1", parent: "/w", index: 0, role: 39, childCount: 1),
            item("/page2", parent: "/w", index: 1, role: 39, states: hidden),
            item("/ok", parent: "/page1", index: 0, role: 43, name: "OK"),
        ]
        let chosen = ATSPITree.select(items, from: "/w", limit: 100)
        #expect(chosen.map(\.path) == ["/w", "/page1", "/ok"])
        let root = ATSPITree.assemble(items, chosen: chosen, bus: ":1.5", from: "/w", extras: [:])
        #expect(root?.role == "AXWindow")
        #expect(root?.unread == 0)
        #expect(root?.children.first?.children.first?.title == "OK")
    }

    @Test func countsChildrenTheLimitLeftOut() {
        let items = [item("/w", parent: "/root", index: 0, role: 23, childCount: 3)]
            + (0..<3).map { item("/b\($0)", parent: "/w", index: $0, role: 43, name: "B\($0)") }
        let chosen = ATSPITree.select(items, from: "/w", limit: 2)
        let root = ATSPITree.assemble(items, chosen: chosen, bus: ":1.5", from: "/w", extras: [:])
        #expect(root?.children.count == 1)
        #expect(root?.unread == 2)
    }

    @Test func givesEachKindOfElementItsValue() {
        let check = ATSPITree.makeNode(
            item("/c", parent: "/w", index: 0, role: 7, name: "Remember", states: states(.showing, .sensitive, .checked)),
            bus: ":1.5", extras: .init()
        )
        #expect(check?.value == "1")
        #expect(check?.title == "Remember")
        let field = ATSPITree.makeNode(
            item("/f", parent: "/w", index: 0, role: 79, name: "Name"), bus: ":1.5", extras: .init(text: "Ada", identifier: "name_field")
        )
        #expect(field?.value == "Ada")
        #expect(field?.identifier == "name_field")
        let password = ATSPITree.makeNode(item("/p", parent: "/w", index: 0, role: 40), bus: ":1.5", extras: .init(text: "secret"))
        #expect(password?.value == nil)
        let label = ATSPITree.makeNode(item("/l", parent: "/w", index: 0, role: 29, name: "Taps: 2"), bus: ":1.5", extras: .init())
        #expect(label?.value == "Taps: 2")
        #expect(label?.title == nil)
        let slider = ATSPITree.makeNode(item("/s", parent: "/w", index: 0, role: 51, name: "Volume"), bus: ":1.5", extras: .init(value: 50))
        #expect(slider?.value == "50")
        let disabled = ATSPITree.makeNode(item("/d", parent: "/w", index: 0, role: 43, states: states(.showing)), bus: ":1.5", extras: .init())
        #expect(disabled?.enabled == false)
        #expect(check?.key == AnyHashable(ATSPIKey(bus: ":1.5", path: "/c")))
    }

    @Test func picksAppsByPidNameOrPart() throws {
        let apps = [
            ATSPIApp(bus: ":1.1", name: "org.gnome.Nautilus", pid: 10),
            ATSPIApp(bus: ":1.2", name: "gnome-calculator", pid: 20),
            ATSPIApp(bus: ":1.3", name: "gnome-clocks", pid: 30),
        ]
        #expect(try LinuxDesktop.pick("20", from: apps).bus == ":1.2")
        #expect(try LinuxDesktop.pick("nautilus", from: apps).bus == ":1.1")
        #expect(try LinuxDesktop.pick("org.gnome.Nautilus", from: apps).bus == ":1.1")
        #expect(try LinuxDesktop.pick("calc", from: apps).bus == ":1.2")
        #expect(throws: (any Error).self) { try LinuxDesktop.pick("gnome", from: apps) }
        #expect(throws: (any Error).self) { try LinuxDesktop.pick("Safari", from: apps) }
    }

    @Test func namesAppsByTheirID() {
        #expect(LinuxDesktop.displayName(ATSPIApp(bus: ":1.1", name: "org.gnome.Nautilus", pid: 1)) == "Nautilus")
        #expect(LinuxDesktop.appID(ATSPIApp(bus: ":1.1", name: "org.gnome.Nautilus", pid: 1)) == "org.gnome.Nautilus")
        #expect(LinuxDesktop.displayName(ATSPIApp(bus: ":1.2", name: "Google Chrome", pid: 2)) == "Google Chrome")
        #expect(LinuxDesktop.appID(ATSPIApp(bus: ":1.2", name: "Google Chrome", pid: 2)) == nil)
    }

    @Test func numbersWindowsStably() {
        let first = LinuxDesktop.windowID(bus: ":1.5", path: "/a/1")
        #expect(first == LinuxDesktop.windowID(bus: ":1.5", path: "/a/1"))
        #expect(first != LinuxDesktop.windowID(bus: ":1.5", path: "/a/2"))
        #expect(first != LinuxDesktop.windowID(bus: ":1.6", path: "/a/1"))
    }
}
