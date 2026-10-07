import AppKit
import ApplicationServices
import Foundation
import HarnessProtocol

/// The element an action targets, read fresh.
struct ResolvedElement {
    var element: AXUIElement
    var raw: RawNode
    var visible: CGRect?
}

enum ElementResolver {
    /// A ref, a selector, or (when allowed) the app's focused element.
    static func resolve(
        _ selector: ElementSelector?, window: WindowService.Window, app: AppRef, allowFocused: Bool
    ) throws -> ResolvedElement {
        let clip = window.info.frame.cgRect
        if let ref = selector?.ref {
            let element = try Snapshotter.element(for: ref, app: app)
            return single(element, clip: clip)
        }
        if let selector, !selector.isEmpty {
            let raw = AXReader(maxNodes: 8000, maxDepth: 80, timeBudget: 5).read(window.element)
            var hits = ElementSearch.search(raw, for: selector, clip: clip, limit: 60)
            if hits.isEmpty {
                hits = openMenuHits(selector, app: app)
            }
            let registrar = Snapshotter.registrar(for: app)
            let hit = try ElementSearch.single(hits, selector: selector) { hit in
                let label = hit.raw.label ?? hit.raw.value ?? ""
                let place = hit.visible == nil ? " (not visible)" : ""
                return "\(registrar(hit.raw)) \(hit.raw.role.dropFirst(2).lowercased()) \"\(label.prefix(40))\"\(place)"
            }
            guard let element = hit.raw.element else {
                throw RPCError(code: RPCErrorCode.internalError, message: "matched element has no AX handle")
            }
            return ResolvedElement(element: element, raw: hit.raw, visible: hit.visible)
        }
        guard allowFocused else {
            throw RPCError(code: RPCErrorCode.invalidParams, message: "Say which element: a ref, or --text, --role or --id.")
        }
        let appElement = AX.application(app.pid)
        guard let focused = AX.element(appElement, "AXFocusedUIElement") else {
            throw RPCError(code: RPCErrorCode.failed, message: "\(app.name) has no focused element; name one with a ref or --text.")
        }
        if let owner = AX.element(focused, "AXWindow"), !CFEqual(owner, window.element) {
            let other = AX.string(owner, "AXTitle") ?? "another window"
            throw RPCError(
                code: RPCErrorCode.failed,
                message: "\(app.name)'s focused element is in “\(other)”, not in window \(window.info.id) “\(window.info.title)”. Pass --into a ref from that window, or activate it first."
            )
        }
        return single(focused, clip: clip)
    }

    /// Matches in the app's open menus (context menus aren't part of any window).
    static func openMenuHits(_ selector: ElementSelector, app: AppRef) -> [ElementSearch.Hit] {
        let everywhere = CGRect(x: -1_000_000, y: -1_000_000, width: 2_000_000, height: 2_000_000)
        return AX.children(AX.application(app.pid)).filter { AX.role($0) == "AXMenu" }.flatMap { menu in
            ElementSearch.search(AXReader(maxNodes: 400, maxDepth: 4, timeBudget: 1).read(menu), for: selector, clip: everywhere, limit: 60)
        }
    }

    static func single(_ element: AXUIElement, clip: CGRect) -> ResolvedElement {
        var raw = AXReader(maxNodes: 1, maxDepth: 0).read(element)
        raw.children = []
        return ResolvedElement(element: element, raw: raw, visible: visibleFrame(element, frame: raw.frame, clip: clip))
    }

    /// The part of `frame` not clipped by the window or any scroll area around the element.
    static func visibleFrame(_ element: AXUIElement, frame: CGRect?, clip: CGRect) -> CGRect? {
        guard var visible = frame?.visiblePart(in: clip) else { return nil }
        var current = AX.element(element, "AXParent")
        while let node = current, AX.role(node) != "AXWindow" {
            if AX.role(node) == "AXScrollArea", let area = AX.frame(node) {
                guard let inside = visible.visiblePart(in: area) else { return nil }
                visible = inside
            }
            current = AX.element(node, "AXParent")
        }
        return visible
    }
}

