#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import HarnessCore
import HarnessProtocol

/// A key plus modifiers, parsed from text like "cmd+shift+s", "⌘S" or "return". Printable keys
/// go where a keyboard layout types their character (with Shift added when the layout needs it);
/// named keys (return, arrows, f1…) keep their fixed key codes.
public struct KeyCombo: Equatable, Sendable {
    public var keyCode: CGKeyCode
    public var flags: CGEventFlags
    public var display: String

    static let modifierNames: [String: (CGEventFlags, String)] = [
        "cmd": (.maskCommand, "⌘"), "command": (.maskCommand, "⌘"), "⌘": (.maskCommand, "⌘"),
        "shift": (.maskShift, "⇧"), "⇧": (.maskShift, "⇧"),
        "opt": (.maskAlternate, "⌥"), "option": (.maskAlternate, "⌥"), "alt": (.maskAlternate, "⌥"), "⌥": (.maskAlternate, "⌥"),
        "ctrl": (.maskControl, "⌃"), "control": (.maskControl, "⌃"), "⌃": (.maskControl, "⌃"),
        "fn": (.maskSecondaryFn, "fn "),
    ]

    /// Keys known by name, whose codes don't depend on the keyboard layout.
    static let namedKeys: [String: (CGKeyCode, String)] = {
        var table: [String: (CGKeyCode, String)] = [
            "return": (36, "↩"), "enter": (36, "↩"), "tab": (48, "⇥"), "space": (49, "Space"),
            "delete": (51, "⌫"), "backspace": (51, "⌫"), "esc": (53, "⎋"), "escape": (53, "⎋"),
            "forwarddelete": (117, "⌦"), "home": (115, "↖"), "end": (119, "↘"), "pageup": (116, "⇞"),
            "pagedown": (121, "⇟"), "left": (123, "←"), "right": (124, "→"), "down": (125, "↓"), "up": (126, "↑"),
        ]
        let functionKeys: [CGKeyCode] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        for (index, code) in functionKeys.enumerated() { table["f\(index + 1)"] = (code, "F\(index + 1)") }
        return table
    }()

    /// Parses `text`. A printable key goes where `layout` types its character, or to its US
    /// position when `layout` is nil or lacks the character.
    public static func parse(_ text: String, layout: KeyLayout? = nil) throws -> KeyCombo {
        var flags: CGEventFlags = []
        var prefix = ""
        var remaining = text.trimmingCharacters(in: .whitespaces)
        while let first = remaining.first, let (flag, symbol) = modifierNames[String(first)], remaining.count > 1 {
            flags.insert(flag)
            prefix += symbol
            remaining.removeFirst()
        }
        let parts = remaining.split(whereSeparator: { $0 == "+" || $0 == " " }).map { $0.lowercased() }
        guard let keyName = parts.last else {
            throw RPCError(code: RPCErrorCode.invalidParams, message: "Give a key, e.g. cmd+s, return or ⇧⌘S.")
        }
        for name in parts.dropLast() {
            guard let (flag, symbol) = modifierNames[name] else {
                throw RPCError(code: RPCErrorCode.invalidParams, message: "Unknown modifier \(name); use cmd, shift, opt or ctrl.")
            }
            flags.insert(flag)
            prefix += symbol
        }
        let order = ["⌃", "⌥", "⇧", "⌘"]
        let sorted = order.filter { prefix.contains($0) }.joined() + (prefix.contains("fn ") ? "fn " : "")
        if let (code, display) = namedKeys[keyName] {
            return KeyCombo(keyCode: code, flags: flags, display: sorted + display)
        }
        let command = flags.contains(.maskCommand)
        guard keyName.count == 1, let character = keyName.first,
              let key = layout?.key(for: character, command: command) ?? KeyLayout.us.key(for: character, command: command) else {
            throw RPCError(code: RPCErrorCode.invalidParams, message: "Unknown key \(keyName). Use a letter, digit, punctuation, return, tab, space, delete, esc, arrows, home, end, page keys or f1–f12.")
        }
        if key.shift { flags.insert(.maskShift) }
        let upper = keyName.uppercased()
        return KeyCombo(keyCode: key.code, flags: flags, display: sorted + (upper.count == 1 ? upper : keyName))
    }
}
