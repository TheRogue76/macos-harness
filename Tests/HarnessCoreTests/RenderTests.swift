import HarnessClient
import HarnessProtocol
import Testing

struct RenderTests {
    @Test func rendersAButtonCompactly() {
        let node = UINode(
            ref: "e4", role: "AXButton", label: "Increment", identifier: "increment-button",
            actions: ["AXPress"], hit: Point(x: 69, y: 105)
        )
        #expect(Render.node(node) == #"e4 button "Increment" id=increment-button @69,105"#)
    }

    @Test func rendersTogglesAsOnOff() {
        let toggle = UINode(ref: "e9", role: "AXCheckBox", subrole: "AXSwitch", value: "0", identifier: "enabled-toggle")
        #expect(Render.node(toggle) == "e9 switch off id=enabled-toggle")
    }

    @Test func rendersStateAndExtraActions() {
        let node = UINode(
            ref: "e2", role: "AXButton", label: "Stockholm", value: "13°", enabled: false, selected: true,
            actions: ["AXPress", "Trash", "AXIncrement"], omitted: 3
        )
        #expect(Render.node(node) == #"e2 button "Stockholm" = "13°" disabled selected actions: Trash, increment (+3 more)"#)
    }

    @Test func flattensMultilineText() {
        let text = UINode(ref: "e7", role: "AXStaticText", value: "line one\nline two")
        #expect(Render.node(text) == #"e7 text "line one ⏎ line two""#)
    }
}
