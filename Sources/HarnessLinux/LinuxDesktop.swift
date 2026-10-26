#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import HarnessCore
import HarnessDBus
import HarnessProtocol

/// Seeing Linux desktop apps through AT-SPI: what apps, windows, snapshot, find and read do for
/// targets that aren't `android:` devices. Frames are relative to the window, because Wayland
/// doesn't tell apps where their windows are.
public enum LinuxDesktop {
    /// A window of an app, with everything its app's tree holds.
    struct Place {
        var app: ATSPIApp
        var ref: AppRef
        var window: ATSPIItem
        var info: WindowInfo
        var items: [ATSPIItem]
        var connection: DBusConnection
        /// What the agent should know about the window, such as a Chromium tree switched on.
        var notices: [Notice] = []

        var frame: CGRect { CGRect(x: 0, y: 0, width: info.frame.width, height: info.frame.height) }
    }

    /// AT-SPI roles of windows and dialogs.
    static let windowRoles: Set<UInt32> = [2, 9, 14, 16, 19, 22, 23, 36, 69]

    static let windowRelative = Notice(
        kind: "windowRelative",
        message: "Positions are relative to the window's top-left corner: Wayland doesn't tell apps where their windows are."
    )

    public static func apps(_ params: AppsMethod.Params) async throws -> AppsMethod.Result {
        let connection = try await ATSPIBus.shared.connection()
        let apps = try await ATSPI.apps(on: connection)
        let windows = await topLevels(of: apps, on: connection)
        let listed = zip(apps, windows).compactMap { app, windows -> AppsMethod.App? in
            guard let pid = app.pid, params.includeBackground || !windows.isEmpty else { return nil }
            return AppsMethod.App(
                name: displayName(app), bundleIdentifier: appID(app), pid: pid,
                active: windows.contains { $0.states.contains(.active) }, hidden: false,
                activationPolicy: windows.isEmpty ? "accessory" : "regular", windowCount: windows.count
            )
        }
        return AppsMethod.Result(apps: listed)
    }

    public static func windows(_ params: WindowsMethod.Params) async throws -> WindowsMethod.Result {
        let connection = try await ATSPIBus.shared.connection()
        var apps = try await ATSPI.apps(on: connection)
        if let query = params.app { apps = [try pick(query, from: apps)] }
        let windows = await topLevels(of: apps, on: connection)
        var infos: [WindowInfo] = []
        for (app, items) in zip(apps, windows) {
            for item in items {
                infos.append(await info(item, app: app, on: connection))
            }
        }
        return WindowsMethod.Result(windows: infos)
    }

