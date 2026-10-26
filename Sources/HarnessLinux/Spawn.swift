#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import Synchronization
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Starting apps the way a desktop does: with no signals blocked or ignored, in their own process
/// group, with nothing open but `/dev/null` for their standard streams.
enum Spawn {
    /// Starts `executable` and returns its pid; a thread collects it when it exits.
    static func app(_ executable: String, arguments: [String], environment: [String: String]) throws -> pid_t {
        var attributes = posix_spawnattr_t()
        unsafe posix_spawnattr_init(&attributes)
        defer { unsafe posix_spawnattr_destroy(&attributes) }
        var none = sigset_t()
        unsafe sigemptyset(&none)
        unsafe posix_spawnattr_setsigmask(&attributes, &none)
        var all = sigset_t()
        unsafe sigfillset(&all)
        unsafe posix_spawnattr_setsigdefault(&attributes, &all)
        unsafe posix_spawnattr_setpgroup(&attributes, 0)
        unsafe posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETPGROUP))

        var actions = unsafe posix_spawn_file_actions_t()
        unsafe posix_spawn_file_actions_init(&actions)
        defer { unsafe posix_spawn_file_actions_destroy(&actions) }
        unsafe posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        unsafe posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        unsafe posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        unsafe posix_spawn_file_actions_addclosefrom_np(&actions, 3)

        let argv = unsafe cStrings([executable] + arguments)
        let envp = unsafe cStrings(environment.map { "\($0.key)=\($0.value)" })
        defer {
            unsafe free(argv)
            unsafe free(envp)
        }
        var pid: pid_t = 0
        let status = unsafe posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
        guard status == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: unsafe String(cString: strerror(status))])
        }
        let child = pid
        Thread.detachNewThread {
            var result: Int32 = 0
            while unsafe waitpid(child, &result, 0) < 0, errno == EINTR {}
        }
        return pid
    }

    /// Starts a tool with a clean signal mask, its standard input from `stdin` (or `/dev/null`),
    /// its output to `log` (or `/dev/null`), and `descriptors` handed on, by the number the
    /// child sees them as; returns the running process.
    static func process(
        _ executable: String, arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment,
        stdin: Int32? = nil, descriptors: [Int32: Int32] = [:], log: String? = nil
    ) throws -> SpawnedProcess {
        var attributes = posix_spawnattr_t()
        unsafe posix_spawnattr_init(&attributes)
        defer { unsafe posix_spawnattr_destroy(&attributes) }
        var none = sigset_t()
        unsafe sigemptyset(&none)
        unsafe posix_spawnattr_setsigmask(&attributes, &none)
        var all = sigset_t()
        unsafe sigfillset(&all)
        unsafe posix_spawnattr_setsigdefault(&attributes, &all)
        unsafe posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))

        var actions = unsafe posix_spawn_file_actions_t()
        unsafe posix_spawn_file_actions_init(&actions)
        defer { unsafe posix_spawn_file_actions_destroy(&actions) }
        if let stdin {
            unsafe posix_spawn_file_actions_adddup2(&actions, stdin, 0)
        } else {
            unsafe posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        }
        let output = log ?? "/dev/null"
        unsafe posix_spawn_file_actions_addopen(&actions, 1, output, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        unsafe posix_spawn_file_actions_adddup2(&actions, 1, 2)
        for (target, source) in descriptors.sorted(by: { $0.key < $1.key }) {
            unsafe posix_spawn_file_actions_adddup2(&actions, source, target)
        }
        unsafe posix_spawn_file_actions_addclosefrom_np(&actions, (descriptors.keys.max() ?? 2) + 1)

        let argv = unsafe cStrings([executable] + arguments)
        let envp = unsafe cStrings(environment.map { "\($0.key)=\($0.value)" })
        defer {
            unsafe free(argv)
            unsafe free(envp)
        }
        var pid: pid_t = 0
        let status = unsafe posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
        guard status == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: unsafe String(cString: strerror(status))])
        }
        return SpawnedProcess(pid: pid)
    }

    /// The full path of a tool on `PATH`, or nil.
    static func which(_ name: String, path: String? = ProcessInfo.processInfo.environment["PATH"]) -> String? {
        (path ?? "/usr/bin:/bin").split(separator: ":").map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// A NULL-terminated array of C strings in one malloc'd block, freed with a single `free`.
    private static func cStrings(_ strings: [String]) -> UnsafeMutablePointer<UnsafeMutablePointer<CChar>?> {
        let encoded = strings.map { Array($0.utf8CString) }
        let pointers = unsafe MemoryLayout<UnsafeMutablePointer<CChar>?>.stride * (encoded.count + 1)
        let total = pointers + encoded.reduce(0) { $0 + $1.count }
        let block = unsafe malloc(total)!
        let table = unsafe block.bindMemory(to: UnsafeMutablePointer<CChar>?.self, capacity: encoded.count + 1)
        var text = unsafe (block + pointers).bindMemory(to: CChar.self, capacity: total - pointers)
        for (index, string) in encoded.enumerated() {
            unsafe text.update(from: string, count: string.count)
            unsafe table[index] = text
            unsafe text += string.count
        }
        unsafe table[encoded.count] = nil
        return unsafe table
    }
}

/// A process `Spawn.process` started, collected by a thread when it exits.
final class SpawnedProcess: Sendable {
    let pid: pid_t
    private let exited = Mutex(false)

    init(pid: pid_t) {
        self.pid = pid
        Thread.detachNewThread { [self] in
            var result: Int32 = 0
            while unsafe waitpid(pid, &result, 0) < 0, errno == EINTR {}
            exited.withLock { $0 = true }
        }
    }

    var isRunning: Bool { exited.withLock { !$0 } }

    func signal(_ number: Int32) {
        if isRunning { kill(pid, number) }
    }

    /// Waits for the process to exit; false if it was still running after `timeout`.
    func wait(timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while isRunning, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return !isRunning
    }
}

/// Starting the harness's own tools, such as the Control Tower panel, detached from the helper.
public enum Tools {
    /// Starts `executable` with a clean signal mask and `environment` added to the helper's, and
    /// returns its pid.
    @discardableResult
    public static func launch(_ executable: String, arguments: [String] = [], environment: [String: String] = [:]) throws -> Int32 {
        let merged = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        return try Spawn.process(executable, arguments: arguments, environment: merged).pid
    }

    /// Puts the harness's own window (the panel) near a point, such as where its tray icon was
    /// clicked: waits for a window of `appIDPrefix` to be on screen (a compositor places a new
    /// window itself when it maps it, undoing an earlier move), then has the compositor move it,
    /// and again a moment later at its settled size. False when it couldn't.
    public static func place(appIDPrefix: String, near point: CGPoint, timeout: Duration = .seconds(3)) async -> Bool {
        guard let compositor = await Compositors.current() else { return false }
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let window = try? await compositor.windows().first(where: { ($0.appID ?? "").hasPrefix(appIDPrefix) }),
               window.frame.width > 0, window.frame.height > 0 {
                guard (try? await compositor.place(window, near: point)) != nil else { return false }
                try? await Task.sleep(for: .milliseconds(200))
                let settled = (try? await compositor.windows().first { $0.id == window.id }) ?? window
                return (try? await compositor.place(settled, near: point)) != nil
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }
}
