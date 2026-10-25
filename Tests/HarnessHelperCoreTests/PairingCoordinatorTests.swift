import Foundation
import HarnessCore
import HarnessProtocol
import Testing
@testable import HarnessHelperCore

@MainActor
struct PairingCoordinatorTests {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "pairing-test-\(UUID())")!
    }

    private func caller(_ name: String, pid: Int32 = getpid()) -> CallerIdentity {
        CallerIdentity(
            displayName: name, key: "\(name)|TEAM|id",
            chain: [ProcessSnapshot(pid: pid, parentPID: 1, path: "/usr/bin/\(name)", arguments: [name])], agentPID: pid
        )
    }

    @Test func asksOnceAndRemembersAnApproval() async {
        let pairing = PairingCoordinator(store: PairingStore(defaults: defaults()))
        var asked: [String] = []
        pairing.onNewRequest = { request in
            asked.append(request.caller.displayName)
            pairing.resolve(request.id, .allow)
        }
        let agent = caller("agent")
        #expect(await pairing.requestApproval(for: agent))
        #expect(await pairing.isPaired(agent))
        #expect(await pairing.requestApproval(for: agent))
        #expect(asked == ["agent"])
        #expect(pairing.paired.map(\.displayName) == ["agent"])
    }

    @Test func deniedCallersStayUnpaired() async {
        let pairing = PairingCoordinator(store: PairingStore(defaults: defaults()))
        pairing.onNewRequest = { pairing.resolve($0.id, .deny) }
        let agent = caller("agent")
        #expect(await pairing.requestApproval(for: agent) == false)
        #expect(await pairing.isPaired(agent) == false)
        #expect(pairing.pending.isEmpty)
    }

    @Test func aSessionApprovalLastsWhileItsProcessRuns() async {
        let pairing = PairingCoordinator(store: PairingStore(defaults: defaults()))
        pairing.onNewRequest = { pairing.resolve($0.id, .session) }
        let agent = caller("agent")
        #expect(await pairing.requestApproval(for: agent))
        #expect(pairing.isApproved(agent))
        #expect(pairing.paired.isEmpty)
    }

    @Test func unattendedHelpersApproveEveryone() async {
        let pairing = PairingCoordinator(store: PairingStore(defaults: defaults()), approvesEveryone: true)
        pairing.onNewRequest = { _ in Issue.record("nobody should be asked") }
        #expect(await pairing.requestApproval(for: caller("anyone")))
    }

    @Test func revokingForgetsAnAgent() async {
        let pairing = PairingCoordinator(store: PairingStore(defaults: defaults()))
        pairing.onNewRequest = { pairing.resolve($0.id, .allow) }
        let agent = caller("agent")
        _ = await pairing.requestApproval(for: agent)
        pairing.revoke(key: agent.key)
        #expect(pairing.isApproved(agent) == false)
    }
}

@MainActor
struct ActivityCenterTests {
    @Test func stopsAreSavedAndRestored() {
        let defaults = UserDefaults(suiteName: "activity-test-\(UUID())")!
        let activity = ActivityCenter(defaults: defaults)
        activity.stop(key: "agent|TEAM|id", name: "Agent")
        #expect(activity.isStopped("agent|TEAM|id"))
        let restarted = ActivityCenter(defaults: defaults)
        #expect(restarted.isStopped("agent|TEAM|id"))
        restarted.stopAll()
        #expect(ActivityCenter(defaults: defaults).allStopped)
        restarted.resumeAll()
        #expect(ActivityCenter(defaults: defaults).isStopped("agent|TEAM|id") == false)
    }
}
