import ApplicationServices
import CoreGraphics
import Foundation
import HarnessCore
import HarnessProtocol

extension ReadService {
    public static func read(_ params: ReadMethod.Params) async throws -> ReadMethod.Result {
        if params.target.androidDevice != nil { return try await AndroidService.read(params) }
        if params.element?.ocr == true {
            throw RPCError(code: RPCErrorCode.invalidParams, message: "Text found by OCR has no element to read; `find --ocr` lists every line it reads.")
        }
        let (app, window) = try await TargetResolver.resolve(TargetResolver.target(params.target, holding: params.element?.ref))
        let treeNotice = try await Snapshotter.prepare(window, app: app)
        var element = window.content
        var visible: CGRect?
        if let selector = params.element, !selector.isEmpty {
            let resolved = if window.isSimulator, selector.ref == nil {
                try await SimulatorScrolling.reveal(selector, window: window, app: app, deadline: Date().addingTimeInterval(SimulatorScrolling.budget))
            } else {
                try await ElementResolver.resolve(selector, window: window, app: app, allowFocused: false)
            }
            element = resolved.element
            visible = resolved.visible
        }
        AX.setTimeout(element, seconds: window.isSimulator ? 8 : 2)
        let raw = AXReader(maxNodes: 5000, maxDepth: 80, timeBudget: 5, valueLimit: limit).read(element)
        var shaper = TreeShaper(space: window.space, maxNodes: 1, maxDepth: 0, ref: Snapshotter.registrar(for: app))
        shaper.links = true
        let notices = await Notices.collect(for: window.info) + [treeNotice].compactMap { $0 }
        return result(raw, node: shaper.makeNode(raw, visible: visible), app: app, window: window.info, ref: shaper.ref, notices: notices)
    }

}
