import Foundation
import HarnessProtocol

/// What `snapshot`'s `since` and `query` do to a whole snapshot, on every platform.
public enum SnapshotNarrowing {
    /// Refuses a `since` other than `last`.
    package static func check(_ params: SnapshotMethod.Params) throws {
        if let since = params.since, since != "last" {
            throw RPCError(code: RPCErrorCode.invalidParams, message: "since takes `last`.")
        }
    }

    /// The whole snapshot narrowed as `params` ask, remembered as `owner`'s latest of the window.
    package static func narrowed(_ result: SnapshotMethod.Result, params: SnapshotMethod.Params, owner: String) async -> SnapshotMethod.Result {
        let memory = await SnapshotMemory.shared.replace(
            owner: owner, window: "\(params.target.app)|\(result.window.id)",
            limits: "\(params.root ?? "")|\(params.maxNodes)|\(params.maxDepth)", with: flatten(result.root)
        )
        let query = params.query?.trimmingCharacters(in: .whitespacesAndNewlines)
        return narrow(result, since: params.since != nil, previous: memory, query: query?.isEmpty == false ? query : nil)
    }

    /// The snapshot as changes since `previous` when asked and possible, then only the elements
    /// matching `query` and the elements they're in.
    package static func narrow(
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
    package static func flatten(_ root: UINode) -> [(ref: String, node: UINode)] {
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

    package static func matches(_ node: UINode, _ query: String) -> Bool {
        [node.label, node.value, node.identifier].contains { $0?.localizedCaseInsensitiveContains(query) == true }
    }

    /// `node` with only the descendants that match `query` or contain one that does, or nil.
    package static func filter(_ node: UINode, _ query: String) -> UINode? {
        let kept = node.children.compactMap { filter($0, query) }
        guard matches(node, query) || !kept.isEmpty else { return nil }
        var copy = node
        copy.children = kept
        copy.omitted = 0
        return copy
    }

    package static func count(_ node: UINode) -> Int {
        1 + node.children.reduce(0) { $0 + count($1) }
    }
}
