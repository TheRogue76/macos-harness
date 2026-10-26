#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
@testable import HarnessLinux
import Testing

struct KWinCompositorTests {
    @Test func readsWindowsFromTheScriptsReply() throws {
        let reply = """
            {"width": 1280, "height": 800, "windows": [
              {"id": "{6f1c0e3a-0000-4000-8000-000000000001}", "pid": 42, "title": "Harness Fixture", "appId": "harness-fixture",
               "x": 200, "y": 104, "width": 880, "height": 620, "focused": true, "minimized": false, "output": "Virtual-0"},
              {"id": "{6f1c0e3a-0000-4000-8000-000000000002}", "pid": 43, "title": "Other", "appId": "org.kde.dolphin",
               "x": 0, "y": 0, "width": 400, "height": 300, "focused": false, "minimized": true, "output": null}
            ]}
            """
        let layout = try #require(try JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
        let windows = KWinCompositor.windows(from: layout)
        #expect(windows.count == 2)
        #expect(windows[0].pid == 42)
        #expect(windows[0].title == "Harness Fixture")
        #expect(windows[0].frame == CGRect(x: 200, y: 104, width: 880, height: 620))
        #expect(windows[0].focused)
        #expect(windows[0].visible)
        #expect(windows[0].output == "Virtual-0")
        #expect(windows[0].key == "{6f1c0e3a-0000-4000-8000-000000000001}")
        #expect(!windows[1].visible)
        #expect(windows[1].output == nil)
    }

    @Test func numbersWindowsTheSameWayEveryTime() {
        let key = "{6f1c0e3a-0000-4000-8000-000000000001}"
        #expect(KWinCompositor.id(for: key) == KWinCompositor.id(for: key))
        #expect(KWinCompositor.id(for: key) != KWinCompositor.id(for: "{6f1c0e3a-0000-4000-8000-000000000002}"))
        #expect(KWinCompositor.id(for: key) >= 0)
    }
}
