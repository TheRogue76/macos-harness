/// Writes values in the D-Bus wire format, little-endian, aligned from the start of the buffer.
struct DBusWriter {
    var bytes: [UInt8] = []

    mutating func pad(to alignment: Int) {
        while bytes.count % alignment != 0 { bytes.append(0) }
    }

    mutating func integer<T: FixedWidthInteger>(_ value: T) {
        pad(to: MemoryLayout<T>.size)
        for shift in stride(from: 0, to: T.bitWidth, by: 8) {
            bytes.append(UInt8(truncatingIfNeeded: value >> shift))
        }
    }

    mutating func text(_ value: String) {
        let utf8 = Array(value.utf8)
        integer(UInt32(utf8.count))
        bytes += utf8
        bytes.append(0)
    }

    mutating func write(_ value: DBusValue) throws {
        switch value {
        case .byte(let value): bytes.append(value)
        case .boolean(let value): integer(UInt32(value ? 1 : 0))
        case .int16(let value): integer(value)
        case .uint16(let value): integer(value)
        case .int32(let value): integer(value)
        case .uint32(let value): integer(value)
        case .int64(let value): integer(value)
        case .uint64(let value): integer(value)
        case .double(let value): integer(value.bitPattern)
        case .string(let value), .objectPath(let value): text(value)
        case .signature(let value):
            let utf8 = Array(value.utf8)
            guard utf8.count < 256 else { throw DBusError.protocolViolation("signature too long") }
            bytes.append(UInt8(utf8.count))
            bytes += utf8
            bytes.append(0)
        case .unixFD(let value): integer(value)
        case .array(let element, let values):
            integer(UInt32(0))
            let lengthAt = bytes.count - 4
            pad(to: DBusWriter.alignment(of: element))
            let start = bytes.count
            for value in values {
                guard value.signature == element else {
                    throw DBusError.protocolViolation("array of \(element) holds a \(value.signature)")
                }
                try write(value)
            }
            let length = UInt32(bytes.count - start)
            for index in 0..<4 { bytes[lengthAt + index] = UInt8(truncatingIfNeeded: length >> (8 * index)) }
        case .dictEntry(let key, let value):
            pad(to: 8)
            try write(key)
            try write(value)
        case .structure(let fields):
            pad(to: 8)
            for field in fields { try write(field) }
        case .variant(let inner):
            try write(.signature(inner.signature))
            try write(inner)
        }
    }

    /// The alignment of the first byte of a value of `signature`.
    static func alignment(of signature: String) -> Int {
        switch signature.utf8.first {
        case UInt8(ascii: "n"), UInt8(ascii: "q"): 2
        case UInt8(ascii: "b"), UInt8(ascii: "i"), UInt8(ascii: "u"), UInt8(ascii: "s"), UInt8(ascii: "o"),
             UInt8(ascii: "a"), UInt8(ascii: "h"): 4
        case UInt8(ascii: "x"), UInt8(ascii: "t"), UInt8(ascii: "d"), UInt8(ascii: "("), UInt8(ascii: "{"): 8
        default: 1
        }
    }
}

/// Reads values in the D-Bus wire format from a whole message.
struct DBusReader {
    let bytes: [UInt8]
    let bigEndian: Bool
    var offset: Int

    init(_ bytes: [UInt8], bigEndian: Bool = false, offset: Int = 0) {
        self.bytes = bytes
        self.bigEndian = bigEndian
        self.offset = offset
    }

    mutating func align(to alignment: Int) throws {
        let aligned = (offset + alignment - 1) / alignment * alignment
        guard aligned <= bytes.count else { throw DBusError.protocolViolation("message ends early") }
        offset = aligned
    }

