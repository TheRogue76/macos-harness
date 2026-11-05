import Foundation
import HarnessCore
import HarnessProtocol

/// `collect` on desktop apps: every item of a list that shows only part of itself, gathered by
/// reading the window's tree, then asking AT-SPI to scroll the last item read to the top of the
/// list, until nothing new appears. It never uses the real mouse.
extension LinuxDesktop {
    public static func collect(_ params: CollectMethod.Params, context: ActionContext) async throws -> CollectMethod.Result {
        try CollectService.check(params)
        let first = try await place(params.target)
        if (first.placed?.appID ?? "").hasPrefix("io.github.therogue76.MacosHarness") {
            throw RPCError(code: RPCErrorCode.failed, message: "That's one of the harness's own windows, which agents can't scroll through.")
        }
        try await context.claim(WindowClaims.key(window: first.info.id), place: "\(first.ref.name)'s window “\(first.info.title)”")
        let memory = CollectMemory.key(owner: context.owner, place: "\(first.ref.pid)|\(first.info.id)", params: params)
        var collector = try await CollectService.collector(params, memory: memory)
        collector.patience = 2
        var current = first
        let outcome = try await collector.run(
            read: {
                current = try await place(params.target)
                let tree = try await tree(of: current, limit: 8000)
                guard let within = params.within else { return tree }
                return try await resolve(ElementSelector(ref: within), in: current, tree: tree)
            },
            scroll: { last in try await scroll(from: last, in: current) },
            aborted: context.shouldAbort
        )
        await CollectMemory.shared.remember(memory, seen: collector.seen)
        let shaper = TreeShaper(window: current.frame, maxNodes: 1, maxDepth: 0, ref: registrar(current))
        var notices = current.notices
        if outcome.stop == .stuck {
            notices.append(Notice(
                kind: "listStuck",
                message: "\(current.ref.name) doesn't scroll its list through accessibility (GTK 4 apps don't), so only the items it has built were collected. If there are more, scroll the list with `scroll` and call again with --continue (continue=true)."
            ))
        }
        return CollectService.result(outcome, app: current.ref, window: current.info, ref: shaper.ref, notices: notices)
    }

    /// Scrolls the list on from its last item read, by asking AT-SPI to bring that item to the
    /// top; false when the item can't be scrolled to. The collector stops once a scroll brings
    /// nothing new.
    static func scroll(from last: RawNode, in place: Place) async throws -> Bool {
        guard let key = last.key?.base as? ATSPIKey, let item = place.items.first(where: { $0.path == key.path }),
              item.interfaces.contains(Element.component) else { return false }
        let element = Element(bus: place.app.bus, item: item, connection: place.connection, name: "")
        guard (try? await element.call(Element.component, "ScrollTo", [.uint32(0)]).first?.bool) == true else { return false }
        try await Task.sleep(for: .milliseconds(400))
        return true
    }
}
