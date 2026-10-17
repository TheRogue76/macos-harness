import AppKit
import Foundation
import HarnessProtocol
import Yams

/// The user's rules for which apps agents may use, from `policy.yaml`.
public struct Policy: Codable, Equatable, Sendable {
    /// Apps agents can't see or act on, by name or bundle ID.
    public var blocked: [String]
    /// Apps agents can read but not act on, by name or bundle ID.
    public var readOnly: [String]
    /// Agents work in the background only: accessibility and background clicks, scrolls and keys,
    /// never the real mouse or keyboard, and no bringing apps to the front.
    public var backgroundOnly: Bool

    public enum Access: Equatable, Sendable {
        case full, readOnly, blocked
    }

    enum CodingKeys: String, CodingKey {
        case blocked
        case readOnly = "read_only"
        case backgroundOnly = "background_only"
    }

    public static let empty = Policy(blocked: [], readOnly: [])

    /// This policy with `restrictions` added on top.
    public func adding(_ restrictions: PolicyRestrictions) -> Policy {
        let combined = PolicyRestrictions(blocked: blocked, readOnly: readOnly, backgroundOnly: backgroundOnly ? true : nil).adding(restrictions)
        return Policy(blocked: combined.blocked, readOnly: combined.readOnly, backgroundOnly: combined.backgroundOnly == true)
    }

    /// The file the helper creates when the user first edits the policy.
    public static let template = """
        # macOS Harness policy: which apps agents may use, by name or bundle ID.
        # Agents can't see or touch blocked apps. They can read read-only apps
        # (snapshot, find, screenshot, menu) but not act on them.
        # background_only: true keeps every agent off the real mouse and keyboard
        # and stops them bringing apps to the front.
        blocked: []
        read_only: []

        """

    public init(blocked: [String], readOnly: [String], backgroundOnly: Bool = false) {
        self.blocked = blocked
        self.readOnly = readOnly
        self.backgroundOnly = backgroundOnly
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        blocked = try container.decodeIfPresent([String].self, forKey: .blocked) ?? []
        readOnly = try container.decodeIfPresent([String].self, forKey: .readOnly) ?? []
        backgroundOnly = try container.decodeIfPresent(Bool.self, forKey: .backgroundOnly) ?? false
    }

    public struct ParseError: Error, CustomStringConvertible {
        public var description: String
    }

    /// Parses the YAML text of a policy file; an empty file is the empty policy. Unknown keys are
    /// errors, so a misspelled `read_only` can't silently leave an app open.
    public static func parse(_ text: String) throws -> Policy {
        guard let document = try Yams.load(yaml: text) else { return .empty }
        guard let keys = (document as? [String: Any])?.keys else {
            throw ParseError(description: "expected `blocked:` and `read_only:` lists at the top level")
        }
        let known: Set<String> = [CodingKeys.blocked.rawValue, CodingKeys.readOnly.rawValue, CodingKeys.backgroundOnly.rawValue]
        if let unknown = keys.sorted().first(where: { !known.contains($0) }) {
            throw ParseError(description: "unknown key `\(unknown)`; use `blocked`, `read_only` and `background_only`")
        }
        return try YAMLDecoder().decode(Policy.self, from: text)
    }

    /// How agents may treat an app known by any of `names` (its name, bundle ID, or what the agent asked for).
    public func access(_ names: [String?]) -> Access {
        let keys = Set(names.compactMap { $0?.lowercased() })
        func listed(_ entries: [String]) -> Bool { entries.contains { keys.contains($0.lowercased()) } }
        if listed(blocked) { return .blocked }
        if listed(readOnly) { return .readOnly }
        return .full
    }
}

/// Reads the policy file, again whenever it changes.
public final class PolicyStore: @unchecked Sendable {
    public let path: String
    private let lock = NSLock()
    private var cached: (modified: Date?, result: Result<Policy, PolicyError>)?

    public struct PolicyError: Error, Equatable {
        public var message: String
    }

    public init(path: String = HarnessPaths.policyFile()) {
        self.path = path
    }

    /// The current policy, the empty one when there's no file, or why the file can't be used.
    public func current() -> Result<Policy, PolicyError> {
        let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        return lock.withLock {
            if let cached, cached.modified == modified { return cached.result }
            let result = Self.load(path: path, exists: modified != nil)
            cached = (modified, result)
            return result
        }
    }

