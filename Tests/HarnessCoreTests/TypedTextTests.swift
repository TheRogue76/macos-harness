import Foundation
import HarnessProtocol
import Testing
@testable import HarnessCore

struct TypedTextTests {
    @Test func nothingIsMissingWhenTheFieldHoldsTheText() {
        #expect(TypedText.missing("Grüße ä 東京 👍", from: "Hello, Grüße ä 東京 👍") == nil)
        #expect(TypedText.missing("grüße", from: "GRÜSSE") == nil)
        #expect(TypedText.missing("ä", from: "a\u{0308}") == nil)
        #expect(TypedText.missing("070-123", from: "070-123 45") == nil)
    }

    @Test func reformattingAndSpacesAreNotMissingCharacters() {
        #expect(TypedText.missing("0701 23", from: "070123") == nil)
        #expect(TypedText.missing("abc", from: "c b a") == nil)
    }

    @Test func dropsAreListedOnceInTypingOrder() {
        #expect(TypedText.missing("Grüße ä ö", from: "Grüße  ö") == "ä")
        #expect(TypedText.missing("Mästare ärlig", from: "Mstare rlig") == "ä")
        #expect(TypedText.missing("ä ö é", from: "a o e") == "äöé")
    }

    @Test func returnsAndTabsAreKeysSoTheyAreNotChecked() {
        #expect(TypedText.missing("hello\n", from: "") == nil)
        #expect(TypedText.missing("a\tb", from: "") == nil)
    }

    @Test func theNoticeNamesTheFieldAndWhatDidNotArrive() throws {
        let typed = try #require(TypedText.notice(typed: "Mästare", field: "textfield “Name”", value: "Mstare"))
        #expect(typed.kind == "typedTextMissing")
        #expect(typed.message == "After typing, textfield “Name” reads “Mstare”, without “ä”. The app may have dropped or filtered those characters; if they belong there, `paste` puts text in through the clipboard.")
        let pasted = try #require(TypedText.notice(typed: "Mästare", pasted: true, field: "textfield “Name”", value: "Mstare"))
        #expect(pasted.message == "After pasting, textfield “Name” reads “Mstare”, without “ä”. The app may have dropped or filtered those characters.")
        #expect(TypedText.notice(typed: "Mästare", field: "textfield “Name”", value: "Mästare") == nil)
    }
}
