import Foundation
import HarnessProtocol
import Testing
@testable import HarnessCore
@testable import HarnessMac

private actor Order {
    private(set) var names: [String] = []
    func add(_ name: String) { names.append(name) }
}

@Suite struct ForegroundQueueTests {
    @Test func sessionsGetTheMouseAndKeyboardInTheOrderTheyAsked() async throws {
        let lease = RealInput.Lease()
        let order = Order()
        let first = try await lease.acquire(owner: "a", name: "Claude Code · one")
        #expect(first.wait == nil)
        let second = Task {
            let grant = try await lease.acquire(owner: "b", name: "Claude Code · two")
            await order.add("b")
            return grant
        }
        try await Task.sleep(for: .milliseconds(100))
        let third = Task {
            let grant = try await lease.acquire(owner: "c", name: "Codex")
            await order.add("c")
            return grant
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await lease.status().holder == "Claude Code · one")
        #expect(await lease.status().waiting == ["Claude Code · two", "Codex"])

        await lease.release(first.token)
        let grant = try await second.value
        #expect(grant.wait?.behind == "Claude Code · one")
        #expect((grant.wait?.seconds ?? 0) >= 0.1)
        await lease.release(grant.token)
        _ = try await third.value
        #expect(await order.names == ["b", "c"])
        #expect(await lease.status().holder == "Codex")
    }

    @Test func onlyTheCurrentTurnEnds() async throws {
        let lease = RealInput.Lease()
        let first = try await lease.acquire(owner: "a", name: "Claude Code")
        await lease.release(UUID())
        #expect(await lease.status().holder == "Claude Code")
        await lease.release(first.token)
        await lease.release(first.token)
        #expect(await lease.status().holder == nil)
    }

    @Test func anOpenMenuKeepsTheTurnForTheSessionThatOpenedIt() async throws {
        let lease = RealInput.Lease()
        let opened = try await lease.acquire(owner: "a", name: "Claude Code · one")
        let menu = try #require(await lease.holdForMenu(opened.token))
        let other = Task { try await lease.acquire(owner: "b", name: "Codex", timeout: 5) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await lease.status().waiting == ["Codex"])

        let again = try await lease.acquire(owner: "a", name: "Claude Code · one")
        #expect(again.wait == nil)
        await lease.release(menu)
        #expect(await lease.status().holder == "Claude Code · one")
        await lease.release(again.token)
        let grant = try await other.value
        #expect(grant.wait?.behind == "Claude Code · one")
    }

    @Test func aSessionThatWaitsTooLongIsToldWhoHasIt() async throws {
        let lease = RealInput.Lease()
        let first = try await lease.acquire(owner: "a", name: "Claude Code · one")
        let patient = Task { try await lease.acquire(owner: "b", name: "Claude Code · two", timeout: 5) }
        try await Task.sleep(for: .milliseconds(50))
        do {
            _ = try await lease.acquire(owner: "c", name: "Codex", timeout: 0.2)
            Issue.record("expected the wait to give up")
        } catch let error as RPCError {
            #expect(error.code == RPCErrorCode.inputBusy)
            #expect(error.message.contains("Claude Code · one is using the mouse and keyboard (with 1 more session ahead of you)"))
        }
        #expect(await lease.status().waiting == ["Claude Code · two"])
        await lease.release(first.token)
        _ = try await patient.value
    }

    @Test func theFrontGoesBackOnlyWhenNothingElseWantsIt() {
        #expect(RealInputSession.shouldGiveBackFront(previous: 10, frontmost: 20, target: 20, menuOpen: false, keepFront: false))
        #expect(!RealInputSession.shouldGiveBackFront(previous: nil, frontmost: 20, target: 20, menuOpen: false, keepFront: false))
        #expect(!RealInputSession.shouldGiveBackFront(previous: 20, frontmost: 20, target: 20, menuOpen: false, keepFront: false))
        #expect(!RealInputSession.shouldGiveBackFront(previous: 10, frontmost: 30, target: 20, menuOpen: false, keepFront: false))
        #expect(!RealInputSession.shouldGiveBackFront(previous: 10, frontmost: 20, target: 20, menuOpen: true, keepFront: false))
        #expect(!RealInputSession.shouldGiveBackFront(previous: 10, frontmost: 20, target: 20, menuOpen: false, keepFront: true))
    }
}
