import Foundation
import HarnessProtocol

/// Typing and keys on Android through `adb shell input`.
enum AndroidInput {
    /// Android key codes by the names agents use (the same names as on the Mac where they mean the
    /// same thing).
    static let keys: [String: String] = {
        var table: [String: String] = [
            "return": "KEYCODE_ENTER", "enter": "KEYCODE_ENTER", "tab": "KEYCODE_TAB", "space": "KEYCODE_SPACE",
            "delete": "KEYCODE_DEL", "backspace": "KEYCODE_DEL", "forwarddelete": "KEYCODE_FORWARD_DEL",
            "esc": "KEYCODE_ESCAPE", "escape": "KEYCODE_ESCAPE", "home": "KEYCODE_MOVE_HOME", "end": "KEYCODE_MOVE_END",
            "pageup": "KEYCODE_PAGE_UP", "pagedown": "KEYCODE_PAGE_DOWN", "up": "KEYCODE_DPAD_UP", "down": "KEYCODE_DPAD_DOWN",
            "left": "KEYCODE_DPAD_LEFT", "right": "KEYCODE_DPAD_RIGHT", "back": "KEYCODE_BACK", "search": "KEYCODE_SEARCH",
            "menu": "KEYCODE_MENU",
        ]
        for letter in "abcdefghijklmnopqrstuvwxyz" { table[String(letter)] = "KEYCODE_\(letter.uppercased())" }
        for digit in 0...9 { table["\(digit)"] = "KEYCODE_\(digit)" }
        for number in 1...12 { table["f\(number)"] = "KEYCODE_F\(number)" }
        return table
    }()

    static let modifiers: [String: String] = [
        "ctrl": "KEYCODE_CTRL_LEFT", "control": "KEYCODE_CTRL_LEFT", "shift": "KEYCODE_SHIFT_LEFT",
        "alt": "KEYCODE_ALT_LEFT", "opt": "KEYCODE_ALT_LEFT", "option": "KEYCODE_ALT_LEFT",
        "cmd": "KEYCODE_META_LEFT", "command": "KEYCODE_META_LEFT", "meta": "KEYCODE_META_LEFT",
    ]

    /// The `input` command for a combination such as `enter`, `ctrl+a` or `back`.
    static func command(for combo: String) throws -> String {
        let parts = combo.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let last = parts.last, let key = keys[last] ?? (last.hasPrefix("keycode_") ? last.uppercased() : nil) else {
            throw RPCError(code: RPCErrorCode.invalidParams, message: "Unknown key “\(combo)”; use names like enter, tab, back, delete, up, ctrl+a, or an Android KEYCODE_….")
        }
        let held = try parts.dropLast().map { name -> String in
            guard let code = modifiers[name] else {
                throw RPCError(code: RPCErrorCode.invalidParams, message: "Unknown modifier \(name); use ctrl, shift, alt or meta.")
            }
            return code
        }
        return held.isEmpty ? "input keyevent \(key)" : "input keycombination \((held + [key]).joined(separator: " "))"
    }

    static func key(_ combo: String, screen: AndroidService.Screen) async throws {
        try await ADB.shell(screen.serial, try command(for: combo))
    }

    /// The characters `input text` can't type: anything outside printable ASCII except newlines and tabs.
    static func untypable(_ text: String) -> [Character] {
        var seen: [Character] = []
        for character in text where !(character.isASCII && (character.asciiValue! >= 32 || character == "\n" || character == "\t")) {
            if !seen.contains(character) { seen.append(character) }
        }
        return seen
    }

    /// Shell commands that type the text: runs of `input text`, with Enter and Tab as key events.
    static func commands(for text: String) -> [String] {
        var commands: [String] = []
        var run = ""
        func flush() {
            guard !run.isEmpty else { return }
            let escaped = run.replacingOccurrences(of: " ", with: "%s").replacingOccurrences(of: "'", with: "'\\''")
            commands.append("input text '\(escaped)'")
            run = ""
        }
        for character in text {
            switch character {
            case "\n":
                flush()
                commands.append("input keyevent KEYCODE_ENTER")
            case "\t":
                flush()
                commands.append("input keyevent KEYCODE_TAB")
            default:
                run.append(character)
                if run.count >= 120 { flush() }
            }
        }
        flush()
        return commands
    }

    static func type(_ text: String, screen: AndroidService.Screen) async throws {
        let missing = untypable(text)
        guard missing.isEmpty else {
            throw RPCError(
                code: RPCErrorCode.invalidParams,
                message: "adb can only type plain ASCII, so \(missing.prefix(5).map { "“\($0)”" }.joined(separator: ", ")) can't be typed on \(screen.device.name)."
            )
        }
        for command in commands(for: text) {
            try await ADB.shell(screen.serial, command, timeout: 60)
        }
    }
}
