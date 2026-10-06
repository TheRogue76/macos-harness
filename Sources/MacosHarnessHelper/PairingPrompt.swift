import AppKit
import HarnessCore
import HarnessProtocol

/// Asks the user, once per agent, whether it may use the helper.
/// Concurrent requests from the same agent share one prompt.
@MainActor
final class PairingPrompt: PairingGate {
    private let store: PairingStore
    private var waiting: [String: [CheckedContinuation<Bool, Never>]] = [:]

    init(store: PairingStore) {
        self.store = store
    }

    nonisolated func isPaired(_ caller: CallerIdentity) async -> Bool {
        store.isPaired(caller.key)
    }

    nonisolated func requestApproval(for caller: CallerIdentity) async -> Bool {
        await ask(caller)
    }

    private func ask(_ caller: CallerIdentity) async -> Bool {
        if store.isPaired(caller.key) { return true }
        return await withCheckedContinuation { continuation in
            if waiting[caller.key] != nil {
                waiting[caller.key]?.append(continuation)
                return
            }
            waiting[caller.key] = [continuation]
            // Show the alert on the next run loop turn so this call returns first.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.presentAlert(for: caller) }
            }
        }
    }

    private func presentAlert(for caller: CallerIdentity) {
        let alert = NSAlert()
        alert.messageText = "Allow “\(caller.displayName)” to use macOS Harness?"
        let chain = caller.chain.map(\.name).joined(separator: " ← ")
        alert.informativeText = """
            It will be able to see and control apps on this Mac using the permissions you gave macOS Harness. \
            You only need to approve it once; revoke it any time from the menu bar icon.

            Process chain: \(chain)
            Identity: \(caller.key)
            """
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don't Allow")
        NSApp.activate()
        let allowed = alert.runModal() == .alertFirstButtonReturn
        if allowed {
            store.approve(key: caller.key, displayName: caller.displayName)
        }
        for continuation in waiting.removeValue(forKey: caller.key) ?? [] {
            continuation.resume(returning: allowed)
        }
    }
}
