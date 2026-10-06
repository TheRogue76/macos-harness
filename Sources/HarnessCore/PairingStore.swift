import Foundation

/// Agents the user has approved, kept in the helper's defaults.
public final class PairingStore: @unchecked Sendable {
    public struct Pairing: Codable, Sendable, Equatable {
        public var key: String
        public var displayName: String
        public var approvedAt: Date
    }

    private let defaults: UserDefaults
    private let storageKey = "pairedAgents"
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var all: [Pairing] {
        lock.withLock { load() }.sorted { $0.approvedAt < $1.approvedAt }
    }

    public func isPaired(_ key: String) -> Bool {
        lock.withLock { load().contains { $0.key == key } }
    }

    public func approve(key: String, displayName: String) {
        lock.withLock {
            var pairings = load().filter { $0.key != key }
            pairings.append(Pairing(key: key, displayName: displayName, approvedAt: Date()))
            save(pairings)
        }
    }

    public func revoke(key: String) {
        lock.withLock { save(load().filter { $0.key != key }) }
    }

    private func load() -> [Pairing] {
        guard let data = defaults.data(forKey: storageKey) else { return [] }
        return (try? JSONDecoder().decode([Pairing].self, from: data)) ?? []
    }

    private func save(_ pairings: [Pairing]) {
        defaults.set(try? JSONEncoder().encode(pairings), forKey: storageKey)
    }
}
