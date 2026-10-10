import CoreGraphics
import Foundation
import Testing
@testable import HarnessCore

@Suite struct OnScreenWindowTests {
    func entry(_ number: UInt32, _ rect: CGRect, layer: Int = 0, owner: pid_t = 10, alpha: Double = 1) -> [String: Any] {
        [
            kCGWindowNumber as String: NSNumber(value: number),
            kCGWindowBounds as String: rect.dictionaryRepresentation as NSDictionary,
            kCGWindowLayer as String: NSNumber(value: layer),
            kCGWindowOwnerPID as String: NSNumber(value: owner),
            kCGWindowAlpha as String: NSNumber(value: alpha),
        ]
    }

    @Test func listsTheNormalWindowsInFrontOfIt() throws {
        let list = [
            entry(1, CGRect(x: 0, y: 0, width: 1728, height: 33), layer: 25),
            entry(2, CGRect(x: 400, y: 60, width: 500, height: 460)),
            entry(3, CGRect(x: 0, y: 0, width: 1728, height: 1117), layer: 20),
            entry(4, CGRect(x: 60, y: 110, width: 520, height: 380)),
            entry(5, CGRect(x: 0, y: 0, width: 300, height: 300)),
        ]
        let placement = try #require(OnScreenWindow.placement(of: 4, in: list, ignoring: 99))
        #expect(placement.frame == CGRect(x: 60, y: 110, width: 520, height: 380))
        #expect(placement.occluders == [CGRect(x: 400, y: 60, width: 500, height: 460)])
        #expect(placement.nearestAbove == 2)
    }

    @Test func ourOwnWindowsDontCoverIt() throws {
        let list = [
            entry(2, CGRect(x: 400, y: 60, width: 500, height: 460)),
            entry(7, CGRect(x: 24, y: 74, width: 592, height: 452), owner: 99),
            entry(4, CGRect(x: 60, y: 110, width: 520, height: 380)),
        ]
        let placement = try #require(OnScreenWindow.placement(of: 4, in: list, ignoring: 99))
        #expect(placement.occluders == [CGRect(x: 400, y: 60, width: 500, height: 460)])
        #expect(placement.nearestAbove == 7)
    }

    @Test func invisibleAndTinyWindowsDontCoverIt() throws {
        let list = [
            entry(2, CGRect(x: 400, y: 60, width: 500, height: 460), alpha: 0),
            entry(3, CGRect(x: 100, y: 100, width: 2, height: 2)),
            entry(4, CGRect(x: 60, y: 110, width: 520, height: 380)),
        ]
        #expect(try #require(OnScreenWindow.placement(of: 4, in: list, ignoring: 99)).occluders.isEmpty)
    }

    @Test func aWindowThatIsntOnScreenHasNoPlacement() {
        let list = [entry(2, CGRect(x: 400, y: 60, width: 500, height: 460))]
        #expect(OnScreenWindow.placement(of: 4, in: list, ignoring: 99) == nil)
    }
}
