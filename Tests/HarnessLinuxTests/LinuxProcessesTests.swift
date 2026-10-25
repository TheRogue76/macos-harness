import Foundation
import Glibc
import HarnessCore
import Testing
@testable import HarnessLinux

struct LinuxProcessesTests {
    private let processes = LinuxProcesses()

    @Test func knowsTheProcessAtTheOtherEndOfASocket() throws {
        var fds: [Int32] = [-1, -1]
        try #require(unsafe socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &fds) == 0)
        defer {
            close(fds[0])
            close(fds[1])
        }
        #expect(processes.peerPID(ofSocket: fds[0]) == getpid())
        #expect(processes.peerPID(ofSocket: -1) == nil)
    }

    @Test func describesARunningProcess() throws {
        let me = try #require(processes.snapshot(of: getpid()))
        #expect(me.parentPID == getppid())
        #expect(me.path == (try FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe")))
        #expect(me.arguments == CommandLine.arguments)
        #expect(processes.workingDirectory(of: getpid()) == FileManager.default.currentDirectoryPath)
    }

    @Test func walksAncestorsUpToInit() {
        let chain = processes.chain(from: getpid())
        #expect(chain.first?.pid == getpid())
        #expect(chain.count >= 2)
        #expect(chain.allSatisfy { $0.pid > 1 })
        for (child, parent) in zip(chain, chain.dropFirst()) {
            #expect(child.parentPID == parent.pid)
        }
    }

    @Test func identifiesTheCallerOfASocket() throws {
        var fds: [Int32] = [-1, -1]
        try #require(unsafe socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &fds) == 0)
        defer {
            close(fds[0])
            close(fds[1])
        }
        let identity = processes.identifyPeer(fds[0])
        #expect(identity.chain.first?.pid == getpid())
    }

    @Test func readsStatLinesWhoseCommandHasSpacesAndParentheses() {
        #expect(LinuxProcesses.parentPID(fromStat: "4242 (my (odd) app) S 17 4242 4242 0 -1 4194560\n") == 17)
        #expect(LinuxProcesses.parentPID(fromStat: "garbage") == nil)
    }

    @Test func splitsCommandLines() {
        #expect(LinuxProcesses.arguments(fromCommandLine: Data("node\0/opt/pi\0--print\0".utf8)) == ["node", "/opt/pi", "--print"])
        #expect(LinuxProcesses.arguments(fromCommandLine: Data("bash\0\0x\0".utf8)) == ["bash", "", "x"])
        #expect(LinuxProcesses.arguments(fromCommandLine: Data()) == [])
    }

    @Test func goneProcessesHaveNoSnapshot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("77"), withIntermediateDirectories: true)
        try "77 (fake) S 1 77 77 0 -1 0\n".write(to: root.appendingPathComponent("77/stat"), atomically: true, encoding: .utf8)
        let fake = LinuxProcesses(procRoot: root.path)
        #expect(fake.snapshot(of: 77)?.parentPID == 1)
        #expect(fake.snapshot(of: 78) == nil)
        #expect(fake.chain(from: 77).map(\.pid) == [77])
    }
}
