import Foundation
import HarnessCore
import HarnessProtocol

/// A browser window's tabs and the address of the page showing.
public enum TabsService {
    public static func tabs(_ params: TabsMethod.Params) async throws -> TabsMethod.Result {
        let (app, window) = try await TargetResolver.resolve(params.target)
        _ = try await Snapshotter.prepare(window, app: app)
        let raw = AXReader(maxNodes: 4000, maxDepth: 60, timeBudget: 3).read(window.content)
        let found = ElementSearch.tabs(in: raw)
        guard !found.isEmpty else {
            throw RPCError(
                code: RPCErrorCode.notFound,
                message: "\(app.name)'s window \(window.info.id) “\(window.info.title)” shows no tabs to accessibility; `find --role tab` searches it too."
            )
        }
        let shaper = TreeShaper(space: window.space, maxNodes: 1, maxDepth: 0, ref: Snapshotter.registrar(for: app))
        let tabs = found.map { tab in
            var node = shaper.makeNode(tab, visible: tab.frame?.visiblePart(in: window.space.frame))
            node.selected = ElementSearch.isSelected(tab: tab)
            node.children = []
            return node
        }
        return TabsMethod.Result(window: window.info, tabs: tabs, url: ElementSearch.page(in: raw)?.url)
    }
}
