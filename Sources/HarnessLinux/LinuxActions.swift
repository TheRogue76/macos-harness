#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import HarnessCore
import HarnessDBus
import HarnessProtocol

/// Actions on Linux desktop apps' elements through AT-SPI, without the mouse or keyboard.
extension LinuxDesktop {
    static let realInputLater = "needs real keyboard input, which Linux desktop apps don't have yet"

    public static func act(_ params: ActMethod.Params, context: ActionContext) async throws -> ActionResult {
        if params.element?.ocr == true {
            throw RPCError(code: RPCErrorCode.invalidParams, message: "Text found by OCR isn't an element; Linux desktop apps can't be clicked by position yet.")
        }
        if params.action == .key || params.action == .paste {
            throw RPCError(code: RPCErrorCode.failed, message: "`\(params.action.rawValue)` \(realInputLater); use type or set-value.")
        }
        let place = try await place(params.target)
        try await context.claim(WindowClaims.key(window: place.info.id), place: "\(place.ref.name)'s window “\(place.info.title)”")
        let before = try await tree(of: place, limit: 4000)
        let target = try await element(params.element, in: place, tree: before, allowFocused: params.action == .type)
        guard let key = target.key?.base as? ATSPIKey, let item = place.items.first(where: { $0.path == key.path }) else {
            throw RPCError(code: RPCErrorCode.failed, message: "That element is no longer in \(place.ref.name); take a new snapshot.")
        }
        let shaper = TreeShaper(window: place.frame, maxNodes: 1, maxDepth: 0, ref: registrar(place))
        let node = shaper.makeNode(target, visible: target.frame?.intersection(place.frame))
        let name = ActionService.describe(node)
        let needsEnabled: Set<ElementAction> = [.press, .setValue, .select, .type, .increment, .decrement]
        if needsEnabled.contains(params.action), target.enabled == false {
            throw RPCError(code: RPCErrorCode.disabled, message: "\(name) is disabled, so nothing happened.")
        }
        let element = Element(bus: place.app.bus, item: item, connection: place.connection, name: name)
        let performed: String
        switch params.action {
        case .press:
            try await element.doAction("AXPress")
            performed = "pressed \(name)"
        case .focus:
            try await element.focus()
            performed = "focused \(name)"
        case .select:
            if let parent = place.items.first(where: { $0.path == item.parent }), parent.interfaces.contains(Element.selection), item.index >= 0 {
                let done = try await element.connection.call(
                    element.bus, parent.path, Element.selection, "SelectChild", [.int32(Int32(item.index))], timeout: ATSPI.timeout
                ).first?.bool
                guard done == true else { throw RPCError(code: RPCErrorCode.failed, message: "\(name) couldn't be selected.") }
            } else {
                try await element.doAction("AXPress")
            }
            performed = "selected \(name)"
        case .setValue:
            let value = try ActionService.required(params.value, "set-value needs a value")
            performed = try await element.setValue(value, current: target)
        case .increment, .decrement:
            let steps = max(params.count, 1) * (params.action == .increment ? 1 : -1)
            performed = try await element.step(by: steps)
        case .scrollTo:
            if let frame = target.frame, place.frame.contains(frame) {
                performed = "\(name) was already in view"
            } else {
                try await element.scrollIntoView()
                performed = "scrolled \(name) into view"
            }
        case .type:
            let text = try ActionService.required(params.value, "type needs text")
            try await element.insert(text)
            performed = "typed “\(text.count > 40 ? String(text.prefix(40)) + "…" : text)” into \(name)"
        case .key, .paste:
            throw RPCError(code: RPCErrorCode.failed, message: "`\(params.action.rawValue)` \(realInputLater).")
        }
        var notices: [Notice] = []
        if params.action == .setValue || params.action == .type, target.subrole == "AXSecureTextField" {
            notices.append(Notice(kind: "secure", message: "That's a password field; what was typed isn't shown."))
        }
        var result = ActionResult(app: place.ref, window: place.info, element: node, performed: performed, via: "at-spi", notices: notices)
        if params.diff { await settle(&result, before: before, place: place) }
        return result
    }

    /// The element a selector names, or the focused one when there's no selector and that's allowed.
    static func element(_ selector: ElementSelector?, in place: Place, tree: RawNode, allowFocused: Bool) async throws -> RawNode {
        if let selector, !selector.isEmpty { return try await resolve(selector, in: place, tree: tree) }
        guard allowFocused else {
            throw RPCError(code: RPCErrorCode.invalidParams, message: "Say which element: a ref, or --text, --role or --id.")
        }
        func first(_ node: RawNode, _ matches: (RawNode) -> Bool) -> RawNode? {
            if matches(node) { return node }
            for child in node.children {
                if let found = first(child, matches) { return found }
            }
            return nil
        }
        guard let focused = first(tree, { $0.focused == true && ($0.role == "AXTextField" || $0.role == "AXTextArea") })
            ?? first(tree, { $0.focused == true }) else {
            throw RPCError(code: RPCErrorCode.failed, message: "Nothing in \(place.ref.name)'s window has focus; name the field with a ref or --text.")
        }
        return focused
    }

