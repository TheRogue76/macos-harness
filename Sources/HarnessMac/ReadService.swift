import ApplicationServices
import CoreGraphics
import Foundation
import HarnessCore
import HarnessProtocol

/// Reads one element in full, or the whole window: its whole label and value, the text inside it
/// in reading order, and the links inside it.
public enum ReadService {
    /// Most characters of value or text a read returns.
    static let limit = 100_000

    public static func read(_ params: ReadMethod.Params) async throws -> ReadMethod.Result {
        if params.target.androidDevice != nil { return try await AndroidService.read(params) }
        if params.element?.ocr == true {
            throw RPCError(code: RPCErrorCode.invalidParams, message: "Text found by OCR has no element to read; `find --ocr` lists every line it reads.")
        }
        let (app, window) = try await TargetResolver.resolve(TargetResolver.target(params.target, holding: params.element?.ref))
        let treeNotice = try await Snapshotter.prepare(window, app: app)
        var element = window.content
        var visible: CGRect?
        if let selector = params.element, !selector.isEmpty {
            let resolved = if window.isSimulator, selector.ref == nil {
                try await SimulatorScrolling.reveal(selector, window: window, app: app, deadline: Date().addingTimeInterval(SimulatorScrolling.budget))
            } else {
                try await ElementResolver.resolve(selector, window: window, app: app, allowFocused: false)
            }
            element = resolved.element
            visible = resolved.visible
        }
        AX.setTimeout(element, seconds: window.isSimulator ? 8 : 2)
        let raw = AXReader(maxNodes: 5000, maxDepth: 80, timeBudget: 5, valueLimit: limit).read(element)
        var shaper = TreeShaper(space: window.space, maxNodes: 1, maxDepth: 0, ref: Snapshotter.registrar(for: app))
        shaper.links = true
        let notices = await Notices.collect(for: window.info) + [treeNotice].compactMap { $0 }
        return result(raw, node: shaper.makeNode(raw, visible: visible), app: app, window: window.info, ref: shaper.ref, notices: notices)
    }

    /// The result of reading `raw`, for Mac windows, simulators and Android screens alike.
    static func result(
        _ raw: RawNode, node: UINode, app: AppRef, window: WindowInfo, ref: (RawNode) -> String, notices: [Notice]
    ) -> ReadMethod.Result {
        var notices = notices
        var text = ReadText.text(of: raw)
        if text.count > limit {
            text = String(text.prefix(limit)) + "…"
            notices.append(Notice(kind: "truncated", message: "The text is longer than \(limit) characters, so it was cut; read a smaller element."))
        }
        if ReadText.unread(in: raw) > 0 {
            notices.append(Notice(kind: "truncated", message: "Some elements inside weren't read in time; read the parts separately."))
        }
        let own = [node.label, node.value].compactMap { $0 }
        let links = ReadText.links(in: raw).map { ReadMethod.Link(ref: ref($0.node), label: $0.label, url: $0.url) }
        return ReadMethod.Result(
            app: app, window: window, element: node, text: text.isEmpty || own.contains(text) ? nil : text, links: links, notices: notices
        )
    }
}

/// The text inside an element in reading order, and the links inside it.
enum ReadText {
    /// Roles whose text runs on in the same line as their neighbours'.
    static let inlineRoles: Set<String> = ["AXStaticText", "AXLink", "AXImage"]
    /// Roles whose text is what the user typed into them, their value.
    static let inputRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    private enum Piece {
        case text(String)
        case lineBreak
    }

    /// All the text inside `node`, in reading order: inline text joined into lines, a line per
    /// block. A container's own label counts only when nothing inside it has text, so labels
    /// that repeat their contents aren't read twice.
    static func text(of node: RawNode) -> String {
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
    static func ownText(_ node: RawNode) -> String? {
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
    static func join(_ line: String, _ text: String) -> String {
        guard let last = line.last, let first = text.first else { return line + text }
        if last.isWhitespace || first.isWhitespace || ".,;:!?)]}’”%".contains(first) || "([{‘“".contains(last) {
            return line + text
        }
        return line + " " + text
    }

    /// The links inside `node`, in reading order, each label and target once.
    static func links(in node: RawNode) -> [(node: RawNode, label: String?, url: String)] {
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
    static func unread(in node: RawNode) -> Int {
        node.unread + node.children.reduce(0) { $0 + unread(in: $1) }
    }
}
