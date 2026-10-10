import CoreGraphics
import Foundation
import HarnessProtocol
import ImageIO

/// Seeing and operating Android emulators and phones through adb: what snapshot, find, act,
/// pointer, screenshot and wait do for `android:` targets. Coordinates are the screen's pixels.
public enum AndroidService {
    /// A running device as a target.
    struct Screen {
        var device: AndroidDeviceInfo
        var pid: pid_t
        var app: AppRef
        var window: WindowInfo
        var size: CGSize

        var frame: CGRect { CGRect(origin: .zero, size: size) }
        var serial: String { device.serial }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var pids: [String: pid_t] = [:]

    /// A stand-in process ID per device, which keeps refs apart per device.
    static func pid(for serial: String) -> pid_t {
        lock.withLock {
            if let pid = pids[serial] { return pid }
            let pid = pid_t(-1000 - pids.count)
            pids[serial] = pid
            return pid
        }
    }

    /// The device of an `android:` app string, as a window.
    public static func window(_ app: String) async throws -> WindowInfo {
        try await screen(Target.androidDevice(in: app) ?? "booted").window
    }

    static func screen(_ query: String) async throws -> Screen {
        let device = try await ADB.runningDevice(query)
        let size = device.screen.map { CGSize(width: $0.width, height: $0.height) } ?? CGSize(width: 1080, height: 2400)
        let pid = pid(for: device.serial)
        let app = AppRef(name: device.name, bundleIdentifier: nil, pid: pid)
        let window = WindowInfo(
            id: 0, app: app, title: "\(device.name) – Android \(device.androidVersion ?? "?")",
            frame: Rect(x: 0, y: 0, width: size.width, height: size.height), onScreen: true, minimized: false,
            focused: true, main: true, subrole: nil, hasSheet: false, android: device
        )
        return Screen(device: device, pid: pid, app: app, window: window, size: size)
    }

    /// The screen's tree, read with uiautomator, trying again when a read fails.
    static func dump(_ screen: Screen) async throws -> RawNode {
        var problem = ""
        for attempt in 0..<3 {
            let text = try await ADB.run(["exec-out", "uiautomator", "dump", "/dev/tty"], serial: screen.serial, timeout: 40).text
            if let start = text.range(of: "<?xml"), let end = text.range(of: "</hierarchy>", options: .backwards) {
                return try AndroidTree.parse(Data(text[start.lowerBound..<end.upperBound].utf8), serial: screen.serial, size: screen.size)
            }
            problem = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if attempt < 2 { try await Task.sleep(for: .milliseconds(600)) }
        }
        throw RPCError(code: RPCErrorCode.failed, message: "uiautomator couldn't read \(screen.device.name)'s screen: \(problem.prefix(200))")
    }

    static func registrar(_ screen: Screen) -> (RawNode) -> String {
        { node in ElementRegistry.shared.ref(for: node.key ?? AnyHashable(UUID()), element: nil, pid: screen.pid) }
    }

    static func shaper(_ screen: Screen, maxNodes: Int = 1, maxDepth: Int = 0) -> TreeShaper {
        TreeShaper(window: screen.frame, maxNodes: maxNodes, maxDepth: maxDepth, ref: registrar(screen))
    }

    public static func snapshot(_ params: SnapshotMethod.Params) async throws -> SnapshotMethod.Result {
        let started = Date()
        let screen = try await screen(params.target.androidDevice ?? "booted")
        let tree = try await dump(screen)
        let root = try params.root.map { try node($0, in: tree, screen: screen) } ?? tree
        let shaped = shaper(screen, maxNodes: max(params.maxNodes, 1), maxDepth: params.maxDepth).shape(root)
        var notices: [Notice] = []
        if shaped.omitted > 0 {
            notices.append(Notice(
                kind: "truncated",
                message: "\(shaped.omitted) elements left out by the limits; run snapshot with --root <ref> on a node marked \"+N more\", or raise --max-nodes."
            ))
        }
        if shaped.offscreen > 0 {
            notices.append(Notice(kind: "offscreen", message: "\(shaped.offscreen) elements are scrolled out of view; `find` still searches them."))
        }
        return SnapshotMethod.Result(
            window: screen.window, root: shaped.root, notices: notices, shownCount: shaped.shown, readCount: tree.count,
            milliseconds: Int(Date().timeIntervalSince(started) * 1000)
        )
    }

