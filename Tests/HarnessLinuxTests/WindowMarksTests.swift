#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
@testable import HarnessLinux
import HarnessProtocol
import Testing

struct WindowMarksTests {
    @Test func theMarkerLeavesRoomForTheGlowAndTheTabAbove() {
        let frame = WindowMarks.markerFrame(around: CGRect(x: 300, y: 200, width: 600, height: 500), tabInside: false)
        #expect(frame == CGRect(x: 293, y: 173, width: 614, height: 534))
    }

    @Test func theTabGoesInsideWhenTheWindowIsAtTheTop() {
        #expect(WindowMarks.tabInside(CGRect(x: 0, y: 0, width: 1280, height: 800)))
        #expect(WindowMarks.tabInside(CGRect(x: 0, y: 20, width: 600, height: 400)))
        #expect(!WindowMarks.tabInside(CGRect(x: 0, y: 27, width: 600, height: 400)))
        let inside = WindowMarks.markerFrame(around: CGRect(x: 0, y: 0, width: 1280, height: 800), tabInside: true)
        #expect(inside == CGRect(x: -7, y: -7, width: 1294, height: 814))
    }

    @Test func kwinsFrameIsTheOuterFrameWhenItDrawsATitleBar() throws {
        let reply = """
            {"width": 1280, "height": 800, "windows": [
              {"id": "a", "pid": 1, "title": "Server", "appId": "x", "x": 100, "y": 130, "width": 400, "height": 300,
               "frame": [100, 100, 400, 330], "focused": false, "minimized": false},
              {"id": "b", "pid": 2, "title": "Client", "appId": "y", "x": 10, "y": 10, "width": 200, "height": 100,
               "frame": [10, 10, 200, 100], "focused": false, "minimized": false}
            ]}
            """
        let layout = try #require(try JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
        let windows = KWinCompositor.windows(from: layout)
        #expect(windows[0].outer == CGRect(x: 100, y: 100, width: 400, height: 330))
        #expect(windows[1].outer == nil)
    }
}
