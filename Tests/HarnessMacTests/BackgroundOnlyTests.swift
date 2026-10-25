import Foundation
@testable import HarnessClient
import HarnessProtocol
import Testing
@testable import HarnessCore
@testable import HarnessMac

struct BackgroundOnlyTests {
    private func request(_ method: String, _ params: [String: JSONValue]) -> RPCRequest {
        RPCRequest(id: 1, method: method, params: .object(params.merging(["target": .object(["app": .string("Notes")])]) { $1 }))
    }

    @Test func thePolicyFileCanTurnItOn() throws {
        #expect(try Policy.parse("background_only: true\n").backgroundOnly)
        #expect(try !Policy.parse("blocked: []\n").backgroundOnly)
        #expect(try Policy.parse(Policy.template) == .empty)
        #expect(throws: Policy.ParseError.self) { try Policy.parse("background-only: true\n") }
    }

    @Test func connectionsCanOnlyTurnItOn() {
        let on = PolicyRestrictions(backgroundOnly: true)
        #expect(!on.isEmpty)
        #expect(PolicyRestrictions().adding(on).backgroundOnly == true)
        #expect(on.adding(PolicyRestrictions(backgroundOnly: false)).backgroundOnly == true)
        #expect(Policy.empty.adding(on).backgroundOnly)
        #expect(Policy(blocked: [], readOnly: [], backgroundOnly: true).adding(PolicyRestrictions()).backgroundOnly)
    }

    @Test func askingForTheFrontOrTheRealMouseIsRefused() {
        let refused = [
            request(WindowActionMethod.name, ["action": .string("activate")]),
            request(LaunchMethod.name, ["activate": .bool(true)]),
            request(ActMethod.name, ["action": .string("type"), "real": .bool(true)]),
            request(PointerMethod.name, ["action": .string("click"), "real": .bool(true)]),
        ]
        for item in refused {
            #expect(PolicyEnforcer.backgroundOnlyRefusal(for: item)?.code == RPCErrorCode.blockedByPolicy)
        }
        let allowed = [
            request(WindowActionMethod.name, ["action": .string("minimize")]),
            request(LaunchMethod.name, ["activate": .bool(false)]),
            request(ActMethod.name, ["action": .string("press")]),
            request(PointerMethod.name, ["action": .string("click")]),
            request(SnapshotMethod.name, [:]),
        ]
        for item in allowed {
            #expect(PolicyEnforcer.backgroundOnlyRefusal(for: item) == nil)
        }
    }

    @Test func realInputIsRefusedBeforeItStarts() async {
        let context = ActionContext(owner: "s1", ownerName: "Agent", backgroundOnly: true) { false }
        let app = AppRef(name: "Notes", bundleIdentifier: nil, pid: 1)
        do {
            _ = try await RealInputSession.begin(app: app, window: nil, context: context, keyboard: false)
            Issue.record("expected a refusal")
        } catch let error as RPCError {
            #expect(error.code == RPCErrorCode.blockedByPolicy)
            #expect(error.message.contains("real mouse"))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func flowsCanWorkInTheBackgroundOnly() throws {
        let flow = try FlowParser.parse("app: X\npolicy:\n  background_only: true\nsteps:\n  - press: Save\n")
        #expect(flow.restrictions.backgroundOnly == true)
        #expect(throws: FlowError.self) { try FlowParser.parse("app: X\npolicy:\n  background: true\nsteps:\n  - press: Save\n") }
    }

    @Test func doctorSaysSo() {
        let status = DoctorMethod.PolicyStatus(path: "/tmp/policy.yaml", exists: false, blocked: [], readOnly: [], error: nil, backgroundOnly: true)
        #expect(Render.policy(status).contains("background only"))
        let off = DoctorMethod.PolicyStatus(path: "/tmp/policy.yaml", exists: false, blocked: [], readOnly: [], error: nil)
        #expect(!Render.policy(off).contains("background only"))
    }
}
