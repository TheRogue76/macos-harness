import Foundation
import HarnessProtocol
import Testing
@testable import HarnessCore

private actor Order {
    private(set) var names: [String] = []
    func add(_ name: String) { names.append(name) }
}

@Suite struct ForegroundQueueTests {
    @Test func sessionsGetTheMouseAndKeyboardInTheOrderTheyAsked() async throws {
        let lease = RealInput.Lease()
        let order = Order()
        #expect(try await lease.acquire(owner: "a", name: "Claude Code · one") == nil)
        let second = Task {
            let wait = try await lease.acquire(owner: "b", name: "Claude Code · two")
            await order.add("b")
            return wait
        }
        try await Task.sleep(for: .milliseconds(100))
        let third = Task {
            _ = try await lease.acquire(owner: "c", name: "Codex")
            await order.add("c")
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await lease.status().holder == "Claude Code · one")
        #expect(await lease.status().waiting == ["Claude Code · two", "Codex"])

        await lease.release(owner: "a")
        let wait = try await second.value
        #expect(wait?.behind == "Claude Code · one")
        #expect((wait?.seconds ?? 0) >= 0.1)
        await lease.release(owner: "b")
        try await third.value
        #expect(await order.names == ["b", "c"])
        #expect(await lease.status().holder == "Codex")
    }

    @Test func onlyTheHolderReleases() async throws {
        let lease = RealInput.Lease()
        _ = try await lease.acquire(owner: "a", name: "Claude Code")
        await lease.release(owner: "b")
        #expect(await lease.status().holder == "Claude Code")
    }

    @Test func aSessionThatWaitsTooLongIsToldWhoHasIt() async throws {
        let lease = RealInput.Lease()
        _ = try await lease.acquire(owner: "a", name: "Claude Code · one")
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
        await lease.release(owner: "a")
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
