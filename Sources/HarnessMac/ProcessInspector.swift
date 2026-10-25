import Darwin
import Foundation
import HarnessProtocol
import Security
import HarnessCore

/// What macOS tells the helper about the processes behind a connection.
public struct MacProcesses: ProcessIntrospection {
    public init() {}

    public func peerPID(ofSocket fd: Int32) -> pid_t? { ProcessInspector.peerPID(ofSocket: fd) }
    public func chain(from pid: pid_t) -> [ProcessSnapshot] { ProcessInspector.chain(from: pid) }
    public func responsiblePID(of pid: pid_t) -> pid_t? { ProcessInspector.responsiblePID(of: pid) }
    public func workingDirectory(of pid: pid_t) -> String? { ProcessInspector.workingDirectory(of: pid) }
}

extension SocketServer {
    /// Recognizes the agent behind a connected socket from its macOS process ancestry.
    public static let identifyPeer: @Sendable (Int32) -> CallerIdentity = { MacProcesses().identifyPeer($0) }
}

public enum ProcessInspector {
    /// The pid at the other end of a connected Unix socket.
    public static func peerPID(ofSocket fd: Int32) -> pid_t? {
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0, pid > 0 else { return nil }
        return pid
    }

    /// The process macOS holds responsible for `pid`; for a command that detached from its parent,
    /// still its agent.
    public static func responsiblePID(of pid: pid_t) -> pid_t? {
        typealias Function = @convention(c) (pid_t) -> pid_t
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else {
            return nil
        }
        let responsible = unsafeBitCast(symbol, to: Function.self)(pid)
        return responsible > 0 ? responsible : nil
    }

    /// The process and its ancestors, nearest first, stopping before launchd.
    public static func chain(from pid: pid_t, limit: Int = 32) -> [ProcessSnapshot] {
        var result: [ProcessSnapshot] = []
        var current = pid
        var seen = Set<pid_t>()
        while current > 1, result.count < limit, seen.insert(current).inserted,
              let snapshot = snapshot(of: current) {
            result.append(snapshot)
            current = snapshot.parentPID
        }
        return result
    }

    public static func snapshot(of pid: pid_t) -> ProcessSnapshot? {
        guard let parent = parentPID(of: pid) else { return nil }
        let path = executablePath(of: pid) ?? ""
        let signing = signingInfo(of: pid)
        return ProcessSnapshot(
            pid: pid, parentPID: parent, path: path, arguments: arguments(of: pid) ?? [],
            signingIdentifier: signing.identifier, teamIdentifier: signing.team, signer: signing.signer
        )
    }

    static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    /// The IDs of running processes whose executable path ends with `suffix`.
    public static func pids(withExecutableEnding suffix: String) -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return [] }
        return pids.prefix(Int(filled)).filter { $0 > 0 && (executablePath(of: $0)?.hasSuffix(suffix) ?? false) }
    }

    static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(nulTerminated: buffer)
    }

    /// The process's current directory, when it can be read.
    public static func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(nulTerminated: Array($0.bindMemory(to: CChar.self))) }
        return path.isEmpty ? nil : path
    }

    static func arguments(of pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return parseProcArgs(Array(buffer[0..<size]))
    }

    /// The arguments in a KERN_PROCARGS2 buffer, or nil if it's malformed.
    public static func parseProcArgs(_ bytes: [UInt8]) -> [String]? {
        guard bytes.count >= 4 else { return nil }
        let argc = Int(bytes[0..<4].withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        let execPathEnd: Int = bytes[4...].firstIndex(of: 0) ?? bytes.count
        var index: Int = bytes[execPathEnd...].firstIndex(where: { $0 != 0 }) ?? bytes.count
        var arguments: [String] = []
        while arguments.count < argc, index < bytes.count {
            let start = index
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            arguments.append(String(decoding: bytes[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments
    }

    static func signingInfo(of pid: pid_t) -> (identifier: String?, team: String?, signer: String?) {
        var code: SecCode?
        let attributes = [kSecGuestAttributePid: pid] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else {
            return (nil, nil, nil)
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
            return (nil, nil, nil)
        }
        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &information) == errSecSuccess,
              let info = information as? [String: Any] else {
            return (nil, nil, nil)
        }
        let leaf = (info[kSecCodeInfoCertificates as String] as? [SecCertificate])?.first
        let summary = leaf.flatMap { SecCertificateCopySubjectSummary($0) as String? }
        return (
            info[kSecCodeInfoIdentifier as String] as? String,
            info[kSecCodeInfoTeamIdentifier as String] as? String,
            summary.map(signerName)
        )
    }

    /// "Developer ID Application: OpenAI, L.L.C. (2DC432GLL2)" → "OpenAI, L.L.C.";
    /// Apple's platform signatures ("Software Signing") → "Apple".
    public static func signerName(fromCertificateSummary summary: String) -> String {
        if summary == "Software Signing" || summary.hasPrefix("Apple ") && !summary.contains(":") {
            return "Apple"
        }
        var name = summary
        if let colon = name.range(of: ": ") { name = String(name[colon.upperBound...]) }
        if let paren = name.range(of: " (", options: .backwards) { name = String(name[..<paren.lowerBound]) }
        return name
    }
}
