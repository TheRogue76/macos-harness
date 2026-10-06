import Foundation

public enum SocketError: Error, CustomStringConvertible {
    case system(String, Int32)
    case pathTooLong(String)
    case closed
    case timedOut

    public var description: String {
        switch self {
        case .system(let call, let code): "\(call) failed: \(String(cString: strerror(code)))"
        case .pathTooLong(let path): "socket path is too long: \(path)"
        case .closed: "connection closed"
        case .timedOut: "timed out waiting for the helper"
        }
    }

    public var errnoCode: Int32? {
        if case .system(_, let code) = self { return code }
        return nil
    }
}

/// A connected Unix stream socket that sends and receives newline-delimited JSON.
/// Reads are blocking; use one reader per thread.
public final class LineSocket: @unchecked Sendable {
    public let fd: Int32
    private var buffer = Data()
    private let writeLock = NSLock()

    public init(fd: Int32) {
        self.fd = fd
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    deinit {
        close(fd)
    }

    /// Connects to a listening socket at `path`.
    public static func connect(path: String) throws -> LineSocket {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.system("socket", errno) }
        do {
            var address = try makeAddress(path)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0 else { throw SocketError.system("connect", errno) }
        } catch {
            close(fd)
            throw error
        }
        return LineSocket(fd: fd)
    }

    public static func makeAddress(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { throw SocketError.pathTooLong(path) }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return address
    }

    /// Sets how long `readLine` waits before throwing `timedOut`. nil waits forever.
    public func setReadTimeout(_ seconds: TimeInterval?) {
        var value = timeval()
        if let seconds {
            value.tv_sec = Int(seconds)
            value.tv_usec = Int32((seconds - Double(Int(seconds))) * 1_000_000)
        }
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
    }

    public func writeLine(_ data: Data) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        var payload = data
        payload.append(0x0A)
        try payload.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw SocketError.system("write", errno)
                }
                offset += written
            }
        }
    }

    /// Returns the next line without its newline, or nil at end of stream.
    public func readLine() throws -> Data? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                return Data(line)
            }
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { throw SocketError.timedOut }
                throw SocketError.system("read", errno)
            }
            if count == 0 {
                // End of stream: hand back an unterminated last line, if any.
                guard !buffer.isEmpty else { return nil }
                let rest = buffer
                buffer = Data()
                return rest
            }
            buffer.append(contentsOf: chunk[0..<count])
        }
    }
}
