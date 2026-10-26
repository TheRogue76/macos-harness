import Foundation
import HarnessDBus
import HarnessProtocol

/// The accessibility bus, where apps publish their AT-SPI trees.
public actor ATSPIBus {
    public static let shared = ATSPIBus()

    private var current: DBusConnection?
    private var connecting: Task<DBusConnection, any Error>?

    /// The connection to the bus, made on first use and again after it closes.
    public func connection() async throws -> DBusConnection {
        if let current, !current.isClosed { return current }
        if let connecting { return try await connecting.value }
        let task = Task { try await Self.connect() }
        connecting = task
        defer { connecting = nil }
        let made = try await task.value
        current = made
        return made
    }

    private static func connect() async throws -> DBusConnection {
        let session: DBusConnection
        do {
            session = try await DBusConnection.session()
        } catch {
            throw RPCError(code: RPCErrorCode.failed, message: "Can't reach the D-Bus session bus (\(error)); Linux desktop apps need a graphical session.")
        }
        defer { session.close() }
        let address: String?
        do {
            address = try await session.call("org.a11y.Bus", "/org/a11y/bus", "org.a11y.Bus", "GetAddress").first?.string
        } catch {
            throw RPCError(code: RPCErrorCode.failed, message: "The accessibility bus isn't running (\(error)); install at-spi2-core.")
        }
        guard let address, !address.isEmpty else {
            throw RPCError(code: RPCErrorCode.failed, message: "The accessibility bus gave no address; install at-spi2-core.")
        }
        return try await DBusConnection.connect(to: address)
    }
}

/// An app that publishes an accessibility tree.
public struct ATSPIApp: Sendable, Equatable {
    /// The app's name on the accessibility bus, e.g. `:1.259`.
    public var bus: String
    /// The name it gives itself, e.g. `org.gnome.Nautilus`.
    public var name: String
    public var pid: Int32?
}

/// An element in an app's accessibility tree, as the cache or a walk describes it.
struct ATSPIItem: Sendable, Equatable {
    var path: String
    var parent: String
    var index: Int
    var childCount: Int
    var interfaces: Set<String>
    var name: String
    var role: UInt32
    var description: String
    var states: ATSPIStates
    /// Children in order, when the source lists them rather than giving indexes.
    var children: [String]?
}

/// A set of AT-SPI states, as their numbers.
struct ATSPIStates: Sendable, Equatable {
    var bits: UInt64

    init(bits: UInt64) {
        self.bits = bits
    }

    /// The states from the two 32-bit words AT-SPI sends.
    init(words: [Int]) {
        let low = UInt64(UInt32(truncatingIfNeeded: words.first ?? 0))
        let high = UInt64(UInt32(truncatingIfNeeded: words.dropFirst().first ?? 0))
        bits = low | high << 32
    }

    func contains(_ state: ATSPIState) -> Bool {
        bits & (1 << state.rawValue) != 0
    }
}

/// The AT-SPI states the harness reads.
enum ATSPIState: UInt64 {
    case active = 1, checked = 4, collapsed = 5, defunct = 6, editable = 7, enabled = 8, expandable = 9, expanded = 10
    case focusable = 11, focused = 12, iconified = 15, modal = 16, multiLine = 17, pressed = 20, selectable = 22
    case selected = 23, sensitive = 24, showing = 25, singleLine = 26, visible = 30, indeterminate = 32
    case readOnly = 43, checkable = 41, hasPopup = 42
}

/// Reading apps and trees over the accessibility bus.
enum ATSPI {
    static let root = "/org/a11y/atspi/accessible/root"
    static let accessible = "org.a11y.atspi.Accessible"
    static let timeout = Duration.seconds(3)

