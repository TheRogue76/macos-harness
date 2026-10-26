import Foundation
import Synchronization
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// An image read from the compositor, as RGBA bytes.
public struct WaylandImage: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var rgba: [UInt8]
}

/// A screen the compositor shows, as `wl_output` describes it.
public struct WaylandOutput: Sendable, Equatable {
    public var object: UInt32
    public var name: String?
    public var width = 0
    public var height = 0
    public var scale = 1
}

/// Reading the screen through wlr-screencopy into shared memory.
public final class WaylandCapture: Sendable {
    let connection: WaylandConnection
    let manager: UInt32
    let shm: UInt32
    public let outputs: [WaylandOutput]

    private init(connection: WaylandConnection, manager: UInt32, shm: UInt32, outputs: [WaylandOutput]) {
        self.connection = connection
        self.manager = manager
        self.shm = shm
        self.outputs = outputs
    }

    /// Binds what capture needs, failing when the compositor doesn't offer wlr-screencopy.
    public static func make(on connection: WaylandConnection) async throws -> WaylandCapture {
        let (registry, globals) = try await connection.globals()
        guard let screencopy = globals.first(where: { $0.interface == "zwlr_screencopy_manager_v1" }) else {
            throw WaylandError.missingGlobal("zwlr_screencopy_manager_v1")
        }
        guard let shmGlobal = globals.first(where: { $0.interface == "wl_shm" }) else { throw WaylandError.missingGlobal("wl_shm") }
        let manager = try connection.bind(screencopy, registry: registry, version: 3)
        let shm = try connection.bind(shmGlobal, registry: registry, version: 1)
        let outputs = Mutex<[UInt32: WaylandOutput]>([:])
        for global in globals where global.interface == "wl_output" {
            let object = try connection.bind(global, registry: registry, version: 4)
            outputs.withLock { $0[object] = WaylandOutput(object: object) }
            connection.listen(object) { event in
                switch event.opcode {
                case 1:
                    let flags = try event.uint()
                    let width = Int(try event.int())
                    let height = Int(try event.int())
                    if flags & 1 != 0 {
                        outputs.withLock { $0[object]?.width = width; $0[object]?.height = height }
                    }
                case 3:
                    let scale = Int(try event.int())
                    outputs.withLock { $0[object]?.scale = scale }
                case 4:
                    let name = try event.string()
                    outputs.withLock { $0[object]?.name = name }
                default:
                    break
                }
            }
        }
        try await connection.roundtrip()
        let found = outputs.withLock { $0.values.sorted { $0.object < $1.object } }
        return WaylandCapture(connection: connection, manager: manager, shm: shm, outputs: found)
    }

    /// What a frame says about the buffer it wants, then whether the copy worked.
    private struct Frame {
        var format: UInt32?
        var width = 0
        var height = 0
        var stride = 0
        var flipped = false
        var described = false
        var finished: Bool?
    }