/// Actions on one element: press, set-value, focus, select, increment, decrement, scroll-to, type
/// and key.
public enum ActionService {
    public static func act(_ params: ActMethod.Params) async throws -> ActionResult {
        try await act(params, context: .unattended)
    }

    public static func act(_ params: ActMethod.Params, context: ActionContext) async throws -> ActionResult {
        let app = try await MainActor.run { try AppResolver.resolve(params.target.app) }
        if params.action == .key, params.element == nil, (try? WindowService.resolve(params.target, app: app)) == nil {
            return try await keyWithoutWindow(params, app: app)
        }
        let treeNotice = await HiddenTrees.shared.prepare(app)
        let window = try WindowService.resolve(params.target, app: app)
        let before = params.diff ? Settle.Capture.take(window: window, app: app) : nil

        if params.element?.ocr == true {
            throw RPCError(
                code: RPCErrorCode.invalidParams,
                message: "Text found by OCR isn't an accessibility element, so it can't be pressed or edited; click it with the pointer instead."
            )
        }
        let allowFocused = params.action == .type || params.action == .key
        let target = try ElementResolver.resolve(params.element, window: window, app: app, allowFocused: allowFocused)
        AX.setTimeout(target.element, seconds: 2)
        let shaper = TreeShaper(window: window.info.frame.cgRect, maxNodes: 1, maxDepth: 0, ref: Snapshotter.registrar(for: app))
        let node = shaper.makeNode(target.raw, visible: target.visible)
        let name = describe(node)

        let needsEnabled: Set<ElementAction> = [.press, .setValue, .select, .increment, .decrement, .type]
        if needsEnabled.contains(params.action), target.raw.enabled == false {
            throw RPCError(code: RPCErrorCode.failed, message: "\(name) is disabled, so nothing happened.")
        }

        var via = "AX"
        var notices: [Notice] = [treeNotice].compactMap { $0 }
        let performed: String
        switch params.action {
        case .press:
            if let action = try? pressAction(for: target, name: name) {
                try check(AX.perform(target.element, action), doing: "press \(name)", notices: &notices)
                performed = action == "AXPress" ? "pressed \(name)" : "\(action.dropFirst(2).lowercased()) on \(name)"
                if target.raw.role == "AXMenuItem" { await Settle.waitForMenuToClose(target.element) }
            } else if let visible = target.visible {
                let point = CGPoint(x: visible.midX, y: visible.midY)
                await RealInputHooks.shared.willAct?(point, "click \(name)", context.owner, context.ownerName)
                let session = try await RealInputSession.begin(app: app, window: window, context: context, keyboard: false)
                do { try await session.click(at: point) } catch { await session.end(); throw error }
                await session.end()
                notices += session.notices
                via = "real input"
                performed = "clicked \(name) (it has no accessibility action)"
            } else {
                throw RPCError(code: RPCErrorCode.failed, message: "\(name) has no accessibility action and isn't visible to click; scroll it into view first.")
            }
        case .setValue:
            let value = try required(params.value, "set-value needs a value")
            let isText = ["AXTextField", "AXTextArea", "AXComboBox"].contains(target.raw.role)
            if isText, target.raw.focused != true, isSettable(target.element, "AXFocused") {
                _ = AX.set(target.element, "AXFocused", kCFBooleanTrue)
            }
            try setValue(value, on: target, name: name)
            performed = "set \(name) to “\(value)”"
            if isText {
                notices.append(Notice(kind: "editing", message: "The field is still being edited; many apps save it only when editing ends. If labels elsewhere don't show the new text, send `key tab` or `key return`."))
            }
        case .focus:
            try check(AX.set(target.element, "AXFocused", kCFBooleanTrue), doing: "focus \(name)", notices: &notices)
            performed = "focused \(name)"
        case .select:
            if isSettable(target.element, "AXSelected") {
                try check(AX.set(target.element, "AXSelected", kCFBooleanTrue), doing: "select \(name)", notices: &notices)
            } else {
                try check(AX.perform(target.element, try pressAction(for: target, name: name)), doing: "select \(name)", notices: &notices)
            }
            performed = "selected \(name)"
        case .increment, .decrement:
            let action = params.action == .increment ? "AXIncrement" : "AXDecrement"
            guard target.raw.actions.contains(action) else {
                throw RPCError(code: RPCErrorCode.failed, message: "\(name) can't \(params.action.rawValue).")
            }
            for _ in 0..<max(1, params.count) {
                try check(AX.perform(target.element, action), doing: "\(params.action.rawValue) \(name)", notices: &notices)
            }
            performed = "\(params.action == .increment ? "incremented" : "decremented") \(name)\(params.count > 1 ? " ×\(params.count)" : "")"
        case .scrollTo:
            let scrolled = AX.scrollIntoView(target.element)
            guard scrolled != .actionUnsupported else {
                throw RPCError(
                    code: RPCErrorCode.failed,
                    message: "\(name) can't be scrolled into view through accessibility in this app. Use `scroll` on its scroll area (the real wheel), or `click`/`hover` it, which scroll it into view first."
                )
            }
            try check(scrolled, doing: "scroll to \(name)", notices: &notices)
            performed = "scrolled \(name) into view"
        case .type where params.real:
            let text = try required(params.value, "type needs text")
            if isSettable(target.element, "AXFocused") { _ = AX.set(target.element, "AXFocused", kCFBooleanTrue) }
            let session = try await RealInputSession.begin(app: app, window: window, context: context, keyboard: true)
            do { try await session.type(text) } catch { await session.end(); throw error }
            await session.end()
            notices += session.notices
            via = "real input"
            performed = "typed “\(text.count > 40 ? String(text.prefix(40)) + "…" : text)” into \(name)"
        case .type:
            let text = try required(params.value, "type needs text")
            via = try type(text, into: target, pid: app.pid)
            performed = "typed “\(text.count > 40 ? String(text.prefix(40)) + "…" : text)” into \(name)"
        case .key where params.real:
            let combo = try KeyCombo.parse(try required(params.value, "key needs a combination, e.g. cmd+s"))
            let session = try await RealInputSession.begin(app: app, window: window, context: context, keyboard: true)
            do { try await session.key(combo) } catch { await session.end(); throw error }
            await session.end()
            notices += session.notices
            via = "real input"
            performed = "pressed \(combo.display) in \(app.name)"
        case .key:
            let combo = try KeyCombo.parse(try required(params.value, "key needs a combination, e.g. cmd+s"))
            if window.info.hasSheet, let panel = await panelService(for: app) {
                post(combo, to: panel)
                notices.append(Notice(kind: "panel", message: "A file panel is open, so the keys went to its process."))
            } else {
                post(combo, to: app.pid)
            }
            via = "background keys"
            performed = "sent \(combo.display) to \(app.name)"
            if !window.info.focused, !window.info.hasSheet {
                notices.append(Notice(kind: "keyWindow", message: "Keys go to \(app.name)'s focused window, which isn't window \(window.info.id) “\(window.info.title)”."))
            }
            let frontmost = await MainActor.run { NSWorkspace.shared.frontmostApplication?.processIdentifier }
            if frontmost != app.pid, !combo.flags.isEmpty {
                notices.append(Notice(kind: "notFrontmost", message: "\(app.name) isn't frontmost; many shortcuts only reach the frontmost window. If nothing changed, run `window activate` first or use `menu-select`."))
            }
        }

        var result = ActionResult(app: app, window: window.info, element: node, performed: performed, via: via, notices: notices)
        if let hit = node.hit {
            result.screenPoint = Point(x: window.info.frame.x + hit.x, y: window.info.frame.y + hit.y)
        }
        if let before {
            await Settle.finish(&result, before: before, window: window, app: app)
        }
        return result
    }