    public static func find(_ params: FindMethod.Params) async throws -> FindMethod.Result {
        let screen = try await screen(params.target.androidDevice ?? "booted")
        if params.ocr == true {
            let image = try await screenshotImage(screen)
            let found = try OCRService.find(params.text, exact: params.exact, image: image, size: screen.size)
            let matches = found.prefix(params.limit).enumerated().map { FindMethod.Match(node: OCRService.node($1, index: $0 + 1), path: []) }
            return FindMethod.Result(window: screen.window, matches: Array(matches), notices: [])
        }
        let tree = try await dump(screen)
        let selector = ElementSelector(text: params.text, role: params.role, identifier: params.identifier, exact: params.exact)
        let hits = ElementSearch.search(tree, for: selector, clip: screen.frame, limit: params.limit)
        let shaper = shaper(screen)
        return FindMethod.Result(
            window: screen.window, matches: hits.map { FindMethod.Match(node: shaper.makeNode($0.raw, visible: $0.visible), path: $0.path) },
            notices: []
        )
    }

    /// The node a ref stands for in a fresh tree.
    static func node(_ ref: String, in tree: RawNode, screen: Screen) throws -> RawNode {
        guard let key = ElementRegistry.shared.key(for: ref, pid: screen.pid)?.base as? AndroidKey else {
            if ElementRegistry.shared.isStale(ref) {
                throw RPCError(code: RPCErrorCode.failed, message: "\(ref) is from before the helper restarted; take a new snapshot of \(screen.device.name).")
            }
            throw RPCError(code: RPCErrorCode.failed, message: "Unknown ref \(ref) for \(screen.device.name). Refs come from snapshot or find on the same device; take a new snapshot.")
        }
        let match = first(in: tree) { ($0.key?.base as? AndroidKey) == key } ?? onlyNode(withID: key, in: tree)
        guard let match else {
            throw RPCError(code: RPCErrorCode.failed, message: "\(ref) is no longer on \(screen.device.name)'s screen; take a new snapshot.")
        }
        return match
    }

    /// The one node with the key's class and resource ID, when exactly one has them: an element
    /// whose text changed, such as a counter.
    static func onlyNode(withID key: AndroidKey, in tree: RawNode) -> RawNode? {
        guard !key.resourceID.isEmpty else { return nil }
        var found: [RawNode] = []
        func visit(_ node: RawNode) {
            if let other = node.key?.base as? AndroidKey, other.className == key.className, other.resourceID == key.resourceID {
                found.append(node)
            }
            node.children.forEach(visit)
        }
        visit(tree)
        return found.count == 1 ? found[0] : nil
    }

    static func first(in node: RawNode, where matches: (RawNode) -> Bool) -> RawNode? {
        if matches(node) { return node }
        for child in node.children {
            if let found = first(in: child, where: matches) { return found }
        }
        return nil
    }

    /// The element a selector names in the tree, or the focused text field when allowed.
    static func resolve(_ selector: ElementSelector?, tree: RawNode, screen: Screen, allowFocused: Bool) throws -> RawNode {
        if let ref = selector?.ref { return try node(ref, in: tree, screen: screen) }
        if let selector, !selector.isEmpty {
            let registrar = registrar(screen)
            let hits = ElementSearch.search(tree, for: selector, clip: screen.frame, limit: 60)
            return try ElementSearch.single(hits, selector: selector) { hit in
                let label = hit.raw.label ?? hit.raw.value ?? ""
                return "\(registrar(hit.raw)) \(hit.raw.role.dropFirst(2).lowercased()) \"\(label.prefix(40))\""
            }.raw
        }
        guard allowFocused else {
            throw RPCError(code: RPCErrorCode.invalidParams, message: "Say which element: a ref, or --text, --role or --id.")
        }
        guard let focused = first(in: tree, where: { $0.focused == true && $0.role == "AXTextField" })
            ?? first(in: tree, where: { $0.focused == true }) else {
            throw RPCError(code: RPCErrorCode.failed, message: "Nothing on \(screen.device.name)'s screen has focus; name the field with a ref or --text.")
        }
        return focused
    }