    /// The whole of an output, in its pixels.
    public func capture(_ output: WaylandOutput, timeout: Duration = .seconds(5)) async throws -> WaylandImage {
        let frame = connection.allocate()
        let state = Mutex(Frame())
        connection.listen(frame) { event in
            switch event.opcode {
            case 0:
                let format = try event.uint()
                let width = Int(try event.uint())
                let height = Int(try event.uint())
                let stride = Int(try event.uint())
                if PixelLayout(format: format) != nil {
                    state.withLock { $0.format = format; $0.width = width; $0.height = height; $0.stride = stride }
                }
            case 1:
                let flags = try event.uint()
                state.withLock { $0.flipped = flags & 1 != 0 }
            case 2: state.withLock { $0.finished = true }
            case 3: state.withLock { $0.finished = false }
            case 6: state.withLock { $0.described = true }
            default: break
            }
        }
        defer {
            connection.forget(frame)
            try? connection.send(frame, 1)
        }
        try connection.send(manager, 0, [.newID(frame), .int(0), .object(output.object)])
        try await connection.roundtrip(timeout: timeout)
        let described = state.withLock { $0 }
        guard let format = described.format, described.width > 0, described.height > 0 else {
            throw WaylandError.malformed("the compositor offered no shared-memory buffer format for capture")
        }
        let buffer = try SharedBuffer(size: described.stride * described.height)
        defer { buffer.release() }
        let pool = connection.allocate()
        let wlBuffer = connection.allocate()
        try connection.send(shm, 0, [.newID(pool), .fd(buffer.fd), .int(Int32(buffer.size))])
        try connection.send(pool, 0, [
            .newID(wlBuffer), .int(0), .int(Int32(described.width)), .int(Int32(described.height)), .int(Int32(described.stride)), .uint(format),
        ])
        defer {
            try? connection.send(wlBuffer, 0)
            try? connection.send(pool, 1)
        }
        try connection.send(frame, 0, [.object(wlBuffer)])
        let deadline = ContinuousClock.now + timeout
        while state.withLock({ $0.finished }) == nil {
            guard ContinuousClock.now < deadline, !connection.isClosed else { throw WaylandError.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard state.withLock({ $0.finished }) == true else { throw WaylandError.malformed("the compositor couldn't copy the screen") }
        let pixels = buffer.bytes()
        return Self.rgba(
            from: pixels, width: described.width, height: described.height, stride: described.stride,
            layout: PixelLayout(format: format) ?? PixelLayout(bytes: 4, red: 2, green: 1, blue: 0, alpha: nil), flipped: state.withLock { $0.flipped }
        )
    }

    /// Where a shared-memory format keeps each channel within a pixel's bytes.
    struct PixelLayout: Equatable {
        var bytes: Int
        var red: Int
        var green: Int
        var blue: Int
        var alpha: Int?

        /// The layout of a `wl_shm` format: 0 and 1 are ARGB8888 and XRGB8888; others are DRM
        /// fourcc codes, whose names list channels from the most significant byte of a
        /// little-endian word, so memory holds them in reverse.
        init?(format: UInt32) {
            switch format {
            case 0: self.init(bytes: 4, red: 2, green: 1, blue: 0, alpha: 3)
            case 1: self.init(bytes: 4, red: 2, green: 1, blue: 0, alpha: nil)
            case 0x3432_4241: self.init(bytes: 4, red: 0, green: 1, blue: 2, alpha: 3)
            case 0x3432_4258: self.init(bytes: 4, red: 0, green: 1, blue: 2, alpha: nil)
            case 0x3432_4742: self.init(bytes: 3, red: 0, green: 1, blue: 2, alpha: nil)
            case 0x3432_4752: self.init(bytes: 3, red: 2, green: 1, blue: 0, alpha: nil)
            default: return nil
            }
        }

        init(bytes: Int, red: Int, green: Int, blue: Int, alpha: Int?) {
            self.bytes = bytes
            self.red = red
            self.green = green
            self.blue = blue
            self.alpha = alpha
        }
    }

    /// RGBA bytes from a captured buffer's rows.
    static func rgba(from pixels: [UInt8], width: Int, height: Int, stride: Int, layout: PixelLayout, flipped: Bool) -> WaylandImage {
        var out = [UInt8](repeating: 255, count: width * height * 4)
        for row in 0..<height {
            let source = (flipped ? height - 1 - row : row) * stride
            for column in 0..<width {
                let from = source + column * layout.bytes
                let to = (row * width + column) * 4
                guard from + layout.bytes <= pixels.count else { continue }
                out[to] = pixels[from + layout.red]
                out[to + 1] = pixels[from + layout.green]
                out[to + 2] = pixels[from + layout.blue]
                if let alpha = layout.alpha { out[to + 3] = pixels[from + alpha] }
            }
        }
        return WaylandImage(width: width, height: height, rgba: out)
    }
}

/// Shared memory the compositor writes into: an unlinked POSIX shared-memory object, mapped.
@safe final class SharedBuffer: @unchecked Sendable {
    let fd: Int32
    let size: Int
    private let mapping: UnsafeMutableRawPointer

    var mappingPointer: UnsafeMutableRawPointer { unsafe mapping }

    init(size: Int) throws {
        let name = "/macos-harness-\(getpid())-\(UInt32.random(in: 0...UInt32.max))"
        let fd = unsafe shm_open(name, O_RDWR | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw WaylandError.malformed("can't create shared memory (errno \(errno))") }
        _ = unsafe shm_unlink(name)
        guard ftruncate(fd, off_t(size)) == 0, let mapped = unsafe mmap(nil, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0),
              unsafe mapped != MAP_FAILED else {
            _ = Glibc.close(fd)
            throw WaylandError.malformed("can't map shared memory (errno \(errno))")
        }
        self.fd = fd
        self.size = size
        unsafe mapping = mapped
    }

    /// A copy of the buffer's bytes.
    func bytes() -> [UInt8] {
        unsafe [UInt8](UnsafeRawBufferPointer(start: mapping, count: size))
    }

    func release() {
        _ = unsafe munmap(mapping, size)
        _ = Glibc.close(fd)
    }
}