    public var status: DoctorMethod.PolicyStatus {
        let exists = FileManager.default.fileExists(atPath: path)
        switch current() {
        case .success(let policy):
            return .init(
                path: path, exists: exists, blocked: policy.blocked, readOnly: policy.readOnly, error: nil,
                backgroundOnly: policy.backgroundOnly ? true : nil
            )
        case .failure(let error):
            return .init(path: path, exists: exists, blocked: [], readOnly: [], error: error.message)
        }
    }

    static func load(path: String, exists: Bool) -> Result<Policy, PolicyError> {
        guard exists else { return .success(.empty) }
        do {
            return .success(try Policy.parse(try String(contentsOfFile: path, encoding: .utf8)))
        } catch {
            return .failure(PolicyError(message: String(describing: error)))
        }
    }
}

/// Applies the policy to requests.
public enum PolicyEnforcer {
    /// Methods that change an app rather than read it.
    public static let actionMethods: Set<String> = [
        ActMethod.name, PointerMethod.name, MenuSelectMethod.name, WindowActionMethod.name, QuitMethod.name, SimulatorMethod.name,
        AndroidMethod.name, CollectMethod.name,
    ]

    /// The name the policy uses for every Android device.
    public static let androidName = "Android"

    /// The name the policy uses for every iOS Simulator.
    public static let simulatorName = "Simulator"

    /// The app a request targets, as the agent named it.
    public static func targetApp(of request: RPCRequest) -> String? {
        if request.method == SimulatorMethod.name {
            return Target.simulatorPrefix + (request.params?["device"]?.stringValue ?? "booted")
        }
        if request.method == AndroidMethod.name {
            return Target.androidPrefix + (request.params?["device"]?.stringValue ?? "booted")
        }
        return request.params?["target"]?["app"]?.stringValue ?? request.params?["app"]?.stringValue
    }

    /// The method as the policy sees it: a simulator `list` only reads, and reading a menu bar
    /// extra's menu presses the extra.
    static func policyMethod(of request: RPCRequest) -> String {
        if request.method == MenuMethod.name, request.params?["extras"]?.boolValue == true,
           !(request.params?["path"]?.arrayValue ?? []).isEmpty {
            return MenuSelectMethod.name
        }
        if request.method == SimulatorMethod.name,
           let action = request.params?["action"]?.stringValue.flatMap(SimulatorAction.init(rawValue:)),
           SimulatorAction.reading.contains(action) {
            return SnapshotMethod.name
        }
        if request.method == AndroidMethod.name,
           let action = request.params?["action"]?.stringValue.flatMap(AndroidAction.init(rawValue:)),
           AndroidAction.reading.contains(action) {
            return SnapshotMethod.name
        }
        return request.method
    }

    /// Why the policy, plus the connection's own restrictions, refuses `request`, or nil when it's allowed.
    public static func refusal(
        for request: RPCRequest, store: PolicyStore, restrictions: PolicyRestrictions = .init()
    ) async -> RPCError? {
        let policy: Policy
        switch store.current() {
        case .success(let loaded): policy = loaded.adding(restrictions)
        case .failure(let error):
            return RPCError(
                code: RPCErrorCode.blockedByPolicy,
                message: "The macOS Harness policy file (\(store.path)) can't be read, so agents are refused until the user fixes it: \(error.message)"
            )
        }
        if policy.backgroundOnly, let refused = backgroundOnlyRefusal(for: request) { return refused }
        guard policy != .empty, let query = targetApp(of: request) else { return nil }
        var names = await identify(query)
        if request.method == SimulatorMethod.name, let bundle = request.params?["bundleIdentifier"]?.stringValue {
            names.append(bundle)
        }
        if request.method == AndroidMethod.name, let package = request.params?["package"]?.stringValue {
            names.append(package)
        }
        let appName = names.compactMap { $0 }.first ?? query
        let access = policy.access(names)
        let method = policyMethod(of: request)
        if access == .readOnly, request.method == MenuMethod.name, method != request.method {
            return RPCError(
                code: RPCErrorCode.blockedByPolicy,
                message: "\(appName) is read-only for agents in the user's macOS Harness policy: listing its menu bar extras works, but reading one's menu means pressing it, which is an action."
            )
        }
        if let refused = refusal(access: access, appName: appName, method: method) {
            return refused
        }
        guard let destination = dropApp(of: request) else { return nil }
        let dropNames = await identify(destination)
        return refusal(access: policy.access(dropNames), appName: dropNames.compactMap { $0 }.first ?? destination, method: request.method)
    }

