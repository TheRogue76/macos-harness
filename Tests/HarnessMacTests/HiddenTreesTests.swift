import Foundation
import Testing
@testable import HarnessMac

struct HiddenTreesTests {
    @Test func aBrowserPageIsLookedAtAgainEveryFewSeconds() async {
        let trees = HiddenTrees()
        let start = Date()
        #expect(await trees.dueForAnotherLook(4998, now: start))
        #expect(await !trees.dueForAnotherLook(4998, now: start.addingTimeInterval(1)))
        #expect(await trees.dueForAnotherLook(700, now: start.addingTimeInterval(1)))
        #expect(await trees.dueForAnotherLook(4998, now: start.addingTimeInterval(HiddenTrees.lookAgain + 0.1)))
    }
}