    /// Waits for the window to settle after an action and reports what changed.
    static func settle(_ result: inout ActionResult, before: RawNode, place: Place) async {
        let started = Date()
        try? await Task.sleep(for: .milliseconds(300))
        guard let items = try? await ATSPI.items(of: place.app.bus, on: place.connection) else { return }
        var after = place
        after.items = items
        guard let tree = try? await tree(of: after, limit: 4000) else { return }
        result.settledMilliseconds = Int(Date().timeIntervalSince(started) * 1000)
        let changes = Settle.diff(before: flatten(before, place: place), after: flatten(tree, place: place))
        result.changes = Array(changes.prefix(40))
        result.moreChanges = max(0, changes.count - 40)
    }

    static func flatten(_ tree: RawNode, place: Place) -> [(ref: String, node: UINode)] {
        let shaped = TreeShaper(window: place.frame, maxNodes: 400, maxDepth: 40, ref: registrar(place)).shape(tree)
        var nodes: [(String, UINode)] = []
        func visit(_ node: UINode) {
            var copy = node
            copy.children = []
            copy.omitted = 0
            nodes.append((node.ref, copy))
            node.children.forEach(visit)
        }
        visit(shaped.root)
        return nodes
    }

    /// One element and the AT-SPI calls that act on it.
    struct Element {
        static let action = "org.a11y.atspi.Action"
        static let component = "org.a11y.atspi.Component"
        static let value = "org.a11y.atspi.Value"
        static let text = "org.a11y.atspi.Text"
        static let editableText = "org.a11y.atspi.EditableText"
        static let selection = "org.a11y.atspi.Selection"

        var bus: String
        var item: ATSPIItem
        var connection: DBusConnection
        var name: String

        func call(_ interface: String, _ member: String, _ arguments: [DBusValue] = []) async throws -> [DBusValue] {
            try await connection.call(bus, item.path, interface, member, arguments, timeout: ATSPI.timeout)
        }

        func property(_ interface: String, _ property: String) async throws -> DBusValue {
            try await connection.property(bus, item.path, interface, property, timeout: ATSPI.timeout)
        }

        func setProperty(_ interface: String, _ property: String, _ value: DBusValue) async throws {
            _ = try await connection.call(
                bus, item.path, "org.freedesktop.DBus.Properties", "Set", [.string(interface), .string(property), .variant(value)],
                timeout: ATSPI.timeout
            )
        }

        /// Performs the element's action that means `wanted`, or its first action for a press.
        func doAction(_ wanted: String) async throws {
            guard item.interfaces.contains(Self.action) else {
                throw RPCError(code: RPCErrorCode.failed, message: "\(name) has no actions to perform; it may not be pressable.")
            }
            let names = (try await call(Self.action, "GetActions").first?.elements ?? []).map { $0.fields?.first?.string ?? "" }
            let index = names.firstIndex { !$0.contains(".") && ATSPIRoles.action($0) == wanted }
                ?? (wanted == "AXPress" ? names.firstIndex { !$0.isEmpty && !$0.contains(".") } : nil)
            guard let index else {
                throw RPCError(code: RPCErrorCode.failed, message: "\(name) has no \(wanted == "AXPress" ? "press" : wanted) action.")
            }
            let done = try await call(Self.action, "DoAction", [.int32(Int32(index))]).first?.bool
            guard done != false else { throw RPCError(code: RPCErrorCode.failed, message: "\(name) refused the action.") }
        }

        /// Gives the element keyboard focus, or for text whose toolkit can't grab focus (GTK 4),
        /// puts the caret at its end.
        func focus() async throws {
            if item.interfaces.contains(Self.component), (try? await call(Self.component, "GrabFocus").first?.bool) == true { return }
            if item.interfaces.contains(Self.text) {
                let end = (try? await property(Self.text, "CharacterCount").int) ?? 0
                if (try? await call(Self.text, "SetCaretOffset", [.int32(Int32(end))]).first?.bool) == true { return }
            }
            throw RPCError(code: RPCErrorCode.failed, message: "\(name)'s app doesn't let it take focus on request.")
        }

        func scrollIntoView() async throws {
            guard item.interfaces.contains(Self.component) else {
                throw RPCError(code: RPCErrorCode.failed, message: "\(name) can't be scrolled to; scroll its list instead.")
            }
            let done = try? await call(Self.component, "ScrollTo", [.uint32(6)]).first?.bool
            guard done == true else {
                throw RPCError(code: RPCErrorCode.failed, message: "\(item.name.isEmpty ? name : name)'s app doesn't scroll elements into view on request.")
            }
        }