    public static func snapshot(_ params: SnapshotMethod.Params) async throws -> SnapshotMethod.Result {
        let started = Date()
        let place = try await place(params.target)
        let start = try params.root.map { try path(for: $0, in: place) } ?? place.window.path
        guard let (raw, count) = await ATSPITree.read(
            place.items, bus: place.app.bus, from: start, on: place.connection, limit: max(params.maxNodes * 8, 2000)
        ) else {
            throw RPCError(code: RPCErrorCode.failed, message: "\(place.ref.name)'s window has no elements to show.")
        }
        var shaper = TreeShaper(window: place.frame, maxNodes: max(params.maxNodes, 1), maxDepth: params.maxDepth, ref: registrar(place))
        shaper.links = params.links == true
        let shaped = shaper.shape(raw)
        var notices = place.notices + [windowRelative]
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
            window: place.info, root: shaped.root, notices: notices, shownCount: shaped.shown, readCount: count,
            milliseconds: Int(Date().timeIntervalSince(started) * 1000)
        )
    }

    public static func find(_ params: FindMethod.Params) async throws -> FindMethod.Result {
        guard params.ocr != true else {
            throw RPCError(code: RPCErrorCode.failed, message: "Text recognition on Linux desktop apps needs screenshots, which aren't supported yet.")
        }
        let place = try await place(params.target)
        let raw = try await tree(of: place, limit: 8000)
        var shaper = TreeShaper(window: place.frame, maxNodes: 1, maxDepth: 0, ref: registrar(place))
        shaper.links = params.links == true
        let selector = ElementSelector(text: params.text, role: params.role, identifier: params.identifier, exact: params.exact)
        let hits = ElementSearch.search(raw, for: selector, clip: place.frame, limit: params.limit)
        return FindMethod.Result(
            window: place.info, matches: hits.map { FindMethod.Match(node: shaper.makeNode($0.raw, visible: $0.visible), path: $0.path) },
            notices: place.notices + [windowRelative]
        )
    }

    public static func read(_ params: ReadMethod.Params) async throws -> ReadMethod.Result {
        let place = try await place(params.target)
        let raw: RawNode
        if let selector = params.element, !selector.isEmpty {
            raw = try await resolve(selector, in: place)
        } else {
            raw = try await tree(of: place, limit: 8000)
        }
        let shaper = TreeShaper(window: place.frame, maxNodes: 1, maxDepth: 0, ref: registrar(place))
        return ReadService.result(
            raw, node: shaper.makeNode(raw, visible: raw.frame), app: place.ref, window: place.info, ref: shaper.ref,
            notices: place.notices + [windowRelative]
        )
    }

    /// The element a selector names in the window, searching `tree` when it's already read.
    static func resolve(_ selector: ElementSelector, in place: Place, tree: RawNode? = nil) async throws -> RawNode {
        if let ref = selector.ref {
            let path = try path(for: ref, in: place)
            guard let (node, _) = await ATSPITree.read(place.items, bus: place.app.bus, from: path, on: place.connection, limit: 8000) else {
                throw RPCError(code: RPCErrorCode.failed, message: "\(ref) is no longer in \(place.ref.name); take a new snapshot.")
            }
            return node
        }
        let raw = if let tree { tree } else { try await self.tree(of: place, limit: 8000) }
        let registrar = registrar(place)
        let hits = ElementSearch.search(raw, for: selector, clip: place.frame, limit: 60)
        return try ElementSearch.single(hits, selector: selector) { hit in
            let label = hit.raw.label ?? hit.raw.value ?? ""
            return "\(registrar(hit.raw)) \(hit.raw.role.dropFirst(2).lowercased()) \"\(label.prefix(40))\""
        }.raw
    }

    static func tree(of place: Place, limit: Int) async throws -> RawNode {
        guard let (raw, _) = await ATSPITree.read(place.items, bus: place.app.bus, from: place.window.path, on: place.connection, limit: limit) else {
            throw RPCError(code: RPCErrorCode.failed, message: "\(place.ref.name)'s window has no elements.")
        }
        return raw
    }

    static func registrar(_ place: Place) -> (RawNode) -> String {
        let pid = place.ref.pid
        return { node in ElementRegistry.shared.ref(for: node.key ?? AnyHashable(UUID()), pid: pid) }
    }

    /// The object path a ref stands for, checking it belongs to this app and still exists.
    static func path(for ref: String, in place: Place) throws -> String {
        guard let key = ElementRegistry.shared.key(for: ref, pid: place.ref.pid)?.base as? ATSPIKey, key.bus == place.app.bus else {
            if ElementRegistry.shared.isStale(ref) {
                throw RPCError(code: RPCErrorCode.failed, message: "\(ref) is from before the helper restarted; take a new snapshot of \(place.ref.name).")
            }
            throw RPCError(
                code: RPCErrorCode.failed,
                message: "Unknown ref \(ref) for \(place.ref.name). Refs come from snapshot or find on the same app and end when the app quits; take a new snapshot."
            )
        }
        guard place.items.contains(where: { $0.path == key.path }) else {
            throw RPCError(code: RPCErrorCode.failed, message: "\(ref) no longer exists in \(place.ref.name); take a new snapshot.")
        }
        return key.path
    }

    /// The app and window a target names, with the app's tree.
    static func place(_ target: Target) async throws -> Place {
        let connection = try await ATSPIBus.shared.connection()
        let app = try pick(target.app, from: try await ATSPI.apps(on: connection))
        let items = try await ATSPI.items(of: app.bus, on: connection)
        let windows = items.filter { $0.parent == ATSPI.root && windowRoles.contains($0.role) }
        let ref = AppRef(name: displayName(app), bundleIdentifier: appID(app), pid: app.pid ?? -1)
        let window: ATSPIItem
        if let id = target.window {
            guard let match = windows.first(where: { windowID(bus: app.bus, path: $0.path) == id }) else {
                throw RPCError(code: RPCErrorCode.notFound, message: "\(ref.name) has no window \(id); run `windows \(ref.name)` to list them.")
            }
            window = match
        } else {
            let showing = await withTaskGroup(of: (Int, ATSPIItem?).self) { group in
                for (index, item) in windows.enumerated() where !item.states.contains(.iconified) && item.states.contains(.showing) {
                    group.addTask { (index, await hasArea(item, bus: app.bus, on: connection) ? item : nil) }
                }
                var kept: [(Int, ATSPIItem?)] = []
                for await entry in group { kept.append(entry) }
                return kept.sorted { $0.0 < $1.0 }.compactMap(\.1)
            }
            guard let chosen = showing.first(where: { $0.states.contains(.active) }) ?? showing.first(where: { $0.states.contains(.modal) })
                ?? showing.first ?? windows.first(where: { $0.states.contains(.active) }) ?? windows.first else {
                throw RPCError(code: RPCErrorCode.notFound, message: "\(ref.name) has no windows open.")
            }
            window = chosen
        }
        let info = await info(window, app: app, on: connection)
        let (grown, notice) = await HiddenTrees.prepare(app, window: window, items: items, on: connection)
        return Place(
            app: app, ref: ref, window: window, info: info, items: grown ?? items, connection: connection, notices: notice.map { [$0] } ?? []
        )
    }

    /// Whether a window has a size; a GTK window that was hidden can linger in the tree at 0×0.
    static func hasArea(_ window: ATSPIItem, bus: String, on connection: DBusConnection) async -> Bool {
        guard let box = try? await connection.call(
            bus, window.path, "org.a11y.atspi.Component", "GetExtents", [.uint32(1)], timeout: ATSPI.timeout
        ).first?.fields?.compactMap(\.int), box.count == 4 else { return true }
        return box[2] > 0 && box[3] > 0
    }

    /// The app a query names: a pid, or a name matched against the app's name, its last
    /// part (`Nautilus` for `org.gnome.Nautilus`) and its executable.
    static func pick(_ query: String, from apps: [ATSPIApp]) throws -> ATSPIApp {
        let wanted = query.trimmingCharacters(in: .whitespaces).lowercased()
        if let pid = Int32(wanted), let app = apps.first(where: { $0.pid == pid }) { return app }
        let named = apps.map { app in (app, names(of: app).map { $0.lowercased() }) }
        if let exact = named.first(where: { $0.1.contains { LinuxApps.matches($0, wanted) } }) { return exact.0 }
        let partial = named.filter { $0.1.contains { $0.contains(wanted) } }
        if partial.count == 1 { return partial[0].0 }
        let listing = Set(apps.filter { $0.pid != nil }.map(displayName)).sorted().joined(separator: ", ")
        if partial.isEmpty {
            throw RPCError(code: RPCErrorCode.notFound, message: "No app matching “\(query)” has an accessibility tree. Apps that do: \(listing).")
        }
        throw RPCError(
            code: RPCErrorCode.notFound,
            message: "“\(query)” could be any of \(partial.map { displayName($0.0) }.joined(separator: ", ")); use a fuller name or a pid."
        )
    }

    static func names(of app: ATSPIApp) -> [String] {
        var names = [app.name, displayName(app)]
        if let pid = app.pid, let path = LinuxProcesses().snapshot(of: pid)?.path, !path.isEmpty {
            names.append((path as NSString).lastPathComponent)
        }
        return names.filter { !$0.isEmpty }
    }

    /// `Nautilus` for `org.gnome.Nautilus`; other names as they are.
    static func displayName(_ app: ATSPIApp) -> String {
        guard let id = appID(app) else { return app.name.isEmpty ? app.bus : app.name }
        return String(id.split(separator: ".").last ?? Substring(id))
    }

    /// A reverse-DNS app ID, when the app's name is one.
    static func appID(_ app: ATSPIApp) -> String? {
        let parts = app.name.split(separator: ".")
        return parts.count >= 3 && !app.name.contains(" ") ? app.name : nil
    }

    /// A stable number for a window, from its app and object path.
    static func windowID(bus: String, path: String) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for byte in (bus + "|" + path).utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        return hash
    }

    static func info(_ window: ATSPIItem, app: ATSPIApp, on connection: DBusConnection) async -> WindowInfo {
        let box = try? await connection.call(
            app.bus, window.path, "org.a11y.atspi.Component", "GetExtents", [.uint32(1)], timeout: ATSPI.timeout
        ).first?.fields?.compactMap(\.int)
        let size = box.flatMap { $0.count == 4 ? (width: Double($0[2]), height: Double($0[3])) : nil } ?? (width: 0, height: 0)
        let role = ATSPIRoles.ax(window.role, states: window.states)
        return WindowInfo(
            id: windowID(bus: app.bus, path: window.path), app: AppRef(name: displayName(app), bundleIdentifier: appID(app), pid: app.pid ?? -1),
            title: window.name, frame: Rect(x: 0, y: 0, width: size.width, height: size.height),
            onScreen: window.states.contains(.showing), minimized: window.states.contains(.iconified),
            focused: window.states.contains(.active), main: window.states.contains(.active), subrole: role?.subrole,
            hasSheet: false
        )
    }

    /// Each app's windows, read without its whole tree.
    static func topLevels(of apps: [ATSPIApp], on connection: DBusConnection) async -> [[ATSPIItem]] {
        await withTaskGroup(of: (Int, [ATSPIItem]).self) { group in
            for (index, app) in apps.enumerated() {
                group.addTask {
                    let items = (try? await ATSPI.walk(app.bus, on: connection, from: ATSPI.root, limit: 200, depth: 2)) ?? []
                    return (index, items.filter { $0.parent == ATSPI.root && windowRoles.contains($0.role) })
                }
            }
            var result = Array(repeating: [ATSPIItem](), count: apps.count)
            for await (index, items) in group { result[index] = items }
            return result
        }
    }
}
