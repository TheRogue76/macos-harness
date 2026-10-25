import Foundation
import Glibc
import HarnessCore
import HarnessProtocol

/// What Linux's socket credentials and `/proc` tell the helper about the processes behind a
/// connection.
public struct LinuxProcesses: ProcessIntrospection {
    let procRoot: String

    public init(procRoot: String = "/proc") {
        self.procRoot = procRoot
    }

    public func peerPID(ofSocket fd: Int32) -> pid_t? {
        var credentials: [Int32] = [0, 0, 0]
        var length = socklen_t(MemoryLayout<Int32>.size * credentials.count)
        guard unsafe getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &credentials, &length) == 0, credentials[0] > 0 else {
            return nil
        }
        return credentials[0]
    }

    /// The process and its ancestors, nearest first, stopping before init.
    public func chain(from pid: pid_t) -> [ProcessSnapshot] {
        var result: [ProcessSnapshot] = []
        var current = pid
        var seen = Set<pid_t>()
        while current > 1, result.count < 32, seen.insert(current).inserted, let snapshot = snapshot(of: current) {
            result.append(snapshot)
            current = snapshot.parentPID
        }
        return result
    }

    public func responsiblePID(of pid: pid_t) -> pid_t? {
        nil
    }

    public func workingDirectory(of pid: pid_t) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: "\(procRoot)/\(pid)/cwd")
    }

    /// The process's parent, executable and arguments, or nil when it's gone.
    public func snapshot(of pid: pid_t) -> ProcessSnapshot? {
        guard let parent = parentPID(of: pid) else { return nil }
        let path = (try? FileManager.default.destinationOfSymbolicLink(atPath: "\(procRoot)/\(pid)/exe")) ?? ""
        return ProcessSnapshot(pid: pid, parentPID: parent, path: path, arguments: arguments(of: pid))
    }

    func parentPID(of pid: pid_t) -> pid_t? {
        guard let stat = try? String(contentsOfFile: "\(procRoot)/\(pid)/stat", encoding: .utf8) else { return nil }
        return Self.parentPID(fromStat: stat)
    }

    func arguments(of pid: pid_t) -> [String] {
        guard let data = FileManager.default.contents(atPath: "\(procRoot)/\(pid)/cmdline") else { return [] }
        return Self.arguments(fromCommandLine: data)
    }

    /// The parent pid in a `/proc/<pid>/stat` line, whose second field (the command name, in
    /// parentheses) may itself contain spaces and parentheses.
    static func parentPID(fromStat stat: String) -> pid_t? {
        guard let commandEnd = stat.lastIndex(of: ")") else { return nil }
        let fields = stat[stat.index(after: commandEnd)...].split(whereSeparator: \.isWhitespace)
        guard fields.count > 1 else { return nil }
        return pid_t(fields[1])
    }

    /// The arguments in a `/proc/<pid>/cmdline` buffer: NUL-separated, with a trailing NUL.
    static func arguments(fromCommandLine data: Data) -> [String] {
        data.split(separator: 0, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
            .reversed().drop { $0.isEmpty }.reversed()
    }
}
