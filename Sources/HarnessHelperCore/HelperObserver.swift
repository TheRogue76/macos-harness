import Foundation
import HarnessCore
import HarnessProtocol

/// Refuses requests from stopped agents and feeds the activity log; the panel and on-screen
/// feedback update after the reply, so agents don't wait for them.
package struct HelperObserver: RequestObserver {
    let activity: ActivityCenter
    let policy: PolicyStore
    let journal: Journal
    /// Where the user stops agents, for the refusal, e.g. " from the macOS Harness menu bar".
    let whereStopped: String

    package init(
        activity: ActivityCenter, policy: PolicyStore, journal: Journal,
        whereStopped: String = " from the macOS Harness menu bar (or with ⌃⌥⌘.)"
    ) {
        self.activity = activity
        self.policy = policy
        self.journal = journal
        self.whereStopped = whereStopped
    }

    package func refusal(for request: RPCRequest, context: RequestContext) async -> RPCError? {
        if await activity.isStopped(context.caller) {
            return RPCError(
                code: RPCErrorCode.stoppedByUser,
                message: "The user stopped \(context.caller.displayName)\(whereStopped). Ask them to resume it before trying again."
            )
        }
        return await PolicyEnforcer.refusal(for: request, store: policy, restrictions: context.connection.restrictions)
    }

    package func didHandle(_ request: RPCRequest, context: RequestContext, response: RPCResponse, milliseconds: Int) async {
        await journal.record(request, response: response, caller: context.caller, milliseconds: milliseconds)
        if let window = response.result?["window"].flatMap({ try? $0.decode(as: WindowInfo.self) }) {
            await WindowClaims.shared.renew(WindowClaims.key(for: window), owner: context.caller.instanceKey)
        }
        let caller = context.caller
        Task { @MainActor [activity] in
            let instance = activity.instanceName(for: caller)
            guard let entry = ActivityDescriber.entry(
                for: request, response: response, agentKey: caller.instanceKey, agentName: caller.displayName, instance: instance
            ) else { return }
            activity.record(entry)
        }
    }
}
