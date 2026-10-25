import ApplicationServices
import Foundation
import HarnessCore

extension ElementRegistry {
    /// The ref for an element read through AX; the element itself comes back through `key`.
    public func ref(for key: AnyHashable, element: AXUIElement?, pid: pid_t) -> String {
        ref(for: key, pid: pid)
    }

    /// The AX element a ref names, or nil when it names none (an unknown or stale ref, or an
    /// element read some other way).
    public func element(for ref: String, pid: pid_t) -> AXUIElement? {
        guard case .found(let key) = lookup(ref, pid: pid) else { return nil }
        return (key.base as? ElementKey)?.element
    }
}
