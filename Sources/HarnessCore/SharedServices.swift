#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import HarnessProtocol

/// Actions on one element: press, set-value, focus, select, increment, decrement, scroll-to, type
/// and key.
public enum ActionService {
    package static func describe(_ node: UINode) -> String {
        let role = node.role.hasPrefix("AX") ? String(node.role.dropFirst(2)).lowercased() : node.role
        let label = node.label ?? node.value ?? node.identifier
        return "\(role)\(label.map { " “\($0.prefix(50))”" } ?? "") (\(node.ref))"
    }

    package static func required(_ value: String?, _ message: String) throws -> String {
        guard let value else { throw RPCError(code: RPCErrorCode.invalidParams, message: message) }
        return value
    }
}

/// Waiting for the UI to stop changing after an action, and describing what changed.
package enum Settle {
    /// Roles whose values change by themselves, left out of `contents`.
    package static let restlessRoles: Set<String> = ["AXScrollBar", "AXValueIndicator", "AXProgressIndicator", "AXBusyIndicator"]

    /// The content and state of every element in `raw` with any content (empty containers come and
    /// go), sorted, or nil when the read was cut short.
    package static func contents(of raw: RawNode) -> [String]? {
        var lines: [String] = []
        var complete = true
        func visit(_ node: RawNode) {
            if node.unread > 0 { complete = false }
            let content = [node.title, node.details, node.value, node.identifier].contains { $0 != nil }
            if content, !restlessRoles.contains(node.role) {
                lines.append(
                    "\(node.role)|\(node.title ?? "")|\(node.details ?? "")|\(node.value ?? "")|\(node.identifier ?? "")|\(node.enabled ?? true)|\(node.selected ?? false)"
                )
            }
            node.children.forEach(visit)
        }
        visit(raw)
        return complete ? lines.sorted() : nil
    }

    /// Whether a window is small and untitled enough to be a tooltip, or a strip like Chrome's
    /// link status bubble.
    package static func isMinor(_ window: WindowInfo) -> Bool {
        window.title.isEmpty && (window.frame.height < 50 || (window.frame.width < 150 && window.frame.height < 150))
    }

    /// Changes with each removed element that came back as a new element with the same identifier
    /// and role (iOS replaces elements whose text changes) reported as one change.
    package static func pairReplacements(_ changes: [UIChange]) -> [UIChange] {
        func unique(_ kind: String) -> Set<String> {
            let identifiers = changes.filter { $0.kind == kind }.compactMap(\.node.identifier)
            return Set(identifiers.filter { identifier in identifiers.filter { $0 == identifier }.count == 1 })
        }
        let pairable = unique("removed").intersection(unique("added"))
        var removed = changes.filter { $0.kind == "removed" && $0.node.identifier.map(pairable.contains) == true }
        var result: [UIChange] = []
        for change in changes where change.kind != "removed" || change.node.identifier.map(pairable.contains) != true {
            guard change.kind == "added", let identifier = change.node.identifier,
                  let index = removed.firstIndex(where: { $0.node.identifier == identifier && $0.node.role == change.node.role }) else {
                result.append(change)
                continue
            }
            let previous = removed.remove(at: index).node
            if previous.label != change.node.label || previous.value != change.node.value || previous.enabled != change.node.enabled
                || previous.focused != change.node.focused || previous.selected != change.node.selected {
                result.append(UIChange(kind: "changed", node: change.node, before: previous))
            }
        }
        return result + removed
    }

    package static func diff(before: [(ref: String, node: UINode)], after: [(ref: String, node: UINode)]) -> [UIChange] {
        let old = Dictionary(before.map { ($0.ref, $0.node) }, uniquingKeysWith: { first, _ in first })
        let new = Dictionary(after.map { ($0.ref, $0.node) }, uniquingKeysWith: { first, _ in first })
        var changes: [UIChange] = []
        for (ref, node) in after {
            if let previous = old[ref] {
                if node.role == "AXMenuItem", previous.label == node.label, previous.enabled == node.enabled { continue }
                if previous.label != node.label || previous.value != node.value || previous.enabled != node.enabled
                    || previous.focused != node.focused || previous.selected != node.selected {
                    changes.append(UIChange(kind: "changed", node: node, before: previous))
                }
            } else {
                changes.append(UIChange(kind: "added", node: node))
            }
        }
        for (ref, node) in before where new[ref] == nil && node.role != "AXMenuItem" {
            changes.append(UIChange(kind: "removed", node: node))
        }
        return pairReplacements(changes)
    }
}

/// Reads one element in full, or the whole window: its whole label and value, the text inside it
/// in reading order, and the links inside it.
public enum ReadService {
    /// Most characters of value or text a read returns.
    package static let limit = 100_000

    /// The result of reading `raw`, for Mac windows, simulators and Android screens alike.
    package static func result(
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

/// `collect`: every item of a list that shows only part of itself at a time, scrolled through
/// without the real mouse, each item once.
public enum CollectService {
    /// Most items one call returns.
    package static let ceiling = 500

    /// Refuses items named by a ref or OCR text, which can't repeat down a list.
    package static func check(_ params: CollectMethod.Params) throws {
        guard !params.item.isEmpty, params.item.ref == nil, params.item.ocr != true else {
            throw RPCError(
                code: RPCErrorCode.invalidParams,
                message: "Say which elements are the items with a role (article, row, cell…), text or an identifier, not a ref."
            )
        }
    }

    /// The collector for a call, carrying on from what this session already got when asked.
    package static func collector(_ params: CollectMethod.Params, memory: String) async throws -> Collector {
        let seen: Set<String> = params.continue == true ? await CollectMemory.shared.seen(memory) : []
        return Collector(
            selector: params.item, key: params.key, max: min(max(params.max, 1), ceiling), until: params.until,
            deadline: Date().addingTimeInterval(max(params.maxSeconds, 1)), seen: seen
        )
    }

    /// The result for what the collector found, with refs for the items and their links.
    package static func result(
        _ outcome: (items: [Collector.Found], stop: Collector.Stop), app: AppRef, window: WindowInfo, ref: (RawNode) -> String,
        notices: [Notice]
    ) -> CollectMethod.Result {
        let items = outcome.items.map { found in
            CollectMethod.Item(
                ref: ref(found.raw), text: found.text,
                links: found.links.map { ReadMethod.Link(ref: ref($0.node), label: $0.label, url: $0.url) }
            )
        }
        return CollectMethod.Result(app: app, window: window, items: items, stopped: outcome.stop.rawValue, notices: notices)
    }
}

/// Real mouse actions: click, double-click, right-click, hover, drag, scroll.
public enum PointerService {
    /// Why a drag can't leave or enter an Android device's screen.
    package static let androidCrossing = "A drag can't go between an Android device and a Mac window or iOS Simulator; both ends must be on the same device's screen."

    /// Why a drag can't go from one window to the other, or nil when it can: both are Mac windows,
    /// or both are the same simulator's or Android device's screen.
    package static func crossingRefusal(from source: WindowInfo, to destination: WindowInfo) -> String? {
        switch (source.android, destination.android) {
        case (nil, nil):
            break
        case let (from?, to?):
            return from.serial == to.serial ? nil : "A drag can't go from one Android device to another; both ends must be on the same screen."
        default:
            return androidCrossing
        }
        switch (source.simulator, destination.simulator) {
        case (nil, nil):
            return nil
        case let (from?, to?):
            return from.udid == to.udid ? nil : "A drag can't go from one simulator to another; both ends must be on the same simulator's screen."
        default:
            return "A drag can't go between a Mac window and an iOS Simulator's screen; drag within the simulator, or between Mac windows."
        }
    }
}
