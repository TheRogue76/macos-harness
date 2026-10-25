import Foundation
import HarnessProtocol
import Testing
@testable import HarnessCore

struct InputLeaseTests {
    @Test func oneAgentAtATime() async throws {
        let lease = InputLease()
        let first = try await lease.acquire(owner: "a", name: "Codex")
        await #expect(throws: RPCError.self) {
            _ = try await lease.acquire(owner: "b", name: "pi", timeout: 0.2)
        }
        await #expect(throws: RPCError.self) {
            _ = try await lease.acquire(owner: "a", name: "Codex", timeout: 0.2)
        }
        await lease.release(first.token)
        let second = try await lease.acquire(owner: "b", name: "pi", timeout: 0.2)
        await lease.release(second.token)
    }

    @Test func waitersGetTheLeaseWhenItFrees() async throws {
        let lease = InputLease()
        let first = try await lease.acquire(owner: "a", name: "Codex")
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            await lease.release(first.token)
        }
        let second = try await lease.acquire(owner: "b", name: "pi", timeout: 2)
        await lease.release(second.token)
    }
}
