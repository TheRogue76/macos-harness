import Synchronization

/// An argument of a Wayland request, in the protocol's types.
public enum WaylandArgument: Sendable, Equatable {
    case int(Int32)
    case uint(UInt32)
    /// A 24.8 fixed-point number.
    case fixed(Double)
    /// A string, or a null one.
    case string(String?)
    /// An object's ID, 0 for none.
    case object(UInt32)
    /// The ID the client chose for a new object.
    case newID(UInt32)
    case array([UInt8])
    /// A file descriptor, sent beside the message rather than in it.
    case fd(Int32)
}

/// Why a Wayland exchange failed.
public enum WaylandError: Error, Equatable, Sendable, CustomStringConvertible {
    case noDisplay
    case closed
    case timedOut
    case missingGlobal(String)
    /// The compositor reported an error on one of our objects and closed the connection.
    case protocolError(object: UInt32, code: UInt32, message: String)
    case malformed(String)

    public var description: String {
        switch self {
        case .noDisplay: "no Wayland display: WAYLAND_DISPLAY and XDG_RUNTIME_DIR don't name a compositor's socket"
        case .closed: "the Wayland compositor closed the connection"
        case .timedOut: "the Wayland compositor didn't answer in time"
        case .missingGlobal(let name): "the compositor doesn't offer \(name)"
        case .protocolError(let object, let code, let message): "the compositor reported error \(code) on object \(object): \(message)"
        case .malformed(let reason): "malformed Wayland message: \(reason)"
        }
    }
}

/// The Wayland wire format: messages of 32-bit words in the host's byte order, which on the
/// platforms the harness supports (x86_64 and arm64) is little-endian.
enum WaylandWire {
    /// A request's bytes, and the descriptors that go beside them.
    static func encode(object: UInt32, opcode: UInt16, _ arguments: [WaylandArgument]) -> (bytes: [UInt8], fds: [Int32]) {
        var body: [UInt8] = []
        var fds: [Int32] = []
        for argument in arguments {
            switch argument {
            case .int(let value): append(UInt32(bitPattern: value), to: &body)
            case .uint(let value), .object(let value), .newID(let value): append(value, to: &body)
            case .fixed(let value): append(UInt32(bitPattern: Int32((value * 256).rounded())), to: &body)
            case .string(let text):
                guard let text else {
                    append(0, to: &body)
                    continue
                }
                let bytes = Array(text.utf8) + [0]
                append(UInt32(bytes.count), to: &body)
                body += bytes
                pad(&body)
            case .array(let bytes):
                append(UInt32(bytes.count), to: &body)
                body += bytes
                pad(&body)
            case .fd(let descriptor): fds.append(descriptor)
            }
        }
        var message: [UInt8] = []
        append(object, to: &message)
        append(UInt32(8 + body.count) << 16 | UInt32(opcode), to: &message)
        return (message + body, fds)
    }

    /// The size of the message at the start of `bytes`, or nil until its header has arrived.
    static func size(of bytes: ArraySlice<UInt8>) throws -> Int? {
        guard bytes.count >= 8 else { return nil }
        let size = Int(word(bytes, at: bytes.startIndex + 4) >> 16)
        guard size >= 8, size % 4 == 0 else { throw WaylandError.malformed("message size \(size)") }
        return size
    }

    static func append(_ value: UInt32, to bytes: inout [UInt8]) {
        for shift in stride(from: 0, to: 32, by: 8) { bytes.append(UInt8(truncatingIfNeeded: value >> shift)) }
    }

    static func pad(_ bytes: inout [UInt8]) {
        while bytes.count % 4 != 0 { bytes.append(0) }
    }

    static func word(_ bytes: ArraySlice<UInt8>, at index: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(bytes[index + $1]) << (8 * $1) }
    }
}

/// An event from the compositor, its arguments read in order.
public struct WaylandEvent: Sendable {
    public let object: UInt32
    public let opcode: UInt16
    let body: [UInt8]
    var offset = 0
    let descriptors: WaylandDescriptors?

    init(object: UInt32, opcode: UInt16, body: [UInt8], descriptors: WaylandDescriptors? = nil) {
        self.object = object
        self.opcode = opcode
        self.body = body
        self.descriptors = descriptors
    }

    /// The event at the start of a whole message, taking descriptors from `descriptors`.
    init(message: ArraySlice<UInt8>, descriptors: WaylandDescriptors? = nil) {
        let start = message.startIndex
        object = WaylandWire.word(message, at: start)
        opcode = UInt16(WaylandWire.word(message, at: start + 4) & 0xFFFF)
        body = Array(message.dropFirst(8))
        self.descriptors = descriptors
    }

    /// The next descriptor the event carries, which the caller then owns and closes.
    public mutating func fd() throws -> Int32 {
        guard let descriptor = descriptors?.take() else { throw WaylandError.malformed("event \(opcode) on \(object) came without its descriptor") }
        return descriptor
    }

    public mutating func uint() throws -> UInt32 {
        guard offset + 4 <= body.count else { throw WaylandError.malformed("event \(opcode) on \(object) ends early") }
        defer { offset += 4 }
        return WaylandWire.word(body[...], at: offset)
    }

    public mutating func int() throws -> Int32 {
        Int32(bitPattern: try uint())
    }

    public mutating func fixed() throws -> Double {
        Double(try int()) / 256
    }

    public mutating func string() throws -> String? {
        let length = Int(try uint())
        guard length > 0 else { return nil }
        guard offset + length <= body.count else { throw WaylandError.malformed("string runs past event \(opcode)'s end") }
        let text = String(decoding: body[offset..<(offset + length - 1)], as: UTF8.self)
        offset += (length + 3) / 4 * 4
        return text
    }

    public mutating func array() throws -> [UInt8] {
        let length = Int(try uint())
        guard offset + length <= body.count else { throw WaylandError.malformed("array runs past event \(opcode)'s end") }
        let bytes = Array(body[offset..<(offset + length)])
        offset += (length + 3) / 4 * 4
        return bytes
    }
}

/// Descriptors received with events, in the order they arrived, for events to take in turn.
final class WaylandDescriptors: Sendable {
    private let queue = Mutex<[Int32]>([])

    func add(_ descriptors: [Int32]) {
        queue.withLock { $0 += descriptors }
    }

    func take() -> Int32? {
        queue.withLock { $0.isEmpty ? nil : $0.removeFirst() }
    }
}
