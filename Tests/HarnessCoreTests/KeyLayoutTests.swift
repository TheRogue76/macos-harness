import CoreGraphics
import HarnessProtocol
import Testing
@testable import HarnessCore

@MainActor
struct KeyLayoutTests {
    static let ansiKeyboard: UInt32 = 40
    static let shortcuts = ["cmd+z", "cmd+y", "cmd+a", "cmd+q", "cmd+w", "cmd+m", "cmd+1"]

    func installed(_ id: String) throws -> KeyLayout {
        try #require(KeyLayout.installed(id, keyboardType: Self.ansiKeyboard), "\(id) isn't installed")
    }

    func codes(_ layout: KeyLayout) throws -> [String: CGKeyCode] {
        var codes: [String: CGKeyCode] = [:]
        for text in Self.shortcuts { codes[text] = try KeyCombo.parse(text, layout: layout).keyCode }
        return codes
    }

    @Test func usLayoutMatchesTheBuiltInPositions() throws {
        let us = try installed("com.apple.keylayout.US")
        #expect(try codes(us) == ["cmd+z": 6, "cmd+y": 16, "cmd+a": 0, "cmd+q": 12, "cmd+w": 13, "cmd+m": 46, "cmd+1": 18])
        for text in Self.shortcuts {
            let combo = try KeyCombo.parse(text, layout: us)
            #expect(combo.flags == .maskCommand, "\(text)")
            #expect(try KeyCombo.parse(text) == combo, "\(text)")
        }
    }

    @Test func germanSwapsYAndZ() throws {
        let german = try installed("com.apple.keylayout.German")
        #expect(try codes(german) == ["cmd+z": 16, "cmd+y": 6, "cmd+a": 0, "cmd+q": 12, "cmd+w": 13, "cmd+m": 46, "cmd+1": 18])
        for text in Self.shortcuts {
            #expect(try KeyCombo.parse(text, layout: german).flags == .maskCommand, "\(text)")
        }
    }

    @Test func frenchMovesLettersAndShiftsDigits() throws {
        let french = try installed("com.apple.keylayout.French")
        #expect(try codes(french) == ["cmd+z": 13, "cmd+y": 16, "cmd+a": 12, "cmd+q": 0, "cmd+w": 6, "cmd+m": 41, "cmd+1": 18])
        for text in Self.shortcuts.dropLast() {
            #expect(try KeyCombo.parse(text, layout: french).flags == .maskCommand, "\(text)")
        }
        let digit = try KeyCombo.parse("cmd+1", layout: french)
        #expect(digit.flags == [.maskCommand, .maskShift])
        #expect(digit.display == "⌘1")
        #expect(try KeyCombo.parse("7", layout: french) == KeyCombo(keyCode: 26, flags: .maskShift, display: "7"))
    }

    @Test func commandUsesTheKeysTheLayoutTypesWithCommandHeld() throws {
        let dvorak = try installed("com.apple.keylayout.Dvorak")
        #expect(try KeyCombo.parse("cmd+z", layout: dvorak).keyCode == 44)
        let qwertyCommand = try installed("com.apple.keylayout.DVORAK-QWERTYCMD")
        #expect(try KeyCombo.parse("cmd+z", layout: qwertyCommand).keyCode == 6)
        #expect(try KeyCombo.parse("ctrl+z", layout: qwertyCommand).keyCode == 44)
        let russian = try installed("com.apple.keylayout.Russian")
        #expect(try KeyCombo.parse("cmd+z", layout: russian).keyCode == 6)
    }

    @Test func namedKeysAndDisplayIgnoreTheLayout() throws {
        let french = try installed("com.apple.keylayout.French")
        #expect(try KeyCombo.parse("return", layout: french).keyCode == 36)
        #expect(try KeyCombo.parse("esc", layout: french).keyCode == 53)
        #expect(try KeyCombo.parse("f5", layout: french).keyCode == 96)
        #expect(try KeyCombo.parse("cmd+left", layout: french) == KeyCombo(keyCode: 123, flags: .maskCommand, display: "⌘←"))
        #expect(try KeyCombo.parse("⇧⌘N", layout: french) == KeyCombo(keyCode: 45, flags: [.maskShift, .maskCommand], display: "⇧⌘N"))
        #expect(try KeyCombo.parse("ctrl+opt+cmd+a", layout: french).display == "⌃⌥⌘A")
    }

    @Test func layoutCharactersBeyondUSAreKeys() throws {
        let german = try installed("com.apple.keylayout.German")
        #expect(try KeyCombo.parse("cmd+ö", layout: german) == KeyCombo(keyCode: 41, flags: .maskCommand, display: "⌘Ö"))
        #expect(throws: RPCError.self) { try KeyCombo.parse("cmd+ö") }
    }

    @Test func charactersTheLayoutLacksKeepTheirUSPositions() throws {
        let german = try installed("com.apple.keylayout.German")
        #expect(try KeyCombo.parse("cmd+[", layout: german) == KeyCombo(keyCode: 33, flags: .maskCommand, display: "⌘["))
        let russian = try installed("com.apple.keylayout.Russian")
        #expect(try KeyCombo.parse("ctrl+z", layout: russian).keyCode == 6)
    }

    @Test func currentLayoutLoads() throws {
        let layout = try #require(KeyLayout.current())
        #expect(KeyLayout.current()?.id == layout.id)
        #expect(try KeyCombo.parse("cmd+return", layout: layout).keyCode == 36)
    }

    @Test func cacheRebuildsOnlyWhenTheInputSourceChanges() {
        var cache = KeyLayoutCache()
        var builds = 0
        func look(_ id: String, _ keyboardType: UInt32, _ layout: KeyLayout? = .us) -> String? {
            cache.layout(id: id, keyboardType: keyboardType) {
                builds += 1
                return layout
            }?.id
        }
        #expect(look("German", 40) == KeyLayout.us.id)
        #expect(look("German", 40) == KeyLayout.us.id)
        #expect(builds == 1)
        _ = look("French", 40)
        #expect(builds == 2)
        _ = look("French", 41)
        _ = look("French", 41)
        #expect(builds == 3)
        #expect(look("Kotoeri", 41, nil) == nil)
        #expect(look("Kotoeri", 41, nil) == nil)
        #expect(builds == 4)
    }
}