    /// The pid of the "Open and Save Panel Service (<app>)" process serving this app, if any.
    @MainActor
    static func panelService(for app: AppRef) -> pid_t? {
        NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == "com.apple.appkit.xpc.openAndSavePanelService"
                && ($0.localizedName ?? "").hasSuffix("(\(app.name))")
        }?.processIdentifier
    }

    static func keyWithoutWindow(_ params: ActMethod.Params, app: AppRef) async throws -> ActionResult {
        let combo = try KeyCombo.parse(try required(params.value, "key needs a combination, e.g. cmd+s"))
        post(combo, to: app.pid)
        return ActionResult(app: app, window: nil, element: nil, performed: "sent \(combo.display) to \(app.name)", via: "background keys")
    }

    static func describe(_ node: UINode) -> String {
        let role = node.role.hasPrefix("AX") ? String(node.role.dropFirst(2)).lowercased() : node.role
        let label = node.label ?? node.value ?? node.identifier
        return "\(role)\(label.map { " “\($0.prefix(50))”" } ?? "") (\(node.ref))"
    }

    /// The best "do it" action an element offers.
    static func pressAction(for target: ResolvedElement, name: String) throws -> String {
        for candidate in ["AXPress", "AXConfirm", "AXPick", "AXOpen", "AXShowMenu"] where target.raw.actions.contains(candidate) {
            return candidate
        }
        let offered = target.raw.actions.isEmpty ? "none" : target.raw.actions.joined(separator: ", ")
        throw RPCError(code: RPCErrorCode.failed, message: "\(name) can't be pressed (its actions: \(offered)).")
    }

    static func setValue(_ value: String, on target: ResolvedElement, name: String) throws {
        guard isSettable(target.element, "AXValue") else {
            throw RPCError(code: RPCErrorCode.failed, message: "\(name)'s value can't be set directly; try `type` or `press`.")
        }
        let cfValue: CFTypeRef
        switch target.raw.role {
        case "AXSlider", "AXIncrementor", "AXValueIndicator":
            guard let number = Double(value) else {
                throw RPCError(code: RPCErrorCode.invalidParams, message: "\(name) takes a number.")
            }
            cfValue = NSNumber(value: number)
        case "AXCheckBox", "AXRadioButton":
            let on = ["1", "on", "true", "yes", "checked"].contains(value.lowercased())
            cfValue = NSNumber(value: on ? 1 : 0)
        default:
            cfValue = value as CFString
        }
        let error = AX.set(target.element, "AXValue", cfValue)
        guard error == .success else {
            throw RPCError(code: RPCErrorCode.failed, message: "Couldn't set \(name) (AX error \(error.rawValue)).")
        }
    }

    /// Types `text` into the element and returns how it was sent: `AX` or `background keys`.
    static func type(_ text: String, into target: ResolvedElement, pid: pid_t) throws -> String {
        if isSettable(target.element, "AXFocused") {
            _ = AX.set(target.element, "AXFocused", kCFBooleanTrue)
        }
        if isSettable(target.element, "AXSelectedText") {
            let before = AX.value(target.element)
            if AX.set(target.element, "AXSelectedText", text as CFString) == .success {
                for _ in 0..<5 where AX.value(target.element) == before {
                    Thread.sleep(forTimeInterval: 0.04)
                }
                if AX.value(target.element) != before { return "AX" }
            }
        }
        let source = CGEventSource(stateID: .privateState)
        for unit in text.utf16 {
            for keyDown in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown)
                var character = unit
                event?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &character)
                event?.postToPid(pid)
            }
        }
        return "background keys"
    }

    static func post(_ combo: KeyCombo, to pid: pid_t) {
        let source = CGEventSource(stateID: .privateState)
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: combo.keyCode, keyDown: keyDown)
            event?.flags = combo.flags
            event?.postToPid(pid)
        }
    }

    static func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success && settable.boolValue
    }

    /// Throws for an AX error, except "cannot complete", which becomes a notice.
    static func check(_ error: AXError, doing what: String, notices: inout [Notice]) throws {
        switch error {
        case .success:
            return
        case .cannotComplete:
            notices.append(Notice(kind: "unconfirmed", message: "The app didn't confirm “\(what)”; it may be showing a dialog. Check the changes below."))
        default:
            throw RPCError(code: RPCErrorCode.failed, message: "Couldn't \(what) (AX error \(error.rawValue)).")
        }
    }

    static func required(_ value: String?, _ message: String) throws -> String {
        guard let value else { throw RPCError(code: RPCErrorCode.invalidParams, message: message) }
        return value
    }
}