    /// The element a selector names, scrolling the screen's main list to find it when it isn't
    /// on screen yet. Returns the tree it was found in.
    static func reveal(_ selector: ElementSelector?, screen: Screen, tree: RawNode, allowFocused: Bool) async throws -> (RawNode, RawNode) {
        guard let selector, selector.ref == nil, !selector.isEmpty,
              ElementSearch.search(tree, for: selector, clip: screen.frame, limit: 1).isEmpty else {
            return (tree, try resolve(selector, tree: tree, screen: screen, allowFocused: allowFocused))
        }
        var current = tree
        for direction in [-1.0, 1.0] {
            for _ in 0..<8 {
                guard let list = mainScroller(in: current) else { break }
                let before = signature(current)
                try await scrollPage(list, direction: direction, screen: screen)
                current = try await dump(screen)
                if !ElementSearch.search(current, for: selector, clip: screen.frame, limit: 1).isEmpty {
                    return (current, try resolve(selector, tree: current, screen: screen, allowFocused: allowFocused))
                }
                if signature(current) == before { break }
            }
        }
        return (current, try resolve(selector, tree: current, screen: screen, allowFocused: allowFocused))
    }

    /// The largest scrollable element on the screen.
    static func mainScroller(in tree: RawNode) -> RawNode? {
        var best: RawNode?
        func visit(_ node: RawNode) {
            if node.actions.contains("scroll"), let frame = node.frame,
               frame.width * frame.height > (best?.frame.map { $0.width * $0.height } ?? 0) {
                best = node
            }
            node.children.forEach(visit)
        }
        visit(tree)
        return best
    }

    /// Swipes a scrollable element by most of its height: a negative direction shows what's below.
    static func scrollPage(_ list: RawNode, direction: Double, screen: Screen) async throws {
        guard let frame = list.frame?.intersection(screen.frame), !frame.isNull else { return }
        let x = Int(frame.midX)
        let top = Int(frame.minY + frame.height * 0.25)
        let bottom = Int(frame.minY + frame.height * 0.75)
        let (from, to) = direction < 0 ? (bottom, top) : (top, bottom)
        try await ADB.shell(screen.serial, "input swipe \(x) \(from) \(x) \(to) 350")
        try await Task.sleep(for: .milliseconds(450))
    }

    /// Text, values and state of every node, to tell whether the screen changed.
    static func signature(_ tree: RawNode) -> [String] {
        var lines: [String] = []
        func visit(_ node: RawNode) {
            lines.append("\(node.role)|\(node.label ?? "")|\(node.value ?? "")|\(node.frame.map { "\(Int($0.minY))" } ?? "")")
            node.children.forEach(visit)
        }
        visit(tree)
        return lines
    }

    /// Whether a frame's center is on screen, clear of the status and navigation bars.
    static func inReach(_ frame: CGRect?, screen: Screen) -> Bool {
        guard let frame else { return false }
        return frame.midY >= screen.size.height * 0.06 && frame.midY <= screen.size.height * 0.94
            && frame.midX >= 0 && frame.midX <= screen.size.width
    }

    /// Scrolls until the node's center is in reach; returns the fresh tree and node.
    static func bringIntoView(_ node: RawNode, tree: RawNode, screen: Screen) async throws -> (RawNode, RawNode) {
        guard !inReach(node.frame, screen: screen), let key = node.key else { return (tree, node) }
        var current = tree
        var target = node
        for _ in 0..<10 {
            guard let list = mainScroller(in: current), let frame = target.frame else { break }
            try await scrollPage(list, direction: frame.midY > screen.size.height / 2 ? -1 : 1, screen: screen)
            current = try await dump(screen)
            guard let found = first(in: current, where: { $0.key == key }) else { break }
            target = found
            if inReach(target.frame, screen: screen) { break }
        }
        return (current, target)
    }

