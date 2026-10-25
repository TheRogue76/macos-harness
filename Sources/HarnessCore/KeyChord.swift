import Foundation
import HarnessProtocol

/// Modifier keys, named as on a Mac keyboard; each platform maps them to its own.
public struct KeyModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let control = KeyModifiers(rawValue: 1 << 0)
    public static let option = KeyModifiers(rawValue: 1 << 1)
    public static let shift = KeyModifiers(rawValue: 1 << 2)
    public static let command = KeyModifiers(rawValue: 1 << 3)
    public static let function = KeyModifiers(rawValue: 1 << 4)
}

/// A key plus modifiers, parsed from text like "cmd+shift+s", "⌘S" or "return", before a
/// keyboard layout decides which physical key types it.
public struct KeyChord: Hashable, Sendable {
    /// Keys known by name, whose position doesn't depend on the keyboard layout.
    public enum NamedKey: String, CaseIterable, Hashable, Sendable {
        case `return`, tab, space, delete, escape, forwardDelete, home, end, pageUp, pageDown
        case left, right, down, up
        case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12
    }

    /// What the chord presses besides its modifiers.
    public enum Key: Hashable, Sendable {
        case named(NamedKey)
        /// A printable character, lowercased; the layout decides where it is and whether it needs Shift.
        case character(Character)
    }

    public var key: Key
    public var modifiers: KeyModifiers
    /// The chord as a Mac menu shows it, e.g. "⌃⌥⌘A" or "⇧⌘N".
    public var display: String

    public init(key: Key, modifiers: KeyModifiers, display: String) {
        self.key = key
        self.modifiers = modifiers
        self.display = display
    }

    /// Modifier names and symbols as they may be written, with the symbol a chord shows for each.
    package static let modifierNames: [String: (KeyModifiers, String)] = [
        "cmd": (.command, "⌘"), "command": (.command, "⌘"), "⌘": (.command, "⌘"),
        "shift": (.shift, "⇧"), "⇧": (.shift, "⇧"),
        "opt": (.option, "⌥"), "option": (.option, "⌥"), "alt": (.option, "⌥"), "⌥": (.option, "⌥"),
        "ctrl": (.control, "⌃"), "control": (.control, "⌃"), "⌃": (.control, "⌃"),
        "fn": (.function, "fn "),
    ]

    /// Named keys as they may be written, with the symbol a chord shows for each.
    package static let namedKeys: [String: (NamedKey, String)] = {
        var table: [String: (NamedKey, String)] = [
            "return": (.return, "↩"), "enter": (.return, "↩"), "tab": (.tab, "⇥"), "space": (.space, "Space"),
            "delete": (.delete, "⌫"), "backspace": (.delete, "⌫"), "esc": (.escape, "⎋"), "escape": (.escape, "⎋"),
            "forwarddelete": (.forwardDelete, "⌦"), "home": (.home, "↖"), "end": (.end, "↘"), "pageup": (.pageUp, "⇞"),
            "pagedown": (.pageDown, "⇟"), "left": (.left, "←"), "right": (.right, "→"), "down": (.down, "↓"), "up": (.up, "↑"),
        ]
        let functionKeys: [NamedKey] = [.f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12]
        for (index, key) in functionKeys.enumerated() { table["f\(index + 1)"] = (key, "F\(index + 1)") }
        return table
    }()

    /// Parses `text`, refusing unknown modifiers and keys.
    public static func parse(_ text: String) throws -> KeyChord {
        var modifiers: KeyModifiers = []
        var prefix = ""
        var remaining = text.trimmingCharacters(in: .whitespaces)
        while let first = remaining.first, let (modifier, symbol) = modifierNames[String(first)], remaining.count > 1 {
            modifiers.insert(modifier)
            prefix += symbol
            remaining.removeFirst()
        }
        let parts = remaining.split(whereSeparator: { $0 == "+" || $0 == " " }).map { $0.lowercased() }
        guard let keyName = parts.last else {
            throw RPCError(code: RPCErrorCode.invalidParams, message: "Give a key, e.g. cmd+s, return or ⇧⌘S.")
        }
        for name in parts.dropLast() {
            guard let (modifier, symbol) = modifierNames[name] else {
                throw unknownModifier(name)
            }
            modifiers.insert(modifier)
            prefix += symbol
        }
        let order = ["⌃", "⌥", "⇧", "⌘"]
        let sorted = order.filter { prefix.contains($0) }.joined() + (prefix.contains("fn ") ? "fn " : "")
        if let (named, display) = namedKeys[keyName] {
            return KeyChord(key: .named(named), modifiers: modifiers, display: sorted + display)
        }
        guard keyName.count == 1, let character = keyName.first else { throw unknownKey(keyName) }
        let upper = keyName.uppercased()
        return KeyChord(key: .character(character), modifiers: modifiers, display: sorted + (upper.count == 1 ? upper : keyName))
    }

    /// Modifiers named in a list such as a pointer step's, e.g. ["cmd", "shift"].
    public static func modifiers(named names: [String]) throws -> KeyModifiers {
        var modifiers: KeyModifiers = []
        for name in names {
            guard let (modifier, _) = modifierNames[name.lowercased()] else { throw unknownModifier(name) }
            modifiers.insert(modifier)
        }
        return modifiers
    }

    /// The error for a key name nothing knows, including a character no layout can type.
    package static func unknownKey(_ name: String) -> RPCError {
        RPCError(
            code: RPCErrorCode.invalidParams,
            message: "Unknown key \(name). Use a letter, digit, punctuation, return, tab, space, delete, esc, arrows, home, end, page keys or f1–f12."
        )
    }

    static func unknownModifier(_ name: String) -> RPCError {
        RPCError(code: RPCErrorCode.invalidParams, message: "Unknown modifier \(name); use cmd, shift, opt or ctrl.")
    }
}
