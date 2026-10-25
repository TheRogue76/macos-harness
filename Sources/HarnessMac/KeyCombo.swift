import CoreGraphics
import Foundation
import HarnessCore
import HarnessProtocol

/// A key plus modifiers as macOS posts it: a key chord resolved to a virtual key code and event
/// flags. Printable keys go where a keyboard layout types their character (with Shift added when
/// the layout needs it); named keys (return, arrows, f1…) keep their fixed key codes.
public struct KeyCombo: Equatable, Sendable {
    public var keyCode: CGKeyCode
    public var flags: CGEventFlags
    public var display: String

    /// The virtual key code of each key known by name.
    static let namedKeyCodes: [KeyChord.NamedKey: CGKeyCode] = [
        .return: 36, .tab: 48, .space: 49, .delete: 51, .escape: 53, .forwardDelete: 117, .home: 115, .end: 119,
        .pageUp: 116, .pageDown: 121, .left: 123, .right: 124, .down: 125, .up: 126,
        .f1: 122, .f2: 120, .f3: 99, .f4: 118, .f5: 96, .f6: 97, .f7: 98, .f8: 100, .f9: 101, .f10: 109, .f11: 103, .f12: 111,
    ]

    /// Parses `text`. A printable key goes where `layout` types its character, or to its US
    /// position when `layout` is nil or lacks the character.
    public static func parse(_ text: String, layout: KeyLayout? = nil) throws -> KeyCombo {
        try KeyCombo(KeyChord.parse(text), layout: layout)
    }

    /// The event flags for a set of modifiers.
    static func flags(for modifiers: KeyModifiers) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        if modifiers.contains(.function) { flags.insert(.maskSecondaryFn) }
        return flags
    }
}

extension KeyCombo {
    /// The chord resolved against `layout`, or the US layout when `layout` is nil or lacks the
    /// character.
    public init(_ chord: KeyChord, layout: KeyLayout? = nil) throws {
        var flags = Self.flags(for: chord.modifiers)
        switch chord.key {
        case .named(let name):
            guard let code = Self.namedKeyCodes[name] else { throw KeyChord.unknownKey(name.rawValue) }
            self.init(keyCode: code, flags: flags, display: chord.display)
        case .character(let character):
            let command = chord.modifiers.contains(.command)
            guard let key = layout?.key(for: character, command: command) ?? KeyLayout.us.key(for: character, command: command) else {
                throw KeyChord.unknownKey(String(character))
            }
            if key.shift { flags.insert(.maskShift) }
            self.init(keyCode: key.code, flags: flags, display: chord.display)
        }
    }
}
