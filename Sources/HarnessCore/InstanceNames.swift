import Foundation

/// Short names that tell running sessions of the same agent apart: the folder each works in,
/// numbered when two share one.
public struct InstanceNames: Sendable {
    private var names: [String: String] = [:]

    public init() {}

    /// The name for an agent process, keeping the one it already has. Empty when it has no
    /// folder and no other session of its agent needs telling apart.
    public mutating func name(for instanceKey: String, folder: String?, isRunning: (String) -> Bool) -> String {
        names = names.filter { $0.key == instanceKey || isRunning($0.key) }
        if let existing = names[instanceKey] { return existing }
        let kind = Self.kindKey(of: instanceKey)
        let taken = Set(names.filter { Self.kindKey(of: $0.key) == kind }.values)
        let base = folder ?? ""
        var name = base
        var number = 2
        while taken.contains(name) {
            name = base.isEmpty ? "\(number)" : "\(base) \(number)"
            number += 1
        }
        names[instanceKey] = name
        return name
    }

    /// The agent's key in an instance key ("Claude Code|TEAM|id#4211" → "Claude Code|TEAM|id").
    public static func kindKey(of instanceKey: String) -> String {
        guard let hash = instanceKey.lastIndex(of: "#") else { return instanceKey }
        return String(instanceKey[..<hash])
    }

    /// The agent process in an instance key, or nil when it has none.
    public static func pid(of instanceKey: String) -> pid_t? {
        guard let hash = instanceKey.lastIndex(of: "#"), let pid = pid_t(instanceKey[instanceKey.index(after: hash)...]), pid > 0 else {
            return nil
        }
        return pid
    }
}

/// Which callers a set of stops covers.
public enum StopRules {
    /// Whether stops, by instance key or by an agent's key, cover a caller: its session, its whole
    /// agent, or a stopped session whose process it descends from.
    public static func covers(_ caller: CallerIdentity, stopped keys: some Collection<String>) -> Bool {
        let keys = Set(keys)
        if keys.contains(caller.instanceKey) || keys.contains(caller.key) { return true }
        let stoppedProcesses = Set(keys.compactMap(InstanceNames.pid(of:)))
        return caller.chain.contains { stoppedProcesses.contains($0.pid) }
    }
}
