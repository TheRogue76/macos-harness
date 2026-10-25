import CZlib
import Foundation

/// Reads and writes PNG images: 8-bit grayscale, RGB, palette, gray with alpha and RGBA, not
/// interlaced, which covers device screenshots.
public enum PNG {
    /// Why an image couldn't be read.
    public enum DecodeError: Error, Equatable, Sendable {
        case notPNG
        case unsupported(String)
        case corrupt(String)
    }

    /// A row filter, as the format numbers them.
    enum Filter: UInt8, CaseIterable {
        case none = 0, sub, up, average, paeth
    }

    static let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]

    /// The width and height an image's header gives, without decoding it.
    public static func size(of data: Data) throws -> (width: Int, height: Int) {
        let bytes = [UInt8](data.prefix(24))
        guard bytes.count == 24, Array(bytes[0..<8]) == signature, Array(bytes[12..<16]) == Array("IHDR".utf8) else {
            throw DecodeError.notPNG
        }
        return (Int(bigEndian: bytes, at: 16), Int(bigEndian: bytes, at: 20))
    }

    public static func decode(_ data: Data) throws -> Bitmap {
        let bytes = [UInt8](data)
        guard bytes.count > 8, Array(bytes[0..<8]) == signature else { throw DecodeError.notPNG }
        var offset = 8
        var header: (width: Int, height: Int, depth: UInt8, color: UInt8, interlace: UInt8)?
        var palette: [UInt8] = []
        var transparency: [UInt8] = []
        var compressed: [UInt8] = []
        while offset + 8 <= bytes.count {
            let length = Int(bigEndian: bytes, at: offset)
            let type = String(decoding: bytes[(offset + 4)..<(offset + 8)], as: UTF8.self)
            let start = offset + 8
            guard length >= 0, start + length + 4 <= bytes.count else { throw DecodeError.corrupt("chunk \(type) runs past the end") }
            let body = bytes[start..<(start + length)]
            switch type {
            case "IHDR":
                guard length == 13 else { throw DecodeError.corrupt("bad header") }
                header = (Int(bigEndian: bytes, at: start), Int(bigEndian: bytes, at: start + 4), bytes[start + 8], bytes[start + 9], bytes[start + 12])
            case "PLTE": palette = Array(body)
            case "tRNS": transparency = Array(body)
            case "IDAT": compressed.append(contentsOf: body)
            case "IEND": offset = bytes.count
            default: break
            }
            offset = start + length + 4
        }
        guard let header, header.width > 0, header.height > 0 else { throw DecodeError.corrupt("no header") }
        guard header.depth == 8 else { throw DecodeError.unsupported("bit depth \(header.depth)") }
        guard header.interlace == 0 else { throw DecodeError.unsupported("interlacing") }
        let channels: Int
        switch header.color {
        case 0: channels = 1
        case 2: channels = 3
        case 3: channels = 1
        case 4: channels = 2
        case 6: channels = 4
        default: throw DecodeError.unsupported("color type \(header.color)")
        }
        let stride = header.width * channels
        let raw = try inflate(compressed, expected: header.height * (stride + 1))
        let rows = try unfilter(raw, rows: header.height, stride: stride, bytesPerPixel: channels)
        var pixels = [UInt8](repeating: 255, count: header.width * header.height * 4)
        for index in 0..<(header.width * header.height) {
            let source = index * channels
            let target = index * 4
            switch header.color {
            case 0:
                pixels[target] = rows[source]; pixels[target + 1] = rows[source]; pixels[target + 2] = rows[source]
            case 2:
                pixels[target] = rows[source]; pixels[target + 1] = rows[source + 1]; pixels[target + 2] = rows[source + 2]
            case 3:
                let entry = Int(rows[source])
                guard entry * 3 + 2 < palette.count else { throw DecodeError.corrupt("palette index \(entry) out of range") }
                pixels[target] = palette[entry * 3]; pixels[target + 1] = palette[entry * 3 + 1]; pixels[target + 2] = palette[entry * 3 + 2]
                if entry < transparency.count { pixels[target + 3] = transparency[entry] }
            case 4:
                pixels[target] = rows[source]; pixels[target + 1] = rows[source]; pixels[target + 2] = rows[source]
                pixels[target + 3] = rows[source + 1]
            default:
                pixels[target] = rows[source]; pixels[target + 1] = rows[source + 1]
                pixels[target + 2] = rows[source + 2]; pixels[target + 3] = rows[source + 3]
            }
        }
        return Bitmap(width: header.width, height: header.height, pixels: pixels)
    }

    /// The image as an RGBA PNG.
    public static func encode(_ image: Bitmap) -> Data {
        encode(image, filters: [.sub])
    }

    /// The image as an RGBA PNG, its rows filtered with `filters` in turn.
    static func encode(_ image: Bitmap, filters: [Filter]) -> Data {
        let stride = image.width * 4
        var raw: [UInt8] = []
        raw.reserveCapacity(image.height * (stride + 1))
        for row in 0..<image.height {
            let filter = filters[row % filters.count]
            raw.append(filter.rawValue)
            let start = row * stride
            for column in 0..<stride {
                let value = image.pixels[start + column]
                let left = column >= 4 ? image.pixels[start + column - 4] : 0
                let up = row > 0 ? image.pixels[start + column - stride] : 0
                let upLeft = row > 0 && column >= 4 ? image.pixels[start + column - stride - 4] : 0
                raw.append(value &- predict(filter, left: left, up: up, upLeft: upLeft))
            }
        }
        var header: [UInt8] = []
        header.appendBigEndian(UInt32(image.width))
        header.appendBigEndian(UInt32(image.height))
        header += [8, 6, 0, 0, 0]
        var out = signature
        out += chunk("IHDR", header)
        out += chunk("IDAT", deflate(raw))
        out += chunk("IEND", [])
        return Data(out)
    }

    static func predict(_ filter: Filter, left: UInt8, up: UInt8, upLeft: UInt8) -> UInt8 {
        switch filter {
        case .none: return 0
        case .sub: return left
        case .up: return up
        case .average: return UInt8((Int(left) + Int(up)) / 2)
        case .paeth:
            let estimate = Int(left) + Int(up) - Int(upLeft)
            let distances = (abs(estimate - Int(left)), abs(estimate - Int(up)), abs(estimate - Int(upLeft)))
            if distances.0 <= distances.1 && distances.0 <= distances.2 { return left }
            return distances.1 <= distances.2 ? up : upLeft
        }
    }

    static func unfilter(_ raw: [UInt8], rows: Int, stride: Int, bytesPerPixel: Int) throws -> [UInt8] {
        guard raw.count >= rows * (stride + 1) else { throw DecodeError.corrupt("image data too short") }
        var out = [UInt8](repeating: 0, count: rows * stride)
        for row in 0..<rows {
            guard let filter = Filter(rawValue: raw[row * (stride + 1)]) else { throw DecodeError.corrupt("unknown row filter") }
            let source = row * (stride + 1) + 1
            let target = row * stride
            for column in 0..<stride {
                let left = column >= bytesPerPixel ? out[target + column - bytesPerPixel] : 0
                let up = row > 0 ? out[target + column - stride] : 0
                let upLeft = row > 0 && column >= bytesPerPixel ? out[target + column - stride - bytesPerPixel] : 0
                out[target + column] = raw[source + column] &+ predict(filter, left: left, up: up, upLeft: upLeft)
            }
        }
        return out
    }

    static func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.appendBigEndian(UInt32(body.count))
        let typed = Array(type.utf8) + body
        out += typed
        out.appendBigEndian(checksum(typed))
        return out
    }

    static func checksum(_ bytes: [UInt8]) -> UInt32 {
        UInt32(truncatingIfNeeded: unsafe crc32(0, bytes, uInt(bytes.count)))
    }

    static func deflate(_ bytes: [UInt8]) -> [UInt8] {
        var length = compressBound(uLong(bytes.count))
        var out = [UInt8](repeating: 0, count: Int(length))
        let status = unsafe compress2(&out, &length, bytes, uLong(bytes.count), 6)
        precondition(status == Z_OK, "zlib couldn't compress (\(status))")
        return Array(out.prefix(Int(length)))
    }

    static func inflate(_ bytes: [UInt8], expected: Int) throws -> [UInt8] {
        var length = uLongf(expected)
        var out = [UInt8](repeating: 0, count: expected)
        let status = unsafe uncompress(&out, &length, bytes, uLong(bytes.count))
        guard status == Z_OK, Int(length) == expected else { throw DecodeError.corrupt("image data doesn't inflate (\(status))") }
        return out
    }
}

extension Int {
    /// A big-endian 32-bit number in `bytes` at `offset`.
    init(bigEndian bytes: [UInt8], at offset: Int) {
        self = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
    }
}

extension Array where Element == UInt8 {
    mutating func appendBigEndian(_ value: UInt32) {
        append(contentsOf: [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
    }
}
