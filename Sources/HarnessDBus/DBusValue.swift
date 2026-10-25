/// A value in a D-Bus message, carrying enough type information to be written back.
public indirect enum DBusValue: Sendable, Equatable {
    case byte(UInt8)
    case boolean(Bool)
    case int16(Int16)
    case uint16(UInt16)
    case int32(Int32)
    case uint32(UInt32)
    case int64(Int64)
    case uint64(UInt64)
    case double(Double)
    case string(String)
    case objectPath(String)
    case signature(String)
    case unixFD(UInt32)
    /// An array of values of the single complete type `element`.
    case array(element: String, [DBusValue])
    case dictEntry(DBusValue, DBusValue)
    case structure([DBusValue])
    case variant(DBusValue)

    /// The value's D-Bus type signature.
    public var signature: String {
        switch self {
        case .byte: "y"
        case .boolean: "b"
        case .int16: "n"
        case .uint16: "q"
        case .int32: "i"
        case .uint32: "u"
        case .int64: "x"
        case .uint64: "t"
        case .double: "d"
        case .string: "s"
        case .objectPath: "o"
        case .signature: "g"
        case .unixFD: "h"
        case .array(let element, _): "a" + element
        case .dictEntry(let key, let value): "{" + key.signature + value.signature + "}"
        case .structure(let fields): "(" + fields.map(\.signature).joined() + ")"
        case .variant: "v"
        }
    }

    /// A string-to-variant dictionary, the `a{sv}` D-Bus APIs use for options and properties.
    public static func properties(_ values: [String: DBusValue]) -> DBusValue {
        .array(element: "{sv}", values.sorted { $0.key < $1.key }.map { .dictEntry(.string($0.key), .variant($0.value)) })
    }

    /// The value inside any variants around it.
    public var unwrapped: DBusValue {
        if case .variant(let inner) = self { return inner.unwrapped }
        return self
    }

    /// The text of a string, object path or signature.
    public var string: String? {
        switch unwrapped {
        case .string(let text), .objectPath(let text), .signature(let text): text
        default: nil
        }
    }

    public var bool: Bool? {
        if case .boolean(let value) = unwrapped { return value }
        return nil
    }

    /// Any integer that fits in an `Int`.
    public var int: Int? {
        switch unwrapped {
        case .byte(let value): Int(value)
        case .int16(let value): Int(value)
        case .uint16(let value): Int(value)
        case .int32(let value): Int(value)
        case .uint32(let value): Int(value)
        case .int64(let value): Int(value)
        case .uint64(let value): Int(exactly: value)
        case .unixFD(let value): Int(value)
        default: nil
        }
    }

    /// A double, or any integer as a double.
    public var double: Double? {
        if case .double(let value) = unwrapped { return value }
        return int.map(Double.init)
    }

    /// The elements of an array.
    public var elements: [DBusValue]? {
        if case .array(_, let values) = unwrapped { return values }
        return nil
    }

    /// The fields of a structure.
    public var fields: [DBusValue]? {
        if case .structure(let values) = unwrapped { return values }
        return nil
    }

    /// The entries of a dictionary with string keys.
    public var dictionary: [String: DBusValue]? {
        guard let elements else { return nil }
        var result: [String: DBusValue] = [:]
        for element in elements {
            guard case .dictEntry(let key, let value) = element, let name = key.string else { return nil }
            result[name] = value
        }
        return result
    }
}

/// Splitting and checking D-Bus type signatures.
public enum DBusSignature {
    /// The complete types a signature lists, in order.
    public static func split(_ signature: String) throws -> [String] {
        let bytes = Array(signature.utf8)
        var types: [String] = []
        var start = 0
        while start < bytes.count {
            let end = try completeTypeEnd(bytes, from: start)
            types.append(String(decoding: bytes[start..<end], as: UTF8.self))
            start = end
        }
        return types
    }

    /// Where the complete type starting at `start` ends.
    static func completeTypeEnd(_ bytes: [UInt8], from start: Int, depth: Int = 0) throws -> Int {
        guard depth < 64 else { throw DBusError.protocolViolation("signature nests too deeply") }
        guard start < bytes.count else { throw DBusError.protocolViolation("signature ends early") }
        switch bytes[start] {
        case UInt8(ascii: "a"):
            return try completeTypeEnd(bytes, from: start + 1, depth: depth + 1)
        case UInt8(ascii: "("):
            var index = start + 1
            while index < bytes.count, bytes[index] != UInt8(ascii: ")") {
                index = try completeTypeEnd(bytes, from: index, depth: depth + 1)
            }
            guard index < bytes.count, index > start + 1 else { throw DBusError.protocolViolation("bad structure in signature") }
            return index + 1
        case UInt8(ascii: "{"):
            let key = try completeTypeEnd(bytes, from: start + 1, depth: depth + 1)
            let value = try completeTypeEnd(bytes, from: key, depth: depth + 1)
            guard value < bytes.count, bytes[value] == UInt8(ascii: "}") else {
                throw DBusError.protocolViolation("bad dictionary entry in signature")
            }
            return value + 1
        case let code where basicTypes.contains(code) || code == UInt8(ascii: "v"):
            return start + 1
        default:
            throw DBusError.protocolViolation("unknown type code in signature \(String(decoding: bytes, as: UTF8.self))")
        }
    }

    static let basicTypes: Set<UInt8> = Set("ybnqiuxtdsogh".utf8)
}