    /// Whether agents work in the background only, by the policy file or a connection's restrictions.
    public static func isBackgroundOnly(store: PolicyStore, restrictions: PolicyRestrictions) -> Bool {
        if restrictions.backgroundOnly == true { return true }
        if case .success(let policy) = store.current() { return policy.backgroundOnly }
        return false
    }

    /// Why a request that asks outright for the real mouse or keyboard, or for an app to come to the
    /// front, is refused while agents work in the background only; nil for any other request.
    public static func backgroundOnlyRefusal(for request: RPCRequest) -> RPCError? {
        let params = request.params
        let asked: String?
        switch request.method {
        case WindowActionMethod.name where params?["action"]?.stringValue == WindowActionMethod.Action.activate.rawValue:
            asked = "bring a window to the front"
        case LaunchMethod.name where params?["activate"]?.boolValue == true:
            asked = "bring an app to the front"
        case ActMethod.name where params?["real"]?.boolValue == true, PointerMethod.name where params?["real"]?.boolValue == true:
            asked = "use the real mouse and keyboard"
        default:
            asked = nil
        }
        return asked.map { RPCError(code: RPCErrorCode.blockedByPolicy, message: backgroundOnlyMessage("can't \($0)")) }
    }

    /// The message for a step refused because agents work in the background only.
    public static func backgroundOnly(_ step: String) -> RPCError {
        RPCError(code: RPCErrorCode.blockedByPolicy, message: backgroundOnlyMessage(step))
    }

    static func backgroundOnlyMessage(_ what: String) -> String {
        "Agents work in the background only here (background_only in the macOS Harness policy, or --background-only), so this \(what). Use accessibility actions (act) and clicks, scrolls and keys that go to the window in the background."
    }

    /// The app a drag ends in, as the agent named it, when that's another app or window.
    public static func dropApp(of request: RPCRequest) -> String? {
        guard request.method == PointerMethod.name, request.params?["action"]?.stringValue == PointerAction.drag.rawValue else { return nil }
        return request.params?["toTarget"]?["app"]?.stringValue
    }

    /// Why `access` refuses `method` on the app, or nil when it's allowed.
    public static func refusal(access: Policy.Access, appName: String, method: String) -> RPCError? {
        switch access {
        case .full:
            return nil
        case .blocked:
            return RPCError(code: RPCErrorCode.blockedByPolicy, message: "The user's macOS Harness policy blocks agents from \(appName).")
        case .readOnly:
            guard actionMethods.contains(method) else { return nil }
            return RPCError(
                code: RPCErrorCode.blockedByPolicy,
                message: "\(appName) is read-only for agents in the user's macOS Harness policy: snapshot, find, screenshot and menu work, actions don't."
            )
        }
    }

    /// The running apps the policy, plus the connection's restrictions, leaves visible.
    public static func visible(
        _ apps: [AppsMethod.App], store: PolicyStore, restrictions: PolicyRestrictions = .init()
    ) -> [AppsMethod.App] {
        guard case .success(let loaded) = store.current() else { return apps }
        let policy = loaded.adding(restrictions)
        guard policy != .empty else { return apps }
        return apps.filter { policy.access([$0.name, $0.bundleIdentifier]) != .blocked }
    }

    /// The app's name and bundle ID, plus the query, whether it's running or only installed.
    static func identify(_ query: String) async -> [String?] {
        if Target.simulatorDevice(in: query) != nil {
            return [simulatorName, query]
        }
        if Target.androidDevice(in: query) != nil {
            return [androidName, query]
        }
        if let app = try? await MainActor.run(body: { try AppResolver.resolve(query) }) {
            return [app.name, app.bundleIdentifier, query]
        }
        if let url = await MainActor.run(body: { AppControl.appURL(for: query) }), let bundle = Bundle(url: url) {
            let name = (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? url.deletingPathExtension().lastPathComponent
            return [name, bundle.bundleIdentifier, query]
        }
        return [query]
    }
}
