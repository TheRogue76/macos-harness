import Foundation
import HarnessProtocol
import Testing
@testable import HarnessCore

struct PolicyTests {
    @Test func parsesBothLists() throws {
        let policy = try Policy.parse("""
        blocked:
          - com.apple.Passwords
        read_only:
          - Mail
          - Messages
        """)
        #expect(policy.blocked == ["com.apple.Passwords"])
        #expect(policy.readOnly == ["Mail", "Messages"])
    }

    @Test func emptyFilesAndCommentsAreTheEmptyPolicy() throws {
        #expect(try Policy.parse("") == .empty)
        #expect(try Policy.parse("# nothing yet\n") == .empty)
        #expect(try Policy.parse("blocked: []\n") == .empty)
        #expect(try Policy.parse(Policy.template) == .empty)
    }

    @Test func misspelledKeysAreErrors() {
        #expect(throws: Policy.ParseError.self) { try Policy.parse("readonly:\n  - Mail\n") }
        #expect(throws: (any Error).self) { try Policy.parse("- Mail\n") }
        #expect(throws: (any Error).self) { try Policy.parse("blocked: Mail\n") }
    }

    @Test func matchesNamesAndBundleIDsCaseInsensitively() {
        let policy = Policy(blocked: ["com.apple.Passwords"], readOnly: ["mail", "com.apple.MobileSMS"])
        #expect(policy.access(["Passwords", "com.apple.passwords"]) == .blocked)
        #expect(policy.access(["Mail", "com.apple.mail"]) == .readOnly)
        #expect(policy.access(["Messages", "com.apple.MobileSMS"]) == .readOnly)
        #expect(policy.access(["Calculator", "com.apple.calculator"]) == .full)
        #expect(Policy(blocked: ["Mail"], readOnly: ["Mail"]).access(["Mail"]) == .blocked)
    }

    @Test func readOnlyAppsRefuseActionsButNotReading() {
        let act = PolicyEnforcer.refusal(access: .readOnly, appName: "Mail", method: ActMethod.name)
        #expect(act?.code == RPCErrorCode.blockedByPolicy)
        for method in [PointerMethod.name, MenuSelectMethod.name, WindowActionMethod.name, QuitMethod.name] {
            #expect(PolicyEnforcer.refusal(access: .readOnly, appName: "Mail", method: method) != nil)
        }
        for method in [SnapshotMethod.name, FindMethod.name, ScreenshotMethod.name, MenuMethod.name, WaitMethod.name, LaunchMethod.name] {
            #expect(PolicyEnforcer.refusal(access: .readOnly, appName: "Mail", method: method) == nil)
        }
        #expect(PolicyEnforcer.refusal(access: .blocked, appName: "Passwords", method: SnapshotMethod.name) != nil)
        #expect(PolicyEnforcer.refusal(access: .full, appName: "Calculator", method: ActMethod.name) == nil)
    }

    @Test func findsTheTargetAppInEitherParamShape() throws {
        let act = RPCRequest(id: 1, method: ActMethod.name, params: .object(["target": .object(["app": .string("Mail")])]))
        let menu = RPCRequest(id: 2, method: MenuSelectMethod.name, params: .object(["app": .string("Notes")]))
        #expect(PolicyEnforcer.targetApp(of: act) == "Mail")
        #expect(PolicyEnforcer.targetApp(of: menu) == "Notes")
        #expect(PolicyEnforcer.targetApp(of: RPCRequest(id: 3, method: AppsMethod.name, params: nil)) == nil)
    }

    @Test func aDragCantEndInAnAppThePolicyProtects() async throws {
        let path = NSTemporaryDirectory() + "policy-\(UUID().uuidString).yaml"
        defer { try? FileManager.default.removeItem(atPath: path) }
        try "blocked: [NoSuchVault]\nread_only: [NoSuchMailer]\n".write(toFile: path, atomically: true, encoding: .utf8)
        let store = PolicyStore(path: path)
        func drag(into app: String?, action: String = "drag") -> RPCRequest {
            var params: [String: JSONValue] = ["target": .object(["app": .string("NoSuchEditor")]), "action": .string(action)]
            if let app { params["toTarget"] = .object(["app": .string(app)]) }
            return RPCRequest(id: 1, method: PointerMethod.name, params: .object(params))
        }
        #expect(await PolicyEnforcer.refusal(for: drag(into: nil), store: store) == nil)
        #expect(await PolicyEnforcer.refusal(for: drag(into: "NoSuchViewer"), store: store) == nil)
        #expect(await PolicyEnforcer.refusal(for: drag(into: "NoSuchVault"), store: store)?.message.contains("blocks agents from NoSuchVault") == true)
        #expect(await PolicyEnforcer.refusal(for: drag(into: "NoSuchMailer"), store: store)?.message.contains("NoSuchMailer is read-only") == true)
        #expect(PolicyEnforcer.dropApp(of: drag(into: "NoSuchVault", action: "click")) == nil)
    }

    @Test func storeRereadsTheFileAndReportsErrors() throws {
        let path = NSTemporaryDirectory() + "policy-\(UUID().uuidString).yaml"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = PolicyStore(path: path)
        #expect(try store.current().get() == .empty)
        #expect(store.status.exists == false)

        try "read_only:\n  - Mail\n".write(toFile: path, atomically: true, encoding: .utf8)
        #expect(try store.current().get().readOnly == ["Mail"])

        try "readonly: [Mail]\n".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: path)
        #expect(store.status.error?.contains("readonly") == true)
    }
}
