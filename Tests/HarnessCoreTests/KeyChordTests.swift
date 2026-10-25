import HarnessProtocol
import Testing
@testable import HarnessCore

struct KeyChordTests {
    @Test func parsesNamedModifiers() throws {
        let chord = try KeyChord.parse("cmd+shift+s")
        #expect(chord.key == .character("s"))
        #expect(chord.modifiers == [.command, .shift])
        #expect(chord.display == "⇧⌘S")
    }

    @Test func parsesSymbolsAndNamedKeys() throws {
        #expect(try KeyChord.parse("⇧⌘G") == KeyChord(key: .character("g"), modifiers: [.shift, .command], display: "⇧⌘G"))
        #expect(try KeyChord.parse("return").key == .named(.return))
        #expect(try KeyChord.parse("enter").key == .named(.return))
        #expect(try KeyChord.parse("esc").display == "⎋")
        #expect(try KeyChord.parse("ctrl+opt+cmd+.").display == "⌃⌥⌘.")
        #expect(try KeyChord.parse("f5").key == .named(.f5))
        #expect(try KeyChord.parse("F12").display == "F12")
        #expect(try KeyChord.parse("fn+left").display == "fn ←")
        #expect(try KeyChord.parse("cmd ö") == KeyChord(key: .character("ö"), modifiers: .command, display: "⌘Ö"))
    }

    @Test func rejectsNonsense() {
        #expect(throws: RPCError.self) { try KeyChord.parse("cmd+banana") }
        #expect(throws: RPCError.self) { try KeyChord.parse("hyper+s") }
        #expect(throws: RPCError.self) { try KeyChord.parse("  ") }
    }

    @Test func readsModifierLists() throws {
        #expect(try KeyChord.modifiers(named: ["CMD", "alt", "⇧"]) == [.command, .option, .shift])
        #expect(try KeyChord.modifiers(named: []) == [])
        #expect(throws: RPCError.self) { try KeyChord.modifiers(named: ["hyper"]) }
    }
}
