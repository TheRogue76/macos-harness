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

    @Test func dragsListWhatChangedInTheWindowTheyEndedIn() {
        let finder = AppRef(name: "Finder", bundleIdentifier: "com.apple.finder", pid: 10)
        let textEdit = AppRef(name: "TextEdit", bundleIdentifier: "com.apple.TextEdit", pid: 20)
        let window = WindowInfo(
            id: 455, app: textEdit, title: "Untitled", frame: Rect(x: 0, y: 0, width: 400, height: 300), onScreen: true,
            minimized: false, focused: false, main: true, subrole: nil, hasSheet: false
        )
        var result = ActionResult(
            app: finder, window: nil, element: nil, performed: "dragged row “a.txt” (k3) to point (40, 60) in TextEdit window 455 “Untitled”",
            via: "real input", settledMilliseconds: 420,
            destination: .init(window: window, changes: [UIChange(kind: "added", node: UINode(ref: "t9", role: "AXImage", label: "a.txt"))])
        )
        #expect(Render.action(result).split(separator: "\n").map(String.init) == [
            "dragged row “a.txt” (k3) to point (40, 60) in TextEdit window 455 “Untitled” via real input · settled in 420 ms",
            "No visible change in the window (take a snapshot if you expected one).",
            "Changes in TextEdit window 455 “Untitled”:",
            #"  + t9 image "a.txt""#,
        ])
        result.destination?.changes = []
        #expect(Render.action(result).hasSuffix("No visible change in TextEdit window 455 “Untitled”."))
    }
}
