import Foundation
import Testing
@testable import HarnessCore

struct ElementRegistryTests {
    @Test func aRefStillNamesTheAppItWasHandedOutFor() {
        let registry = ElementRegistry(tag: "z")
        let old = registry.ref(for: AnyHashable("button"), pid: 4998)
        let other = registry.ref(for: AnyHashable("field"), pid: 700)
        #expect(registry.owner(of: old) == 4998)
        #expect(registry.owner(of: other) == 700)
        #expect(registry.owner(of: "z99999") == nil)
        if case .unknown = registry.lookup(old, pid: 12735) {} else { Issue.record("a ref from another pid isn't found for the new one") }
    }
}
