#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import HarnessProtocol

/// The text inside an element in reading order, and the links inside it.
package enum ReadText {
    /// Roles whose text runs on in the same line as their neighbours'.
    package static let inlineRoles: Set<String> = ["AXStaticText", "AXLink", "AXImage"]
    /// Roles whose text is what the user typed into them, their value.
    package static let inputRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    private enum Piece {
        case text(String)
        case lineBreak
    }

    /// All the text inside `node`, in reading order: inline text joined into lines, a line per
    /// block. A container's own label counts only when nothing inside it has text, so labels
    /// that repeat their contents aren't read twice.
    package static func text(of node: RawNode) -> String {
        var lines: [String] = []
        var line = ""
        func flush() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { lines.append(trimmed) }
            line = ""
        }
        for piece in pieces(node) {
            switch piece {
            case .lineBreak: flush()
            case .text(let text): line = join(line, text)
            }
        }
        flush()
        return lines.joined(separator: "\n")
    }

    private static func pieces(_ node: RawNode) -> [Piece] {
        guard node.windowButtonName == nil else { return [] }
        let inner = node.children.flatMap(pieces)
        let content: [Piece]
        if inner.contains(where: { if case .text = $0 { true } else { false } }) {
            content = inner
        } else if let own = ownText(node) {
            content = [.text(own)]
        } else {
            return []
        }
        return inlineRoles.contains(node.role) ? content : [.lineBreak] + content + [.lineBreak]
    }

    /// The element's own text: what's typed into an input, a static text's text, otherwise its label.
    package static func ownText(_ node: RawNode) -> String? {
        let text: String?
        if inputRoles.contains(node.role) {
            text = node.value == node.placeholder ? nil : node.value
        } else if node.role == "AXStaticText" {
            text = node.value ?? node.label
        } else {
            text = node.label
        }
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// `line` and `text` with a space between, unless punctuation or brackets make it unnatural.
    package static func join(_ line: String, _ text: String) -> String {
        guard let last = line.last, let first = text.first else { return line + text }
        if last.isWhitespace || first.isWhitespace || ".,;:!?)]}’”%".contains(first) || "([{‘“".contains(last) {
            return line + text
        }
        return line + " " + text
    }

    /// The links inside `node`, in reading order, each label and target once.
    package static func links(in node: RawNode) -> [(node: RawNode, label: String?, url: String)] {
        var found: [(node: RawNode, label: String?, url: String)] = []
        var seen = Set<String>()
        func visit(_ element: RawNode) {
            if element.role == "AXLink", let url = element.url {
                let inner = text(of: element)
                let label = element.label ?? (inner.isEmpty ? nil : inner)
                if seen.insert((label ?? "") + "\u{0}" + url).inserted { found.append((element, label, url)) }
            }
            element.children.forEach(visit)
        }
        node.children.forEach(visit)
        return found
    }

    /// Elements inside `node` that weren't read because a limit was reached.
    package static func unread(in node: RawNode) -> Int {
        node.unread + node.children.reduce(0) { $0 + unread(in: $1) }
    }
}