import ApplicationServices
import Foundation
import HarnessProtocol

/// `snapshot` and `find`: read a window's AX tree and turn it into refs an agent can use.
public enum Snapshotter {
    public static func snapshot(_ params: SnapshotMethod.Params) async throws -> SnapshotMethod.Result {
        if params.target.androidDevice != nil { return try await AndroidService.snapshot(params) }
        let started = Date()
        let (app, window) = try await TargetResolver.resolve(params.target)
        let treeNotice = try await prepare(window, app: app)

        var rootElement = window.content
        if let ref = params.root {
            rootElement = try element(for: ref, app: app)
        }
        let raw = AXReader(maxNodes: max(params.maxNodes * 8, 2000), maxDepth: params.maxDepth + 20).read(rootElement)
        let shaper = TreeShaper(
            space: window.space, maxNodes: max(params.maxNodes, 1), maxDepth: params.maxDepth, ref: registrar(for: app)
        )
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
        let shaper = TreeShaper(space: window.space, maxNodes: 1, maxDepth: 0, ref: registrar(for: app))
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
