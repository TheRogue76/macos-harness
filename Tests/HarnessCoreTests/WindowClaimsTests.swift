import Foundation
import HarnessProtocol
import Testing
@testable import HarnessCore

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_000)
    private var ended: Set<String> = []

    func now() -> Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
    func end(_ owner: String) { _ = lock.withLock { ended.insert(owner) } }
    func isRunning(_ owner: String) -> Bool { lock.withLock { !ended.contains(owner) } }
}

@Suite struct WindowClaimsTests {
    let first = "Claude Code|T|id#10"
    let second = "Claude Code|T|id#11"
    let place = "TextEdit window 455 “Untitled”"

    private func claims(_ clock: TestClock, patience: TimeInterval = 0) -> WindowClaims {
        WindowClaims(patience: patience, now: { clock.now() }, isRunning: { clock.isRunning($0) })
    }

    private func refusal(_ claims: WindowClaims, owner: String) async -> RPCError? {
        do {
            try await claims.claim(455, place: place, owner: owner, ownerName: "Claude Code · scrubs")
            return nil
        } catch let error as RPCError {
            return error
        } catch {
            return nil
        }
    }

    @Test func aSessionKeepsTheWindowItActsIn() async throws {
        let clock = TestClock()
        let claims = claims(clock)
        try await claims.claim(455, place: place, owner: first, ownerName: "Claude Code · macos-harness")
        clock.advance(20)
        try await claims.claim(455, place: place, owner: first, ownerName: "Claude Code · macos-harness")
        clock.advance(20)
        let error = await refusal(claims, owner: second)
        #expect(error?.code == RPCErrorCode.windowClaimed)
        #expect(error?.message.contains("Claude Code · macos-harness is working in TextEdit window 455 “Untitled”") == true)
        #expect(error?.message.contains("20 s ago") == true)
    }

    @Test func aClaimLapsesWhenTheSessionGoesQuiet() async throws {
        let clock = TestClock()
        let claims = claims(clock)
        try await claims.claim(455, place: place, owner: first, ownerName: "Claude Code · macos-harness")
        clock.advance(WindowClaims.lifetime + 1)
        #expect(await refusal(claims, owner: second) == nil)
        #expect(await claims.holder(of: 455, besides: first)?.owner == second)
    }

    @Test func readsByTheHolderRenewItAndOthersDont() async throws {
        let clock = TestClock()
        let claims = claims(clock)
        try await claims.claim(455, place: place, owner: first, ownerName: "Claude Code · macos-harness")
        clock.advance(25)
        await claims.renew(455, owner: first)
        await claims.renew(455, owner: second)
        clock.advance(25)
        #expect(await refusal(claims, owner: second) != nil)
        await claims.renew(456, owner: second)
        #expect(await claims.holder(of: 456, besides: first) == nil)
    }

    @Test func aClaimEndsWithItsSession() async throws {
        let clock = TestClock()
        let claims = claims(clock)
        try await claims.claim(455, place: place, owner: first, ownerName: "Claude Code · macos-harness")
        clock.end(first)
        #expect(await refusal(claims, owner: second) == nil)
    }

    @Test func releasingAnOwnerFreesItsWindows() async throws {
        let clock = TestClock()
        let claims = claims(clock)
        try await claims.claim(455, place: place, owner: first, ownerName: "Claude Code · macos-harness")
        try await claims.claim(456, place: place, owner: first, ownerName: "Claude Code · macos-harness")
        await claims.release(owner: first)
        #expect(await claims.holder(of: 455, besides: second) == nil)
        #expect(await claims.holder(of: 456, besides: second) == nil)
    }

    @Test func anActionWaitsForAClaimThatEndsSoon() async throws {
        let clock = TestClock()
        let claims = claims(clock, patience: 3)
        try await claims.claim(455, place: place, owner: first, ownerName: "Claude Code · macos-harness")
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            clock.end(first)
        }
        let started = Date()
        try await claims.claim(455, place: place, owner: second, ownerName: "Claude Code · scrubs")
        #expect(Date().timeIntervalSince(started) < 2)
        #expect(await claims.holder(of: 455, besides: first)?.owner == second)
    }
}