/// Waiting for the UI to stop changing after an action, and describing what changed.
enum Settle {
    struct Capture {
        var nodes: [(ref: String, node: UINode)]
        var windowIDs: [UInt32: String]

        static func take(window: WindowService.Window, app: AppRef) -> Capture {
            let raw = AXReader(maxNodes: 3000, maxDepth: 60, timeBudget: 1.5).read(window.element)
            let shaped = TreeShaper(
                window: window.info.frame.cgRect, maxNodes: 400, maxDepth: 40, ref: Snapshotter.registrar(for: app)
            ).shape(raw)
            var nodes: [(String, UINode)] = []
            func flatten(_ node: UINode) {
                var copy = node
                copy.children = []
                copy.omitted = 0
                nodes.append((node.ref, copy))
                node.children.forEach(flatten)
            }
            flatten(shaped.root)
            let windows = (try? WindowService.windows(of: app)) ?? []
            return Capture(nodes: nodes, windowIDs: Dictionary(uniqueKeysWithValues: windows.map { ($0.info.id, $0.info.title) }))
        }

        /// What counts as a change: content and state, not position.
        var signature: [String] {
            nodes.map { ref, node in
                "\(ref)|\(node.role)|\(node.label ?? "")|\(node.value ?? "")|\(node.enabled ?? true)|\(node.focused ?? false)|\(node.selected ?? false)"
            } + windowIDs.keys.sorted().map { "window \($0)" }
        }
    }

