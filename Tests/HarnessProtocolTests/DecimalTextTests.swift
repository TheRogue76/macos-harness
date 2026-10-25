import HarnessProtocol
import Testing

struct DecimalTextTests {
    @Test func matchesPrintfsFixedPoint() {
        #expect(0.0.fixed(1) == "0.0")
        #expect(1.25.fixed(1) == "1.2")
        #expect(1.35.fixed(1) == "1.4")
        #expect(0.04.fixed(1) == "0.0")
        #expect(12.5.fixed(2) == "12.50")
        #expect(3.007.fixed(2) == "3.01")
        #expect((-2.25).fixed(1) == "-2.2")
        #expect((-0.01).fixed(1) == "0.0")
        #expect(7.6.fixed(0) == "8")
    }
}