        func setValue(_ value: String, current: RawNode) async throws -> String {
            if ATSPIRoles.checkable.contains(item.role) {
                let on = ["1", "on", "true", "yes", "checked"].contains(value.lowercased())
                if (current.value == "1") != on { try await doAction("AXPress") }
                return "set \(name) to \(on ? "on" : "off")"
            }
            if item.interfaces.contains(Self.editableText) {
                let done = try await call(Self.editableText, "SetTextContents", [.string(value)]).first?.bool
                guard done != false else { throw RPCError(code: RPCErrorCode.failed, message: "\(name) refused the text.") }
                return "set \(name) to “\(value)”"
            }
            if item.interfaces.contains(Self.value) {
                guard let number = Double(value) else {
                    throw RPCError(code: RPCErrorCode.invalidParams, message: "\(name) takes a number.")
                }
                try await setProperty(Self.value, "CurrentValue", .double(try await clamped(number)))
                return "set \(name) to \(value)"
            }
            throw RPCError(code: RPCErrorCode.failed, message: "\(name)'s value can't be set; press it or type into it instead.")
        }

        func step(by steps: Int) async throws -> String {
            guard item.interfaces.contains(Self.value) else {
                let wanted = steps > 0 ? "AXIncrement" : "AXDecrement"
                for _ in 0..<abs(steps) { try await doAction(wanted) }
                return "\(steps > 0 ? "incremented" : "decremented") \(name)"
            }
            let current = try await property(Self.value, "CurrentValue").double ?? 0
            let increment = try? await property(Self.value, "MinimumIncrement").double
            let step = (increment ?? 0) > 0 ? increment! : 1
            let target = try await clamped(current + Double(steps) * step)
            try await setProperty(Self.value, "CurrentValue", .double(target))
            let shown = target.rounded() == target ? String(Int(target)) : String(target)
            return "\(steps > 0 ? "incremented" : "decremented") \(name) to \(shown)"
        }

        func clamped(_ number: Double) async throws -> Double {
            let low = try? await property(Self.value, "MinimumValue").double
            let high = try? await property(Self.value, "MaximumValue").double
            return min(max(number, low ?? -.infinity), high ?? .infinity)
        }

        /// Inserts text at the caret, or at the end when there's no caret.
        func insert(_ text: String) async throws {
            guard item.interfaces.contains(Self.editableText) else {
                throw RPCError(code: RPCErrorCode.failed, message: "\(name) doesn't take text; \(LinuxDesktop.realInputLater) for other elements.")
            }
            var position = (try? await property(Self.text, "CaretOffset").int) ?? -1
            if position < 0 { position = (try? await property(Self.text, "CharacterCount").int) ?? 0 }
            let done = try await call(
                Self.editableText, "InsertText", [.int32(Int32(position)), .string(text), .int32(Int32(text.count))]
            ).first?.bool
            guard done != false else { throw RPCError(code: RPCErrorCode.failed, message: "\(name) refused the text.") }
        }
    }
}

extension LinuxDesktop {
    /// `wait` on a desktop app: until an element appears, or goes away, in the window the target
    /// names, read again each time so a dialog that opens and takes focus is searched too.
    public static func wait(_ params: WaitMethod.Params) async throws -> WaitMethod.Result {
        guard params.element.ocr != true else {
            throw RPCError(code: RPCErrorCode.failed, message: "Text recognition on Linux desktop apps needs screenshots, which aren't supported yet.")
        }
        let started = Date()
        var window: WindowInfo?
        repeat {
            let place = try await place(params.target)
            window = place.info
            var found: UINode?
            if let raw = try? await tree(of: place, limit: 8000) {
                let shaper = TreeShaper(window: place.frame, maxNodes: 1, maxDepth: 0, ref: registrar(place))
                if params.element.ref != nil {
                    found = (try? await resolve(params.element, in: place, tree: raw)).map { shaper.makeNode($0, visible: $0.frame) }
                } else if let hit = ElementSearch.search(raw, for: params.element, clip: place.frame, limit: 1).first {
                    found = shaper.makeNode(hit.raw, visible: hit.visible)
                }
            }
            if params.gone ? found == nil : found != nil {
                return WaitMethod.Result(satisfied: true, node: found, window: place.info, milliseconds: Int(Date().timeIntervalSince(started) * 1000))
            }
            try await Task.sleep(for: .milliseconds(250))
        } while Date().timeIntervalSince(started) < params.timeout
        return WaitMethod.Result(satisfied: false, node: nil, window: window, milliseconds: Int(Date().timeIntervalSince(started) * 1000))
    }
}
