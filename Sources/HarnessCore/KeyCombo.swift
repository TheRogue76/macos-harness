import CoreGraphics
import Foundation
import HarnessProtocol

/// A key plus modifiers, parsed from text like "cmd+shift+s", "⌘S" or "return".
///
/// Key codes are for the US ANSI layout; on other layouts letter shortcuts may land on a
/// different key. Typing text doesn't have this problem (it sends characters).
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

    static let keys: [String: (CGKeyCode, String)] = {
        var table: [String: (CGKeyCode, String)] = [
            "return": (36, "↩"), "enter": (36, "↩"), "tab": (48, "⇥"), "space": (49, "Space"),
            "delete": (51, "⌫"), "backspace": (51, "⌫"), "esc": (53, "⎋"), "escape": (53, "⎋"),
            "forwarddelete": (117, "⌦"), "home": (115, "↖"), "end": (119, "↘"), "pageup": (116, "⇞"),
            "pagedown": (121, "⇟"), "left": (123, "←"), "right": (124, "→"), "down": (125, "↓"), "up": (126, "↑"),
        ]
        let printable: [(String, CGKeyCode)] = [
            ("a", 0), ("s", 1), ("d", 2), ("f", 3), ("h", 4), ("g", 5), ("z", 6), ("x", 7), ("c", 8), ("v", 9),
            ("b", 11), ("q", 12), ("w", 13), ("e", 14), ("r", 15), ("y", 16), ("t", 17), ("1", 18), ("2", 19),
            ("3", 20), ("4", 21), ("6", 22), ("5", 23), ("=", 24), ("9", 25), ("7", 26), ("-", 27), ("8", 28),
            ("0", 29), ("]", 30), ("o", 31), ("u", 32), ("[", 33), ("i", 34), ("p", 35), ("l", 37), ("j", 38),
            ("'", 39), ("k", 40), (";", 41), ("\\", 42), (",", 43), ("/", 44), ("n", 45), ("m", 46), (".", 47),
            ("`", 50),
        ]
        for (name, code) in printable { table[name] = (code, name.uppercased()) }
        let functionKeys: [CGKeyCode] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        for (index, code) in functionKeys.enumerated() { table["f\(index + 1)"] = (code, "F\(index + 1)") }
        return table
    }()

    public static func parse(_ text: String) throws -> KeyCombo {
        var flags: CGEventFlags = []
        var prefix = ""
        var remaining = text.trimmingCharacters(in: .whitespaces)
        // Leading symbol modifiers without separators, e.g. "⇧⌘S".
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
        guard let (code, display) = keys[keyName] else {
            throw RPCError(code: RPCErrorCode.invalidParams, message: "Unknown key \(keyName). Use a letter, digit, punctuation, return, tab, space, delete, esc, arrows, home, end, page keys or f1–f12.")
        }
        // Show modifiers in Apple's order: ⌃⌥⇧⌘.
        let order = ["⌃", "⌥", "⇧", "⌘"]
        let sorted = order.filter { prefix.contains($0) }.joined() + (prefix.contains("fn ") ? "fn " : "")
        return KeyCombo(keyCode: code, flags: flags, display: sorted + display)
    }
}