    mutating func integer<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
        let size = MemoryLayout<T>.size
        try align(to: size)
        guard offset + size <= bytes.count else { throw DBusError.protocolViolation("message ends early") }
        var value: T = 0
        for index in 0..<size {
            let byte = T(truncatingIfNeeded: bytes[offset + (bigEndian ? size - 1 - index : index)])
            value |= byte << (8 * index)
        }
        offset += size
        return value
    }

    mutating func text() throws -> String {
        let length = Int(try integer(UInt32.self))
        guard offset + length < bytes.count else { throw DBusError.protocolViolation("string runs past the end") }
        let value = String(decoding: bytes[offset..<(offset + length)], as: UTF8.self)
        offset += length + 1
        return value
    }

    mutating func signatureText() throws -> String {
        guard offset < bytes.count else { throw DBusError.protocolViolation("message ends early") }
        let length = Int(bytes[offset])
        guard offset + 1 + length < bytes.count else { throw DBusError.protocolViolation("signature runs past the end") }
        let value = String(decoding: bytes[(offset + 1)..<(offset + 1 + length)], as: UTF8.self)
        offset += length + 2
        return value
    }

    /// Reads one value of the single complete type `signature`.
    mutating func read(_ signature: String, depth: Int = 0) throws -> DBusValue {
        guard depth < 64 else { throw DBusError.protocolViolation("value nests too deeply") }
        let codes = Array(signature.utf8)
        guard let code = codes.first else { throw DBusError.protocolViolation("empty signature") }
        switch code {
        case UInt8(ascii: "y"):
            guard offset < bytes.count else { throw DBusError.protocolViolation("message ends early") }
            offset += 1
            return .byte(bytes[offset - 1])
        case UInt8(ascii: "b"): return .boolean(try integer(UInt32.self) != 0)
        case UInt8(ascii: "n"): return .int16(try integer(Int16.self))
        case UInt8(ascii: "q"): return .uint16(try integer(UInt16.self))
        case UInt8(ascii: "i"): return .int32(try integer(Int32.self))
        case UInt8(ascii: "u"): return .uint32(try integer(UInt32.self))
        case UInt8(ascii: "x"): return .int64(try integer(Int64.self))
        case UInt8(ascii: "t"): return .uint64(try integer(UInt64.self))
        case UInt8(ascii: "d"): return .double(Double(bitPattern: try integer(UInt64.self)))
        case UInt8(ascii: "h"): return .unixFD(try integer(UInt32.self))
        case UInt8(ascii: "s"): return .string(try text())
        case UInt8(ascii: "o"): return .objectPath(try text())
        case UInt8(ascii: "g"): return .signature(try signatureText())
        case UInt8(ascii: "v"):
            let inner = try signatureText()
            guard try DBusSignature.split(inner).count == 1 else { throw DBusError.protocolViolation("variant holds \(inner)") }
            return .variant(try read(inner, depth: depth + 1))
        case UInt8(ascii: "a"):
            let element = String(decoding: codes.dropFirst(), as: UTF8.self)
            let length = Int(try integer(UInt32.self))
            try align(to: DBusWriter.alignment(of: element))
            let end = offset + length
            guard end <= bytes.count else { throw DBusError.protocolViolation("array runs past the end") }
            var values: [DBusValue] = []
            while offset < end {
                values.append(try read(element, depth: depth + 1))
            }
            guard offset == end else { throw DBusError.protocolViolation("array length doesn't match its elements") }
            return .array(element: element, values)
        case UInt8(ascii: "("):
            try align(to: 8)
            let inner = String(decoding: codes.dropFirst().dropLast(), as: UTF8.self)
            return .structure(try DBusSignature.split(inner).map { try read($0, depth: depth + 1) })
        case UInt8(ascii: "{"):
            try align(to: 8)
            let inner = try DBusSignature.split(String(decoding: codes.dropFirst().dropLast(), as: UTF8.self))
            guard inner.count == 2 else { throw DBusError.protocolViolation("dictionary entry of \(signature)") }
            return .dictEntry(try read(inner[0], depth: depth + 1), try read(inner[1], depth: depth + 1))
        default:
            throw DBusError.protocolViolation("unknown type \(signature)")
        }
    }
}
