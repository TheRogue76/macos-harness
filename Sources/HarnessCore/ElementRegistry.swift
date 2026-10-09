import ApplicationServices
import Foundation

/// Hands out refs like `k12` and remembers which element each one means. An element keeps its ref
/// while it exists, and a ref never names a different element, even after the helper or the app
/// restarts.
public final class ElementRegistry: @unchecked Sendable {
    public static let shared = ElementRegistry(tag: ElementRegistry.launchTag())

    public enum Lookup {
        case found(AXUIElement)
        /// From an earlier helper launch.
        case stale
        case unknown
    }

    struct Entry {
        var key: AnyHashable
        var element: AXUIElement?
        var lastUsed: Date
    }

    private struct AppRefs {
        var byKey: [AnyHashable: String] = [:]
        var byRef: [String: Entry] = [:]
    }

    public let tag: Character
    private var next = 1
    private var apps: [pid_t: AppRefs] = [:]
    private let lock = NSLock()
    private let capacity: Int

    public init(capacity: Int = 5000, tag: Character = "e") {
        self.capacity = capacity
        self.tag = tag
    }

    /// The letter for this helper launch, different from the previous launch's.
    public static func launchTag(defaults: UserDefaults = .standard) -> Character {
        let letters = Array("abcdfghjkmnpqrstuvwxyz")
        let index = (defaults.integer(forKey: "refTagIndex") + 1) % letters.count
        defaults.set(index, forKey: "refTagIndex")
        return letters[index]
    }

    /// The ref for this element, creating one if it's new.
    public func ref(for key: AnyHashable, element: AXUIElement?, pid: pid_t) -> String {
        lock.withLock {
            var refs = apps[pid] ?? AppRefs()
            defer { apps[pid] = refs }
            if let existing = refs.byKey[key] {
                refs.byRef[existing]?.lastUsed = Date()
                return existing
            }
            let ref = "\(tag)\(next)"
            next += 1
            refs.byKey[key] = ref
            refs.byRef[ref] = Entry(key: key, element: element, lastUsed: Date())
            if refs.byRef.count > capacity {
                evictOldest(&refs)
            }
            return ref
        }
    }

    public func lookup(_ ref: String, pid: pid_t) -> Lookup {
        lock.withLock {
            if let element = apps[pid]?.byRef[ref]?.element {
                return .found(element)
            }
            if let first = ref.first, first != tag, first.isLetter, Int(ref.dropFirst()) != nil {
                return .stale
            }
            return .unknown
        }
    }

    /// The identity a ref was handed out for, for elements without an AX handle (Android nodes).
    public func key(for ref: String, pid: pid_t) -> AnyHashable? {
        lock.withLock { apps[pid]?.byRef[ref]?.key }
    }

    /// Whether a ref looks like one from an earlier helper launch.
    public func isStale(_ ref: String) -> Bool {
        guard let first = ref.first else { return false }
        return first != tag && first.isLetter && Int(ref.dropFirst()) != nil
    }

    public func element(for ref: String, pid: pid_t) -> AXUIElement? {
        if case .found(let element) = lookup(ref, pid: pid) { return element }
        return nil
    }

    /// Forget apps that are no longer running.
    public func prune(keeping running: Set<pid_t>) {
        lock.withLock { apps = apps.filter { running.contains($0.key) } }
    }

    private func evictOldest(_ refs: inout AppRefs) {
        let oldest = refs.byRef.sorted { $0.value.lastUsed < $1.value.lastUsed }.prefix(capacity / 5)
        for (ref, entry) in oldest {
            refs.byRef.removeValue(forKey: ref)
            refs.byKey.removeValue(forKey: entry.key)
        }
    }
}