    static func finish(_ result: inout ActionResult, before: Capture, window: WindowService.Window, app: AppRef) async {
        let started = Date()
        var previous = before.signature
        var after = before
        while Date().timeIntervalSince(started) < 2 {
            try? await Task.sleep(for: .milliseconds(120))
            let windows = (try? WindowService.windows(of: app)) ?? []
            guard windows.contains(where: { $0.info.id == window.info.id }) else {
                result.notices.append(Notice(kind: "windowClosed", message: "The window closed."))
                after = Capture(nodes: [], windowIDs: Dictionary(uniqueKeysWithValues: windows.map { ($0.info.id, $0.info.title) }))
                break
            }
            let current = Capture.take(window: window, app: app)
            let signature = current.signature
            after = current
            if signature == previous, Date().timeIntervalSince(started) > 0.25 { break }
            previous = signature
        }
        result.settledMilliseconds = Int(Date().timeIntervalSince(started) * 1000)

        for (id, title) in after.windowIDs where before.windowIDs[id] == nil {
            result.notices.append(Notice(kind: "windowOpened", message: "Opened window \(id) “\(title)”."))
        }
        for (id, title) in before.windowIDs where after.windowIDs[id] == nil && id != window.info.id {
            result.notices.append(Notice(kind: "windowClosed", message: "Closed window \(id) “\(title)”."))
        }
        guard !after.nodes.isEmpty else { return }
        let changes = diff(before: before.nodes, after: after.nodes)
        result.changes = Array(changes.prefix(40))
        result.moreChanges = max(0, changes.count - 40)
    }

    /// Waits up to 1.5 s for the menu holding `item` to close.
    static func waitForMenuToClose(_ item: AXUIElement) async {
        var menu = AX.element(item, "AXParent")
        while let current = menu, AX.role(current) != "AXMenu" { menu = AX.element(current, "AXParent") }
        guard let menu else { return }
        let started = Date()
        while Date().timeIntervalSince(started) < 1.5, !AX.children(menu).isEmpty, AX.role(menu) == "AXMenu" {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    static func diff(before: [(ref: String, node: UINode)], after: [(ref: String, node: UINode)]) -> [UIChange] {
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
        return changes
    }
}
