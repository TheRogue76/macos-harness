import ApplicationServices
import Foundation
import HarnessCore
import HarnessProtocol

/// `snapshot` and `find`: read a window's AX tree and turn it into refs an agent can use.
public enum Snapshotter {
    /// A snapshot for `owner`'s session: the whole tree, or with `since` only what changed since
    /// that session's previous snapshot of the window, and with `query` only matching elements.
    public static func snapshot(_ params: SnapshotMethod.Params, owner: String = ActionContext.unattended.owner) async throws -> SnapshotMethod.Result {
        if let since = params.since, since != "last" {
            throw RPCError(code: RPCErrorCode.invalidParams, message: "since takes `last`.")
        }
        let result = try await read(params)
        let memory = await SnapshotMemory.shared.replace(
            owner: owner, window: "\(params.target.app)|\(result.window.id)",
            limits: "\(params.root ?? "")|\(params.maxNodes)|\(params.maxDepth)", with: flatten(result.root)
        )
        let query = params.query?.trimmingCharacters(in: .whitespacesAndNewlines)
        return narrow(result, since: params.since != nil, previous: memory, query: query?.isEmpty == false ? query : nil)
    }

    /// The snapshot as changes since `previous` when asked and possible, then only the elements
    /// matching `query` and the elements they're in.
    static func narrow(
        _ full: SnapshotMethod.Result, since: Bool, previous: (previous: [(ref: String, node: UINode)]?, reason: String?), query: String?
    ) -> SnapshotMethod.Result {
        var result = full
        if since {
            if let before = previous.previous {
                var changes = Settle.diff(before: before, after: flatten(full.root))
                if let query {
                    changes = changes.filter { matches($0.node, query) || $0.before.map { matches($0, query) } == true }
                }
                result.changes = changes
                result.root.children = []
                result.root.omitted = 0
                result.shownCount = changes.count
                return result
            }
            result.notices.append(Notice(kind: "fullSnapshot", message: previous.reason ?? "This is the whole tree."))
        }
        if let query {
            var root = full.root
            root.children = full.root.children.compactMap { filter($0, query) }
            root.omitted = 0
            result.root = root
            result.shownCount = count(root)
            result.notices.append(Notice(
                kind: "query",
                message: root.children.isEmpty
                    ? "Nothing in the tree matches “\(query)”; `find` also searches elements left out by the limits."
                    : "Only elements matching “\(query)” and the elements they're in are shown; refs are the same as in a full snapshot."
            ))
        }
        return result
    }

    /// Every element of a snapshot tree with its ref, without its children.
    static func flatten(_ root: UINode) -> [(ref: String, node: UINode)] {
        var nodes: [(ref: String, node: UINode)] = []
        func visit(_ node: UINode) {
            var bare = node
            bare.children = []
            nodes.append((node.ref, bare))
            node.children.forEach(visit)
        }
        visit(root)
        return nodes
    }

    static func matches(_ node: UINode, _ query: String) -> Bool {
        [node.label, node.value, node.identifier].contains { $0?.localizedCaseInsensitiveContains(query) == true }
    }

    /// `node` with only the descendants that match `query` or contain one that does, or nil.
    static func filter(_ node: UINode, _ query: String) -> UINode? {
        let kept = node.children.compactMap { filter($0, query) }
        guard matches(node, query) || !kept.isEmpty else { return nil }
        var copy = node
        copy.children = kept
        copy.omitted = 0
        return copy
    }

    static func count(_ node: UINode) -> Int {
        1 + node.children.reduce(0) { $0 + count($1) }
    }