    static func center(_ node: RawNode, name: String, screen: Screen) throws -> CGPoint {
        guard let frame = node.frame?.intersection(screen.frame), !frame.isNull, frame.width >= 1, frame.height >= 1 else {
            throw RPCError(code: RPCErrorCode.failed, message: "\(name) isn't on \(screen.device.name)'s screen; use scroll-to first.")
        }
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    static func tap(_ point: CGPoint, screen: Screen) async throws {
        try await ADB.shell(screen.serial, "input tap \(Int(point.x)) \(Int(point.y))")
    }

    public static func act(_ params: ActMethod.Params, context: ActionContext) async throws -> ActionResult {
        if params.element?.ocr == true {
            throw RPCError(code: RPCErrorCode.invalidParams, message: "Text found by OCR isn't an element; tap it with `click --ocr` instead.")
        }
        let screen = try await screen(params.target.androidDevice ?? "booted")
        var (tree, target) = try await reveal(
            params.element, screen: screen, tree: try await dump(screen), allowFocused: params.action == .type || params.action == .key
        )
        let before = tree
        let shaper = shaper(screen)
        var node = shaper.makeNode(target, visible: target.frame?.intersection(screen.frame))
        let name = ActionService.describe(node)
        let needsEnabled: Set<ElementAction> = [.press, .setValue, .select, .type]
        if needsEnabled.contains(params.action), target.enabled == false {
            throw RPCError(code: RPCErrorCode.failed, message: "\(name) is disabled, so nothing happened.")
        }
        if params.action != .scrollTo, params.action != .key {
            (tree, target) = try await bringIntoView(target, tree: tree, screen: screen)
        }
        var notices: [Notice] = []
        let performed: String
        switch params.action {
        case .press, .select, .focus:
            try await tap(try center(target, name: name, screen: screen), screen: screen)
            performed = params.action == .focus ? "focused \(name)" : "tapped \(name)"
        case .setValue:
            let value = try ActionService.required(params.value, "set-value needs a value")
            if target.role == "AXCheckBox" || target.role == "AXRadioButton" {
                let on = ["1", "on", "true", "yes", "checked"].contains(value.lowercased())
                if (target.value == "1") != on { try await tap(try center(target, name: name, screen: screen), screen: screen) }
                performed = "set \(name) to \(on ? "on" : "off")"
            } else {
                guard target.role == "AXTextField" else {
                    throw RPCError(code: RPCErrorCode.failed, message: "\(name)'s value can't be set on Android; tap it, or drag it if it's a slider.")
                }
                if target.focused != true { try await tap(try center(target, name: name, screen: screen), screen: screen) }
                try await ADB.shell(screen.serial, "input keycombination KEYCODE_CTRL_LEFT KEYCODE_A; input keyevent KEYCODE_DEL")
                if !value.isEmpty { try await AndroidInput.type(value, screen: screen) }
                performed = "set \(name) to “\(value)”"
            }
        case .type:
            let text = try ActionService.required(params.value, "type needs text")
            if target.focused != true { try await tap(try center(target, name: name, screen: screen), screen: screen) }
            try await AndroidInput.type(text, screen: screen)
            performed = "typed “\(text.count > 40 ? String(text.prefix(40)) + "…" : text)” into \(name)"
        case .key:
            let combo = try ActionService.required(params.value, "key needs a combination, e.g. enter")
            if params.element != nil, target.focused != true {
                try await tap(try center(target, name: name, screen: screen), screen: screen)
            }
            try await AndroidInput.key(combo, screen: screen)
            performed = "pressed \(combo) on \(screen.device.name)"
        case .increment, .decrement:
            throw RPCError(code: RPCErrorCode.failed, message: "\(name) can't be stepped through adb; drag it with `drag`.")
        case .scrollTo:
            if inReach(target.frame, screen: screen) {
                performed = "\(name) was already in view"
            } else {
                (tree, target) = try await bringIntoView(target, tree: tree, screen: screen)
                guard inReach(target.frame, screen: screen) else {
                    throw RPCError(code: RPCErrorCode.failed, message: "\(name) couldn't be scrolled into view; swipe instead.")
                }
                node = shaper.makeNode(target, visible: target.frame?.intersection(screen.frame))
                performed = "scrolled \(name) into view"
            }
        }
        if params.action == .setValue || params.action == .type, target.subrole == "AXSecureTextField" {
            notices.append(Notice(kind: "secure", message: "That's a password field; what was typed isn't shown."))
        }
        var result = ActionResult(app: screen.app, window: screen.window, element: node, performed: performed, via: "adb", notices: notices)
        if let hit = node.hit { result.screenPoint = hit }
        if params.diff { try await settle(&result, before: before, screen: screen) }
        return result
    }

    /// Throws unless `target` names the device whose screen this is: adb drags stay on one screen.
    static func requireSameScreen(_ target: Target, as screen: Screen) async throws {
        guard let device = target.androidDevice else {
            throw RPCError(code: RPCErrorCode.invalidParams, message: PointerService.androidCrossing)
        }
        let other = try await AndroidService.screen(device)
        if let refusal = PointerService.crossingRefusal(from: screen.window, to: other.window) {
            throw RPCError(code: RPCErrorCode.invalidParams, message: refusal)
        }
    }

    public static func pointer(_ params: PointerMethod.Params, context: ActionContext) async throws -> ActionResult {
        let screen = try await screen(params.target.androidDevice ?? "booted")
        if params.action == .drag, let destination = params.toTarget {
            try await requireSameScreen(destination, as: screen)
        }
        var tree = try await dump(screen)
        let before = tree
        var node: UINode?
        let point: CGPoint
        if let selector = params.element, selector.ocr == true {
            let found = try OCRService.find(selector.text, exact: selector.exact, image: try await screenshotImage(screen), size: screen.size)
            guard found.count == 1, let first = found.first else {
                throw RPCError(code: RPCErrorCode.failed, message: found.isEmpty ? "Text recognition didn't find “\(selector.text ?? "")”." : "“\(selector.text ?? "")” appears \(found.count) times; use --x and --y.")
            }
            point = CGPoint(x: first.frame.midX, y: first.frame.midY)
            node = OCRService.node(first, index: 1)
        } else if let selector = params.element, !selector.isEmpty {
            var target: RawNode
            (tree, target) = try await reveal(selector, screen: screen, tree: tree, allowFocused: false)
            (tree, target) = try await bringIntoView(target, tree: tree, screen: screen)
            let made = shaper(screen).makeNode(target, visible: target.frame?.intersection(screen.frame))
            node = made
            point = try center(target, name: ActionService.describe(made), screen: screen)
        } else if let given = params.point {
            guard given.x >= 0, given.y >= 0, given.x <= screen.size.width, given.y <= screen.size.height else {
                throw RPCError(code: RPCErrorCode.invalidParams, message: "(\(Int(given.x)), \(Int(given.y))) is outside the screen (\(Int(screen.size.width))x\(Int(screen.size.height)) px).")
            }
            point = CGPoint(x: given.x, y: given.y)
        } else if params.action == .scroll || params.action == .swipe {
            point = CGPoint(x: screen.size.width / 2, y: screen.size.height / 2)
        } else {
            throw RPCError(code: RPCErrorCode.invalidParams, message: "Give the target as a ref, --text/--role/--id, or --x and --y in pixels.")
        }
        let what = node.map(ActionService.describe) ?? "point (\(Int(point.x)), \(Int(point.y)))"
        let x = Int(point.x)
        let y = Int(point.y)
        let performed: String
        var notices: [Notice] = []
        switch params.action {
        case .click:
            try await ADB.shell(screen.serial, "input tap \(x) \(y)")
            performed = "tapped \(what)"
        case .doubleClick:
            try await ADB.shell(screen.serial, "input tap \(x) \(y); input tap \(x) \(y)")
            performed = "double-tapped \(what)"
        case .rightClick, .longPress:
            let hold = Int(max(params.hold, params.action == .rightClick ? 0.8 : 0.6) * 1000)
            try await ADB.shell(screen.serial, "input swipe \(x) \(y) \(x) \(y) \(hold)")
            performed = "long-pressed \(what)"
            if params.action == .rightClick {
                notices.append(Notice(kind: "longPress", message: "Android has no right-click; this was a long press."))
            }
        case .hover:
            throw RPCError(code: RPCErrorCode.invalidParams, message: "Android has no hover; tap or long-press instead.")
        case .swipe, .scroll:
            let end = CGPoint(x: point.x + params.dx, y: point.y + params.dy)
            let ms = Int(max(0.15, min(params.duration, 1.5)) * 1000)
            try await ADB.shell(screen.serial, "input swipe \(x) \(y) \(Int(end.x)) \(Int(end.y)) \(ms)")
            performed = params.action == .swipe ? "swiped \(what) by \(Int(params.dx)),\(Int(params.dy))" : "scrolled \(what) by \(Int(params.dx)),\(Int(params.dy))"
        case .drag:
            let destination: CGPoint
            if let to = params.to, !to.isEmpty {
                let target = try resolve(to, tree: tree, screen: screen, allowFocused: false)
                destination = try center(target, name: "the drag destination", screen: screen)
            } else if let toPoint = params.toPoint {
                destination = CGPoint(x: toPoint.x, y: toPoint.y)
            } else {
                throw RPCError(code: RPCErrorCode.invalidParams, message: "drag needs a destination")
            }
            let ms = Int(max(0.3, params.duration) * 1000)
            try await ADB.shell(screen.serial, "input draganddrop \(x) \(y) \(Int(destination.x)) \(Int(destination.y)) \(ms)")
            performed = "dragged \(what) to (\(Int(destination.x)), \(Int(destination.y)))"
        }
        var result = ActionResult(
            app: screen.app, window: screen.window, element: node, performed: performed, via: "adb", notices: notices,
            screenPoint: Point(x: point.x, y: point.y)
        )
        if params.diff { try await settle(&result, before: before, screen: screen) }
        return result
    }

    /// Reads the screen again after an action and lists what changed.
    static func settle(_ result: inout ActionResult, before: RawNode, screen: Screen) async throws {
        let started = Date()
        try await Task.sleep(for: .milliseconds(500))
        let after = try await dump(screen)
        result.settledMilliseconds = Int(Date().timeIntervalSince(started) * 1000)
        let changes = Settle.diff(before: flatten(before, screen: screen), after: flatten(after, screen: screen))
        result.changes = Array(changes.prefix(40))
        result.moreChanges = max(0, changes.count - 40)
    }

    static func flatten(_ tree: RawNode, screen: Screen) -> [(ref: String, node: UINode)] {
        let shaped = shaper(screen, maxNodes: 400, maxDepth: 40).shape(tree)
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

    /// The screen as an image, in its own pixels.
    static func screenshotImage(_ screen: Screen) async throws -> CGImage {
        let data = try await ADB.run(["exec-out", "screencap", "-p"], serial: screen.serial, timeout: 30).stdout
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw RPCError(code: RPCErrorCode.failed, message: "\(screen.device.name)'s screenshot couldn't be read.")
        }
        return image
    }

    public static func screenshot(_ params: ScreenshotMethod.Params) async throws -> ScreenshotMethod.Result {
        let screen = try await screen(params.target.androidDevice ?? "booted")
        var image = try await screenshotImage(screen)
        let longest = max(image.width, image.height)
        if params.maxSize > 0, longest > params.maxSize {
            image = ScreenshotService.resized(image, by: CGFloat(params.maxSize) / CGFloat(longest)) ?? image
        }
        let scale = CGFloat(image.width) / max(screen.size.width, 1)
        var crop: Rect?
        var tree: RawNode?
        if let ref = params.element {
            let current = try await dump(screen)
            tree = current
            guard let frame = try node(ref, in: current, screen: screen).frame?.intersection(screen.frame), !frame.isNull else {
                throw RPCError(code: RPCErrorCode.failed, message: "\(ref) isn't on screen, so there's nothing to crop to.")
            }
            let pixels = CGRect(x: frame.minX * scale, y: frame.minY * scale, width: frame.width * scale, height: frame.height * scale).integral
            if let cropped = image.cropping(to: pixels) {
                image = cropped
                crop = Rect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height)
            }
        }
        let origin = crop.map { CGPoint(x: $0.x, y: $0.y) } ?? .zero
        if let spacing = params.grid, spacing >= 10 {
            image = ScreenshotService.draw(grid: CGFloat(spacing), on: image, scale: scale, origin: origin)
        }
        var labeled: [String] = []
        if params.labels {
            let current: RawNode
            if let tree { current = tree } else { current = try await dump(screen) }
            let shaped = shaper(screen, maxNodes: 400, maxDepth: 40).shape(current)
            let targets = ScreenshotService.labelTargets(shaped.root)
            image = ScreenshotService.draw(labels: targets, on: image, scale: scale, origin: origin)
            labeled = targets.map(\.ref)
        }
        return ScreenshotMethod.Result(
            window: screen.window, pngBase64: try ScreenshotService.png(image).base64EncodedString(), width: image.width,
            height: image.height, scale: (Double(scale) * 1000).rounded() / 1000, crop: crop, labeledRefs: labeled, notices: []
        )
    }

    public static func wait(_ params: WaitMethod.Params) async throws -> WaitMethod.Result {
        let started = Date()
        let screen = try await screen(params.target.androidDevice ?? "booted")
        let shaper = shaper(screen)
        repeat {
            let tree = try await dump(screen)
            var found: UINode?
            if let ref = params.element.ref {
                found = (try? node(ref, in: tree, screen: screen)).map { shaper.makeNode($0, visible: $0.frame?.intersection(screen.frame)) }
            } else if let hit = ElementSearch.search(tree, for: params.element, clip: screen.frame, limit: 1).first {
                found = shaper.makeNode(hit.raw, visible: hit.visible)
            }
            if params.gone ? found == nil : found != nil {
                return WaitMethod.Result(satisfied: true, node: found, window: screen.window, milliseconds: Int(Date().timeIntervalSince(started) * 1000))
            }
            try await Task.sleep(for: .milliseconds(300))
        } while Date().timeIntervalSince(started) < params.timeout
        return WaitMethod.Result(satisfied: false, node: nil, window: screen.window, milliseconds: Int(Date().timeIntervalSince(started) * 1000))
    }
}
