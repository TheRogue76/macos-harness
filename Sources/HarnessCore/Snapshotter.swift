import ApplicationServices
import Foundation
import HarnessProtocol

/// `snapshot` and `find`: read a window's AX tree and turn it into refs an agent can use.
public enum Snapshotter {
    public static func snapshot(_ params: SnapshotMethod.Params) async throws -> SnapshotMethod.Result {
        let started = Date()
        let app = try await MainActor.run { try AppResolver.resolve(params.target.app) }
        let window = try WindowService.resolve(params.target, app: app)

        var rootElement = window.element
        if let ref = params.root {
            rootElement = try element(for: ref, app: app)
        }
        let raw = AXReader(maxNodes: max(params.maxNodes * 8, 2000), maxDepth: params.maxDepth + 20).read(rootElement)
        let shaper = TreeShaper(
            window: window.info.frame.cgRect, maxNodes: max(params.maxNodes, 1), maxDepth: params.maxDepth,
            ref: registrar(for: app)
        )
        let shaped = shaper.shape(raw)

        var notices = await Notices.collect(for: window.info)
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
        let app = try await MainActor.run { try AppResolver.resolve(params.target.app) }
        let window = try WindowService.resolve(params.target, app: app)
        let raw = AXReader(maxNodes: 8000, maxDepth: 80, timeBudget: 5).read(window.element)
        let shaper = TreeShaper(window: window.info.frame.cgRect, maxNodes: 1, maxDepth: 0, ref: registrar(for: app))

        let wantedRole = params.role.map { $0.hasPrefix("AX") ? $0 : "AX" + $0.prefix(1).uppercased() + $0.dropFirst() }
        let text = params.text?.lowercased()
        let identifier = params.identifier?.lowercased()
        var matches: [FindMethod.Match] = []

        func matchesText(_ candidate: String?) -> Bool {
            guard let text, let candidate = candidate?.lowercased() else { return false }
            return params.exact ? candidate == text : candidate.contains(text)
        }
        func visit(_ node: RawNode, path: [String], clip: CGRect) {
            guard matches.count < params.limit, !TreeShaper.noiseRoles.contains(node.role) else { return }
            let roleOK = wantedRole.map { $0.caseInsensitiveCompare(node.role) == .orderedSame } ?? true
            let idOK = identifier.map { $0 == node.identifier?.lowercased() } ?? true
            let textOK = text == nil || matchesText(node.label) || matchesText(node.value) || matchesText(node.identifier)
            let isWindow = node.role == "AXWindow"
            if roleOK, idOK, textOK, !isWindow, params.text != nil || params.role != nil || params.identifier != nil {
                let visible = node.frame.map { $0.intersection(clip) }.flatMap { $0.isNull || $0.width < 1 || $0.height < 1 ? nil : $0 }
                matches.append(FindMethod.Match(node: shaper.makeNode(node, visible: visible), path: path))
            }
            let childClip = node.role == "AXScrollArea" ? (node.frame?.intersection(clip) ?? clip) : clip
            let name = node.role == "AXWindow" ? nil : node.label.map { "\(node.role.dropFirst(2).lowercased()) \"\($0.prefix(40))\"" }
            for child in node.children {
                visit(child, path: name.map { path + [$0] } ?? path, clip: childClip)
            }
        }
        visit(raw, path: [], clip: window.info.frame.cgRect)
        return FindMethod.Result(window: window.info, matches: matches, notices: await Notices.collect(for: window.info))
    }

    static func registrar(for app: AppRef) -> (RawNode) -> String {
        { node in
            ElementRegistry.shared.ref(for: node.key ?? AnyHashable(UUID()), element: node.element, pid: app.pid)
        }
    }

    /// Resolves a ref from an earlier snapshot, checking the element still exists.
    static func element(for ref: String, app: AppRef) throws -> AXUIElement {
        guard let element = ElementRegistry.shared.element(for: ref, pid: app.pid) else {
            throw RPCError(code: RPCErrorCode.failed, message: "Unknown ref \(ref) for \(app.name). Refs come from snapshot or find on the same app, and reset when the app or the helper restarts; take a new snapshot.")
        }
        var role: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXRole" as CFString, &role) == .invalidUIElement {
            throw RPCError(code: RPCErrorCode.failed, message: "\(ref) no longer exists in \(app.name); take a new snapshot.")
        }
        return element
    }
}