    /// Every app on the bus with its process.
    static func apps(on connection: DBusConnection) async throws -> [ATSPIApp] {
        let children = try await connection.call("org.a11y.atspi.Registry", root, accessible, "GetChildren", timeout: timeout)
        let buses = (children.first?.elements ?? []).compactMap { $0.fields?.first?.string }
        return await withTaskGroup(of: (Int, ATSPIApp).self) { group in
            for (index, bus) in buses.enumerated() {
                group.addTask {
                    async let name = try? connection.property(bus, root, accessible, "Name", timeout: timeout).string
                    async let pid = try? connection.call(
                        "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "GetConnectionUnixProcessID",
                        [.string(bus)], timeout: timeout
                    ).first?.int
                    return (index, ATSPIApp(bus: bus, name: await name ?? "", pid: await pid.map { Int32(truncatingIfNeeded: $0) }))
                }
            }
            var apps: [(Int, ATSPIApp)] = []
            for await app in group { apps.append(app) }
            return apps.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    /// Every element of an app: from its cache in one call, or by walking the tree when it
    /// has no cache.
    static func items(of bus: String, on connection: DBusConnection, below start: String = root, limit: Int = 20_000) async throws -> [ATSPIItem] {
        do {
            let reply = try await connection.call(bus, "/org/a11y/atspi/cache", "org.a11y.atspi.Cache", "GetItems", timeout: timeout)
            let items = (reply.first?.elements ?? []).compactMap(item(fromCache:))
            let gaps = incomplete(items)
            if !items.isEmpty, gaps.isEmpty { return items }
            if !items.isEmpty, gaps.count <= 40 { return await filled(items, gaps: gaps, bus: bus, on: connection, limit: limit) }
        } catch DBusError.failed {
        }
        return try await walk(bus, on: connection, from: start, limit: limit)
    }

    /// The elements whose children aren't all in the cache. GTK 4 fills its cache as elements are
    /// first asked about, so just after an app starts or a popover opens some are missing until a
    /// walk below them.
    static func incomplete(_ items: [ATSPIItem]) -> [ATSPIItem] {
        let children = children(of: items)
        return items.filter { $0.childCount > (children[$0.path]?.count ?? 0) }
    }

    /// The cache's items with what's missing below `gaps` walked and added.
    static func filled(_ items: [ATSPIItem], gaps: [ATSPIItem], bus: String, on connection: DBusConnection, limit: Int) async -> [ATSPIItem] {
        let walked = await withTaskGroup(of: [ATSPIItem].self) { group in
            for gap in gaps {
                group.addTask { (try? await walk(bus, on: connection, from: gap.path, limit: limit)) ?? [] }
            }
            var all: [[ATSPIItem]] = []
            for await items in group { all.append(items) }
            return all
        }
        var merged = Dictionary(items.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        for (gap, found) in zip(gaps, walked) where !found.isEmpty {
            for var item in found {
                if item.path == gap.path {
                    item.parent = gap.parent
                    item.index = gap.index
                }
                merged[item.path] = item
            }
        }
        return Array(merged.values)
    }

    /// An item from the cache's `((so)(so)(so)iiassusau)` entry, or the older
    /// `((so)(so)(so)a(so)assusau)` one that lists children.
    static func item(fromCache value: DBusValue) -> ATSPIItem? {
        guard let fields = value.fields, fields.count >= 9,
              let path = fields[0].fields?.last?.string, let parent = fields[2].fields?.last?.string else { return nil }
        if fields.count >= 10, let index = fields[3].int, let childCount = fields[4].int {
            return ATSPIItem(
                path: path, parent: parent, index: index, childCount: childCount,
                interfaces: Set((fields[5].elements ?? []).compactMap(\.string)), name: fields[6].string ?? "",
                role: UInt32(fields[7].int ?? 0), description: fields[8].string ?? "",
                states: ATSPIStates(words: (fields[9].elements ?? []).compactMap(\.int)), children: nil
            )
        }
        guard let children = fields[3].elements else { return nil }
        let paths = children.compactMap { $0.fields?.last?.string }
        return ATSPIItem(
            path: path, parent: parent, index: -1, childCount: paths.count,
            interfaces: Set((fields[4].elements ?? []).compactMap(\.string)), name: fields[5].string ?? "",
            role: UInt32(fields[6].int ?? 0), description: fields[7].string ?? "",
            states: ATSPIStates(words: (fields[8].elements ?? []).compactMap(\.int)), children: paths
        )
    }

    /// Walks the tree a level at a time, asking about every element of a level at once, down to
    /// `depth` levels.
    static func walk(
        _ bus: String, on connection: DBusConnection, from start: String, limit: Int, depth: Int = .max
    ) async throws -> [ATSPIItem] {
        var items: [ATSPIItem] = []
        var level: [(path: String, parent: String, index: Int)] = [(start, "", 0)]
        var levels = 0
        while !level.isEmpty, items.count < limit, levels < depth {
            levels += 1
            let read = await withTaskGroup(of: (Int, ATSPIItem?).self) { group in
                for (position, entry) in level.prefix(limit - items.count).enumerated() {
                    group.addTask {
                        (position, await describe(entry.path, parent: entry.parent, index: entry.index, bus: bus, on: connection))
                    }
                }
                var read: [(Int, ATSPIItem?)] = []
                for await item in group { read.append(item) }
                return read.sorted { $0.0 < $1.0 }.compactMap(\.1)
            }
            items += read
            level = read.flatMap { item in
                (item.children ?? []).enumerated().map { (path: $1, parent: item.path, index: $0) }
            }
        }
        return items
    }

    static func describe(_ path: String, parent: String, index: Int, bus: String, on connection: DBusConnection) async -> ATSPIItem? {
        async let children = try? connection.call(bus, path, accessible, "GetChildren", timeout: timeout)
        async let role = try? connection.call(bus, path, accessible, "GetRole", timeout: timeout)
        async let states = try? connection.call(bus, path, accessible, "GetState", timeout: timeout)
        async let interfaces = try? connection.call(bus, path, accessible, "GetInterfaces", timeout: timeout)
        async let name = try? connection.property(bus, path, accessible, "Name", timeout: timeout)
        async let description = try? connection.property(bus, path, accessible, "Description", timeout: timeout)
        guard let roleNumber = await role?.first?.int else { return nil }
        let paths = (await children?.first?.elements ?? []).compactMap { $0.fields?.last?.string }
        return ATSPIItem(
            path: path, parent: parent, index: index, childCount: paths.count,
            interfaces: Set((await interfaces?.first?.elements ?? []).compactMap(\.string)), name: await name?.string ?? "",
            role: UInt32(roleNumber), description: await description?.string ?? "",
            states: ATSPIStates(words: (await states?.first?.elements ?? []).compactMap(\.int)), children: paths
        )
    }

    /// Each item's children in order.
    static func children(of items: [ATSPIItem]) -> [String: [String]] {
        var children: [String: [(index: Int, path: String)]] = [:]
        for item in items {
            if let listed = item.children { children[item.path] = listed.enumerated().map { ($0, $1) } }
        }
        let listedParents = Set(children.keys)
        for item in items where item.children == nil && item.index >= 0 && !listedParents.contains(item.parent) {
            children[item.parent, default: []].append((item.index, item.path))
        }
        return children.mapValues { $0.sorted { $0.index < $1.index }.map(\.path) }
    }
}
