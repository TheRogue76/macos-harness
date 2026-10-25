import ApplicationServices
import CoreGraphics
import Foundation
import HarnessProtocol
import Testing
@testable import HarnessCore
@testable import HarnessMac

struct OtherSpaceTests {
    private func window(otherSpace: Bool) -> WindowService.Window {
        var info = WindowInfo(
            id: 7, app: AppRef(name: "Fixture", bundleIdentifier: nil, pid: getpid()), title: "Fixture",
            frame: Rect(x: 100, y: 50, width: 400, height: 300), onScreen: false, minimized: false,
            focused: true, main: true, subrole: nil, hasSheet: false
        )
        info.otherSpace = otherSpace ? true : nil
        return WindowService.Window(info: info, element: AXUIElementCreateApplication(getpid()))
    }

    @Test func backgroundClicksReachAWindowOnAnotherSpace() {
        let inside = CGPoint(x: 200, y: 100)
        let notShown: (UInt32) -> Bool = { _ in false }
        guard BackgroundInput.isAvailable else { return }
        #expect(BackgroundInput.reachable(inside, in: window(otherSpace: true), isOnScreen: notShown))
        #expect(!BackgroundInput.reachable(inside, in: window(otherSpace: false), isOnScreen: notShown))
        #expect(!BackgroundInput.reachable(CGPoint(x: 10, y: 10), in: window(otherSpace: true), isOnScreen: notShown))
    }

    @Test func realInputIsRefusedThereWithTheWayBack() async {
        let app = AppRef(name: "Fixture", bundleIdentifier: nil, pid: getpid())
        do {
            _ = try await RealInputSession.begin(app: app, window: window(otherSpace: true), context: .unattended, keyboard: false)
            Issue.record("expected a refusal")
        } catch let error as RPCError {
            #expect(error.code == RPCErrorCode.failed)
            #expect(error.message.contains("another Space"))
            #expect(error.message.contains("launch \"Fixture\" --activate"))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func onlyWindowsOnOtherSpacesAddToTheWindowList() {
        let app = AppRef(name: "Fixture", bundleIdentifier: nil, pid: getpid())
        let titles = WindowService.titles(of: [window(otherSpace: false)], app: app, otherSpaces: false)
        #expect(titles == [7: "Fixture"])
    }

    @Test func theRemoteLookupGivesNothingForAWindowThatIsntThere() {
        #expect(RemoteElements.window(pid: getpid(), id: 999_999, tries: 50) == nil)
    }
}
