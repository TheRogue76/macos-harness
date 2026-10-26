/// Why a D-Bus exchange failed.
public enum DBusError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The peer answered with an error.
    case failed(name: String, message: String)
    case timedOut
    case closed
    case badAddress(String)
    case authenticationFailed(String)
    case protocolViolation(String)

    public var description: String {
        switch self {
        case .failed(let name, let message): message.isEmpty ? name : "\(name): \(message)"
        case .timedOut: "the D-Bus peer didn't answer in time"
        case .closed: "the D-Bus connection closed"
        case .badAddress(let address): "can't connect to the D-Bus address \(address)"
        case .authenticationFailed(let reason): "the D-Bus bus refused authentication: \(reason)"
        case .protocolViolation(let reason): "malformed D-Bus message: \(reason)"
        }
    }
}

/// A D-Bus message: a method call, a reply, an error or a signal.
public struct DBusMessage: Sendable, Equatable {
    public enum Kind: UInt8, Sendable {
        case methodCall = 1
        case methodReturn = 2
        case error = 3
        case signal = 4
    }

    /// The flag asking the peer not to reply.
    public static let noReplyExpected: UInt8 = 0x1

    public var kind: Kind
    public var flags: UInt8 = 0
    public var serial: UInt32 = 0
    public var path: String?
    public var interface: String?
    public var member: String?
    public var errorName: String?
    public var replySerial: UInt32?
    public var destination: String?
    public var sender: String?
    public var body: [DBusValue] = []
    /// The descriptors the message carries; a `unixFD` value in the body is an index into these.
    public var fds: [Int32] = []
    /// How many descriptors the header says came with the message.
    var unixFDCount = 0

    public init(
        kind: Kind, path: String? = nil, interface: String? = nil, member: String? = nil,
        destination: String? = nil, body: [DBusValue] = []
    ) {
        self.kind = kind
        self.path = path
        self.interface = interface
        self.member = member
        self.destination = destination
        self.body = body
    }

    /// The signature of the body.
    public var signature: String { body.map(\.signature).joined() }

    /// The message in wire format.
    public func encoded() throws -> [UInt8] {
        var bodyWriter = DBusWriter()
        for value in body { try bodyWriter.write(value) }
        var fields: [DBusValue] = []
        func field(_ code: UInt8, _ value: DBusValue?) {
            if let value { fields.append(.structure([.byte(code), .variant(value)])) }
        }
        field(1, path.map(DBusValue.objectPath))
        field(2, interface.map(DBusValue.string))
        field(3, member.map(DBusValue.string))
        field(4, errorName.map(DBusValue.string))
        field(5, replySerial.map(DBusValue.uint32))
        field(6, destination.map(DBusValue.string))
        field(7, sender.map(DBusValue.string))
        field(8, body.isEmpty ? nil : .signature(signature))
        field(9, fds.isEmpty ? nil : .uint32(UInt32(fds.count)))
        var writer = DBusWriter()
        writer.bytes = [UInt8(ascii: "l"), kind.rawValue, flags, 1]
        writer.integer(UInt32(bodyWriter.bytes.count))
        writer.integer(serial)
        try writer.write(.array(element: "(yv)", fields))
        writer.pad(to: 8)
        return writer.bytes + bodyWriter.bytes
    }

    /// The length of the message at the start of `bytes`, or nil until its fixed header has arrived.
    static func length(of bytes: ArraySlice<UInt8>) throws -> Int? {
        guard bytes.count >= 16 else { return nil }
        var reader = DBusReader(Array(bytes.prefix(16)), bigEndian: try bigEndian(bytes.first))
        reader.offset = 4
        let bodyLength = Int(try reader.integer(UInt32.self))
        reader.offset = 12
        let fieldsLength = Int(try reader.integer(UInt32.self))
        let header = (16 + fieldsLength + 7) / 8 * 8
        let total = header + bodyLength
        guard total <= 128 * 1024 * 1024 else { throw DBusError.protocolViolation("message of \(total) bytes is too long") }
        return total
    }

    /// Reads a whole message.
    static func decode(_ bytes: [UInt8]) throws -> DBusMessage {
        guard bytes.count >= 16 else { throw DBusError.protocolViolation("message ends early") }
        var reader = DBusReader(bytes, bigEndian: try bigEndian(bytes.first))
        guard let kind = Kind(rawValue: bytes[1]) else { throw DBusError.protocolViolation("unknown message type \(bytes[1])") }
        var message = DBusMessage(kind: kind)
        message.flags = bytes[2]
        reader.offset = 4
        let bodyLength = Int(try reader.integer(UInt32.self))
        message.serial = try reader.integer(UInt32.self)
        var signature = ""
        for field in try reader.read("a(yv)").elements ?? [] {
            guard let parts = field.fields, parts.count == 2, case .byte(let code) = parts[0] else { continue }
            let value = parts[1].unwrapped
            switch code {
            case 1: message.path = value.string
            case 2: message.interface = value.string
            case 3: message.member = value.string
            case 4: message.errorName = value.string
            case 5: message.replySerial = value.int.map(UInt32.init)
            case 6: message.destination = value.string
            case 7: message.sender = value.string
            case 8: signature = value.string ?? ""
            case 9: message.unixFDCount = value.int ?? 0
            default: break
            }
        }
        try reader.align(to: 8)
        guard reader.offset + bodyLength == bytes.count else { throw DBusError.protocolViolation("body length doesn't match") }
        message.body = try DBusSignature.split(signature).map { try reader.read($0) }
        guard reader.offset == bytes.count else { throw DBusError.protocolViolation("body is longer than its signature") }
        return message
    }

    private static func bigEndian(_ marker: UInt8?) throws -> Bool {
        switch marker {
        case UInt8(ascii: "l"): false
        case UInt8(ascii: "B"): true
        default: throw DBusError.protocolViolation("unknown byte order")
        }
    }
}