    static func read(_ params: SnapshotMethod.Params) async throws -> SnapshotMethod.Result {
        if params.target.androidDevice != nil { return try await AndroidService.snapshot(params) }
        let started = Date()
        let (app, window) = try await TargetResolver.resolve(TargetResolver.target(params.target, holding: params.root))
        let treeNotice = try await prepare(window, app: app)

        var rootElement = window.content
        if let ref = params.root {
            rootElement = try element(for: ref, app: app)
        }
        let raw = AXReader(maxNodes: max(params.maxNodes * 8, 2000), maxDepth: params.maxDepth + 20).read(rootElement)
        var shaper = TreeShaper(
            space: window.space, maxNodes: max(params.maxNodes, 1), maxDepth: params.maxDepth, ref: registrar(for: app)
        )
        shaper.links = params.links == true
        let shaped = shaper.shape(raw)

        var notices = await Notices.collect(for: window.info) + [treeNotice].compactMap { $0 }
        if shaped.omitted > 0 {
            notices.append(Notice(
                kind: "truncated",
                message: "\(shaped.omitted) elements left out by the limits; run snapshot with --root <ref> on a node marked \"+N more\", or raise --max-nodes."
            ))
        }
        if shaped.offscreen > 0 {
            notices.append(Notice(kind: "offscreen", message: "\(shaped.offscreen) elements are scrolled or clipped out of view; `find` still searches them."))
        }
        return SnapshotMethod.Result(
            window: window.info, root: shaped.root, notices: notices, shownCount: shaped.shown,
            readCount: raw.count, milliseconds: Int(Date().timeIntervalSince(started) * 1000)
        )
    }

    public static func find(_ params: FindMethod.Params) async throws -> FindMethod.Result {
        if params.target.androidDevice != nil { return try await AndroidService.find(params) }
        let (app, window) = try await TargetResolver.resolve(params.target)
        let treeNotice = try await prepare(window, app: app)
        if params.ocr == true {
            let found = try await OCRService.find(params.text, exact: params.exact, in: window, app: app)
            let matches = found.prefix(params.limit).enumerated().map { FindMethod.Match(node: OCRService.node($1, index: $0 + 1), path: []) }
            return FindMethod.Result(window: window.info, matches: Array(matches), notices: await Notices.collect(for: window.info))
        }
        let raw = AXReader(maxNodes: 8000, maxDepth: 80, timeBudget: 5).read(window.content)
        var shaper = TreeShaper(space: window.space, maxNodes: 1, maxDepth: 0, ref: registrar(for: app))
        shaper.links = params.links == true
        let selector = ElementSelector(text: params.text, role: params.role, identifier: params.identifier, exact: params.exact)
        let hits = ElementSearch.search(raw, for: selector, clip: window.space.frame, limit: params.limit)
        let matches = hits.map { FindMethod.Match(node: shaper.makeNode($0.raw, visible: $0.visible), path: $0.path) }
        return FindMethod.Result(window: window.info, matches: matches, notices: await Notices.collect(for: window.info) + [treeNotice].compactMap { $0 })
    }

    /// Readies the target for reading: switches on a Chromium app's hidden tree, or waits for a
    /// simulator's screen to list its elements. Returns a notice when the agent should know.
    static func prepare(_ window: WindowService.Window, app: AppRef) async throws -> Notice? {
        guard window.isSimulator else { return await HiddenTrees.shared.prepare(app) }
        if await SimulatorScreens.waitForContent(window, timeout: 5) { return nil }
        return Notice(
            kind: "simulatorLoading",
            message: "The simulator's screen lists no elements yet; the app may still be launching, so try again in a few seconds or take a screenshot. If it stays empty, Device Hub has lost the simulator's elements, which happens when a simulator restarts while Device Hub is open; quitting Device Hub fixes it but shuts down its simulators, so ask the user first."
        )
    }

    static func registrar(for app: AppRef) -> (RawNode) -> String {
        { node in
            ElementRegistry.shared.ref(for: node.key ?? AnyHashable(UUID()), element: node.element, pid: app.pid)
        }
    }

    /// Resolves a ref from an earlier snapshot, checking the element still exists.
    static func element(for ref: String, app: AppRef) throws -> AXUIElement {
        let element: AXUIElement
        switch ElementRegistry.shared.lookup(ref, pid: app.pid) {
        case .found(let found):
            element = found
        case .stale:
            throw RPCError(code: RPCErrorCode.failed, message: "\(ref) is from before the helper restarted; take a new snapshot of \(app.name).")
        case .unknown:
            throw RPCError(code: RPCErrorCode.failed, message: "Unknown ref \(ref) for \(app.name). Refs come from snapshot or find on the same app and end when the app quits; take a new snapshot.")
        }
        var role: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXRole" as CFString, &role) == .invalidUIElement {
            throw RPCError(code: RPCErrorCode.failed, message: "\(ref) no longer exists in \(app.name); take a new snapshot.")
        }
        return element
    }
}
