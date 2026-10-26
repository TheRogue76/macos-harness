import Foundation
import HarnessDBus
import Testing
@testable import HarnessLinux

struct StatusItemsTests {
    private func entry(_ id: Int32, _ properties: [String: DBusValue], _ children: [DBusValue] = []) -> DBusValue {
        .structure([.int32(id), .properties(properties), .array(element: "v", children.map { .variant($0) })])
    }

    private let items = [
        StatusItem(service: ":1.5", path: "/StatusNotifierItem", pid: 40, id: "com.calendar.tray", title: "Calendar", menu: "/MenuBar", process: "calendar-notifier"),
        StatusItem(service: ":1.9", path: "/StatusNotifierItem", pid: 77, id: "harness-fixture-extra", title: "Harness Fixture Extra", menu: "/MenuBar", process: "status-item.py"),
    ]

    @Test func readsWatcherEntries() {
        #expect(StatusItems.location(":1.51@/org/ayatana/NotificationItem/livepatch") == (":1.51", "/org/ayatana/NotificationItem/livepatch"))
        #expect(StatusItems.location("org.kde.StatusNotifierItem-40-1") == ("org.kde.StatusNotifierItem-40-1", "/StatusNotifierItem"))
    }

    @Test func readsAMenuLayout() throws {
        let layout = entry(0, ["children-display": .string("submenu")], [
            entry(1, ["label": .string("_Save"), "shortcut": .array(element: "as", [.array(element: "s", [.string("Control"), .string("s")])])]),
            entry(2, ["type": .string("separator")]),
            entry(3, ["label": .string("Show __hidden"), "toggle-type": .string("checkmark"), "toggle-state": .int32(1)]),
            entry(4, ["label": .string("Gone"), "visible": .boolean(false)]),
            entry(5, ["label": .string("More"), "enabled": .boolean(false)], [entry(6, ["label": .string("Inside")])]),
        ])
        let root = try #require(StatusItems.entry(from: layout))
        #expect(root.isSubmenu)
        #expect(root.children.map(\.label) == ["Save", "", "Show _hidden", "More"])
        #expect(root.children[0].shortcut == "Control+s")
        #expect(root.children[1].isSeparator)
        #expect(root.children[2].mark == "✓")
        #expect(root.children[3].enabled == false)
        #expect(root.children[3].isSubmenu)
        #expect(try StatusItems.entry(at: ["more", "Inside"], in: root, icon: "X").id == 6)
        #expect(throws: (any Error).self) { try StatusItems.entry(at: ["Nope"], in: root, icon: "X") }
    }

    @Test func dropsMnemonicUnderscores() {
        #expect(StatusItems.mnemonicFree("_File") == "File")
        #expect(StatusItems.mnemonicFree("snake__case") == "snake_case")
        #expect(StatusItems.mnemonicFree("plain") == "plain")
    }

    @Test func findsAnAppsIcons() {
        #expect(StatusItems.matching("calendar", in: items).map(\.pid) == [40])
        #expect(StatusItems.matching("status-item.py", in: items).map(\.pid) == [77])
        #expect(StatusItems.matching("77", in: items).map(\.pid) == [77])
        #expect(StatusItems.matching("Fixture", in: items).map(\.pid) == [77])
        #expect(StatusItems.matching("*", in: items).count == 2)
        #expect(StatusItems.matching("Nothing", in: items).isEmpty)
    }

    @Test func picksTheIconAPathStartsWith() throws {
        #expect(try StatusItems.pick(["Calendar", "Settings"], from: items).1 == ["Settings"])
        #expect(try StatusItems.pick(["Settings"], from: [items[0]]).0.pid == 40)
        #expect(throws: (any Error).self) { try StatusItems.pick(["Settings"], from: items) }
    }
}
