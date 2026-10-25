import Foundation
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
