import Foundation
import HarnessDBus
@testable import HarnessLinux
import Testing

struct TrayIconTests {
    let items = [
        TrayIcon.Item("macOS Harness — Idle", enabled: false),
        .separatorLine,
        TrayIcon.Item("Stop all agents", action: "stop"),
        TrayIcon.Item("Quit_now", action: "quit"),
    ]

    @Test func numbersMenuLinesFromOneWithTheirProperties() {
        let entries = TrayIcon.entries(items)
        #expect(entries.map(\.id) == [1, 2, 3, 4])
        #expect(entries[0].properties["label"] == .string("macOS Harness — Idle"))
        #expect(entries[0].properties["enabled"] == .boolean(false))
        #expect(entries[1].properties["type"] == .string("separator"))
        #expect(entries[1].properties["label"] == nil)
        #expect(entries[3].properties["label"] == .string("Quit__now"))
    }

    @Test func layoutIsARootHoldingEveryLine() {
        guard case .structure(let root) = TrayIcon.layout(items) else {
            Issue.record("the layout isn't a structure")
            return
        }
        #expect(root[0] == .int32(0))
        #expect(root[1].dictionary?["children-display"]?.unwrapped == .string("submenu"))
        #expect(root[2].elements?.count == 4)
        #expect(TrayIcon.layout(items).signature == "(ia{sv}av)")
    }

    @Test func drawsTheGlyphWithTheDotOnlyForAttention() {
        #expect(!TrayIcon.glyph(color: "#bebebe", dot: false).contains("#FF450F"))
        #expect(TrayIcon.glyph(color: "#bebebe", dot: true).contains("#FF450F"))
        #expect(TrayIcon.glyph(color: "#bebebe", dot: false).hasPrefix("<svg"))
    }
}
