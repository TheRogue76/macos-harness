import Foundation
import HarnessProtocol

/// Checks that text typed or pasted into a field shows up in the field's value afterwards.
package enum TypedText {
    /// The characters of `typed` that `value` doesn't have, each once, in typing order; nil when
    /// nothing is missing, ignoring case, spaces and reformatting, or when `typed` has returns or
    /// tabs, which act as keys.
    package static func missing(_ typed: String, from value: String) -> String? {
        guard !typed.contains(where: { $0.isNewline || $0 == "\t" }) else { return nil }
        var missing = ""
        for character in typed where !character.isWhitespace && !missing.contains(character) {
            if value.range(of: String(character), options: .caseInsensitive) == nil {
                missing.append(character)
            }
        }
        return missing.isEmpty ? nil : missing
    }

    /// A notice when `field` reads `value` after `typed` went in (by pasting when `pasted`) and
    /// some of its characters aren't there.
    package static func notice(typed: String, pasted: Bool = false, field: String, value: String) -> Notice? {
        guard let missing = missing(typed, from: value) else { return nil }
        let shown = value.count > 60 ? String(value.prefix(60)) + "…" : value
        let hint = pasted ? "" : "; if they belong there, `paste` puts text in through the clipboard"
        return Notice(
            kind: "typedTextMissing",
            message: "After \(pasted ? "pasting" : "typing"), \(field) reads “\(shown)”, without “\(missing)”. The app may have dropped or filtered those characters\(hint)."
        )
    }
}
