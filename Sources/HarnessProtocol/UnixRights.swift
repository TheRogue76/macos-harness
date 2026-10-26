#if os(Linux)
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Sending and receiving file descriptors over a Unix socket, as SCM_RIGHTS control messages,
/// for the Wayland and D-Bus clients.
package enum UnixRights {
    /// Sends all of `bytes`, with the descriptors attached to the first part; false when the
    /// socket has closed.
    package static func send(_ fd: Int32, _ bytes: [UInt8], fds: [Int32]) -> Bool {
        var offset = 0
        var pending = fds
        while offset < bytes.count {
            guard let sent = sendChunk(fd, Array(bytes[offset...]), fds: pending) else { return false }
            pending = []
            offset += sent
        }
        return true
    }

    /// Sends bytes with descriptors attached, returning how many bytes went.
    static func sendChunk(_ fd: Int32, _ bytes: [UInt8], fds: [Int32]) -> Int? {
        let control = rightsMessage(fds)
        let body = UnsafeMutableRawPointer.allocate(byteCount: max(bytes.count, 1), alignment: 8)
        let controlBuffer = UnsafeMutableRawPointer.allocate(byteCount: max(control.count, 1), alignment: 8)
        let vector = UnsafeMutablePointer<iovec>.allocate(capacity: 1)
        let message = UnsafeMutablePointer<msghdr>.allocate(capacity: 1)
        defer {
            unsafe body.deallocate()
            unsafe controlBuffer.deallocate()
            unsafe vector.deallocate()
            unsafe message.deallocate()
        }
        unsafe body.copyMemory(from: bytes, byteCount: bytes.count)
        unsafe controlBuffer.copyMemory(from: control, byteCount: control.count)
        unsafe vector.initialize(to: iovec(iov_base: body, iov_len: bytes.count))
        unsafe message.initialize(to: msghdr())
        unsafe message.pointee.msg_iov = vector
        unsafe message.pointee.msg_iovlen = 1
        if !control.isEmpty {
            unsafe message.pointee.msg_control = controlBuffer
            unsafe message.pointee.msg_controllen = control.count
        }
        while true {
            let sent = unsafe sendmsg(fd, message, Int32(MSG_NOSIGNAL))
            if sent < 0, errno == EINTR { continue }
            return sent >= 0 ? sent : nil
        }
    }

    /// Reads what's waiting, with any descriptors attached; nil once the socket has closed.
    package static func receive(_ fd: Int32, capacity: Int = 65_536) -> (bytes: [UInt8], fds: [Int32])? {
        let controlCapacity = 1024
        let body = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 8)
        let controlBuffer = UnsafeMutableRawPointer.allocate(byteCount: controlCapacity, alignment: 8)
        let vector = UnsafeMutablePointer<iovec>.allocate(capacity: 1)
        let message = UnsafeMutablePointer<msghdr>.allocate(capacity: 1)
        defer {
            unsafe body.deallocate()
            unsafe controlBuffer.deallocate()
            unsafe vector.deallocate()
            unsafe message.deallocate()
        }
        while true {
            unsafe vector.initialize(to: iovec(iov_base: body, iov_len: capacity))
            unsafe message.initialize(to: msghdr())
            unsafe message.pointee.msg_iov = vector
            unsafe message.pointee.msg_iovlen = 1
            unsafe message.pointee.msg_control = controlBuffer
            unsafe message.pointee.msg_controllen = controlCapacity
            let count = unsafe recvmsg(fd, message, Int32(MSG_CMSG_CLOEXEC))
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return nil }
            let bytes = unsafe [UInt8](UnsafeRawBufferPointer(start: body, count: count))
            let controlLength = Int(unsafe message.pointee.msg_controllen)
            let control = unsafe [UInt8](UnsafeRawBufferPointer(start: controlBuffer, count: controlLength))
            return (bytes, descriptors(inControl: control))
        }
    }

    /// A control message carrying descriptors: a `cmsghdr` (its length as a `size_t`, then the
    /// level and type) followed by the descriptors, padded to a `size_t`. Empty for none.
    package static func rightsMessage(_ fds: [Int32]) -> [UInt8] {
        guard !fds.isEmpty else { return [] }
        let word = MemoryLayout<Int>.size
        let header = word + 8
        let length = header + fds.count * 4
        var bytes: [UInt8] = []
        for shift in stride(from: 0, to: word * 8, by: 8) { bytes.append(UInt8(truncatingIfNeeded: length >> shift)) }
        append(UInt32(bitPattern: SOL_SOCKET), to: &bytes)
        append(UInt32(bitPattern: Int32(SCM_RIGHTS)), to: &bytes)
        for descriptor in fds { append(UInt32(bitPattern: descriptor), to: &bytes) }
        while bytes.count % word != 0 { bytes.append(0) }
        return bytes
    }

    /// The descriptors in SCM_RIGHTS control messages.
    package static func descriptors(inControl control: [UInt8]) -> [Int32] {
        let word = MemoryLayout<Int>.size
        let header = word + 8
        var found: [Int32] = []
        var start = 0
        while start + header <= control.count {
            var length = 0
            for index in 0..<word { length |= Int(control[start + index]) << (index * 8) }
            guard length >= header, start + length <= control.count else { break }
            let level = Int32(bitPattern: word32(control, at: start + word))
            let type = Int32(bitPattern: word32(control, at: start + word + 4))
            if level == SOL_SOCKET, type == Int32(SCM_RIGHTS) {
                var offset = start + header
                while offset + 4 <= start + length {
                    found.append(Int32(bitPattern: word32(control, at: offset)))
                    offset += 4
                }
            }
            start += (length + word - 1) / word * word
        }
        return found
    }

    static func append(_ value: UInt32, to bytes: inout [UInt8]) {
        for shift in stride(from: 0, to: 32, by: 8) { bytes.append(UInt8(truncatingIfNeeded: value >> shift)) }
    }

    static func word32(_ bytes: [UInt8], at index: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[index + $1]) << ($1 * 8) }
    }
}
/// Pipes for handing data across to another process, as clipboards do.
package enum UnixPipe {
    package static func make() throws -> (read: Int32, write: Int32) {
        var ends: [Int32] = [0, 0]
        guard unsafe pipe(&ends) == 0 else { throw SocketError.system("pipe", errno) }
        for end in ends { _ = fcntl(end, F_SETFD, FD_CLOEXEC) }
        return (ends[0], ends[1])
    }

    package static func close(_ fd: Int32) {
        #if canImport(Glibc)
        _ = Glibc.close(fd)
        #else
        _ = Musl.close(fd)
        #endif
    }

    /// Makes a descriptor block, as pipes other processes hand over may not.
    static func block(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0, flags & O_NONBLOCK != 0 { _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) }
    }

    /// Reads to the end on another thread, closing the descriptor; gives up after `timeout`.
    package static func readAll(_ fd: Int32, timeout: Duration) async throws -> Data {
        block(fd)
        return try await withThrowingTaskGroup(of: Data?.self) { group in
            group.addTask {
                await withCheckedContinuation { continuation in
                    Thread.detachNewThread {
                        var data = Data()
                        var chunk = [UInt8](repeating: 0, count: 65_536)
                        while true {
                            let count = unsafe read(fd, &chunk, chunk.count)
                            if count < 0, errno == EINTR { continue }
                            guard count > 0 else { break }
                            data.append(contentsOf: chunk[0..<count])
                        }
                        close(fd)
                        continuation.resume(returning: data)
                    }
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                return nil
            }
            guard let first = try await group.next(), let data = first else {
                throw SocketError.timedOut
            }
            group.cancelAll()
            return data
        }
    }

    /// Writes everything on another thread, then closes the descriptor.
    package static func writeAll(_ data: Data, to fd: Int32) {
        block(fd)
        Thread.detachNewThread {
            let bytes = [UInt8](data)
            var offset = 0
            while offset < bytes.count {
                let written = bytes.withUnsafeBufferPointer { buffer in
                    unsafe write(fd, buffer.baseAddress! + offset, bytes.count - offset)
                }
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { break }
                offset += written
            }
            close(fd)
        }
    }
}
#endif
