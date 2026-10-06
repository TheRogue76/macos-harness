import ApplicationServices
import Foundation

/// Hands out refs (`e1`, `e2`, …) per app and remembers which element each one means.
/// The same element keeps its ref across snapshots for as long as it exists.
public final class ElementRegistry: @unchecked Sendable {
    public static let shared = ElementRegistry()

    struct Entry {
        var key: AnyHashable
        var element: AXUIElement?
        var lastUsed: Date
    }

    private struct AppRefs {
        var next = 1
        var byKey: [AnyHashable: String] = [:]
        var byRef: [String: Entry] = [:]
    }

    private var apps: [pid_t: AppRefs] = [:]
    private let lock = NSLock()
    private let capacity: Int

    public init(capacity: Int = 5000) {
        self.capacity = capacity
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
            let ref = "e\(refs.next)"
            refs.next += 1
            refs.byKey[key] = ref
            refs.byRef[ref] = Entry(key: key, element: element, lastUsed: Date())
            if refs.byRef.count > capacity {
                evictOldest(&refs)
            }
            return ref
        }
    }

    public func element(for ref: String, pid: pid_t) -> AXUIElement? {
        lock.withLock { apps[pid]?.byRef[ref]?.element }
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
