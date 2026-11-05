import Foundation

/// A reader for the XML `uiautomator dump` writes: elements with quoted attributes, the XML
/// declaration, comments and character references, and no DTDs or namespaces. It needs no
/// libxml2, which Linux distributions ship under different library names.
enum AndroidXML {
    /// One step through the document.
    enum Event: Equatable {
        case start(String, [String: String])
        case end(String)
    }

    struct Malformed: Error, CustomStringConvertible {
        var description: String
    }

    /// The document's elements in order, a self-closing one as a start then an end.
    static func events(in text: String) throws -> [Event] {
        var events: [Event] = []
        let scalars = Array(text.unicodeScalars)
        var index = 0

        func fail(_ what: String) -> Malformed {
            Malformed(description: "\(what) at character \(index)")
        }

        func skip(past terminator: String) throws {
            let marker = Array(terminator.unicodeScalars)
            while index + marker.count <= scalars.count {
                if scalars[index..<index + marker.count].elementsEqual(marker) {
                    index += marker.count
                    return
                }
                index += 1
            }
            throw fail("missing \(terminator)")
        }

        func skipSpace() {
            while index < scalars.count, scalars[index].properties.isWhitespace { index += 1 }
        }

        func name() throws -> String {
            let start = index
            while index < scalars.count, !scalars[index].properties.isWhitespace, !"/>=".unicodeScalars.contains(scalars[index]) {
                index += 1
            }
            guard index > start else { throw fail("expected a name") }
            return String(String.UnicodeScalarView(scalars[start..<index]))
        }

        while index < scalars.count {
            guard scalars[index] == "<" else {
                index += 1
                continue
            }
            if index + 1 < scalars.count, scalars[index + 1] == "?" {
                try skip(past: "?>")
            } else if index + 3 < scalars.count, scalars[index + 1] == "!", scalars[index + 2] == "-", scalars[index + 3] == "-" {
                try skip(past: "-->")
            } else if index + 1 < scalars.count, scalars[index + 1] == "/" {
                index += 2
                let element = try name()
                skipSpace()
                guard index < scalars.count, scalars[index] == ">" else { throw fail("unclosed end tag") }
                index += 1
                events.append(.end(element))
            } else {
                index += 1
                let element = try name()
                var attributes: [String: String] = [:]
                while true {
                    skipSpace()
                    guard index < scalars.count else { throw fail("unclosed start tag") }
                    if scalars[index] == ">" {
                        index += 1
                        events.append(.start(element, attributes))
                        break
                    }
                    if scalars[index] == "/" {
                        guard index + 1 < scalars.count, scalars[index + 1] == ">" else { throw fail("expected />") }
                        index += 2
                        events.append(.start(element, attributes))
                        events.append(.end(element))
                        break
                    }
                    let attribute = try name()
                    skipSpace()
                    guard index < scalars.count, scalars[index] == "=" else { throw fail("expected =") }
                    index += 1
                    skipSpace()
                    guard index < scalars.count, scalars[index] == "\"" || scalars[index] == "'" else { throw fail("expected a quoted value") }
                    let quote = scalars[index]
                    index += 1
                    let start = index
                    while index < scalars.count, scalars[index] != quote { index += 1 }
                    guard index < scalars.count else { throw fail("unclosed attribute value") }
                    attributes[attribute] = try decode(String(String.UnicodeScalarView(scalars[start..<index])))
                    index += 1
                }
            }
        }
        return events
    }

    /// `value` with its entity and character references replaced.
    static func decode(_ value: String) throws -> String {
        guard value.contains("&") else { return value }
        var result = ""
        var rest = Substring(value)
        while let ampersand = rest.firstIndex(of: "&") {
            result += rest[..<ampersand]
            guard let semicolon = rest[ampersand...].firstIndex(of: ";") else { throw Malformed(description: "unfinished reference in “\(value)”") }
            let reference = rest[rest.index(after: ampersand)..<semicolon]
            switch reference {
            case "amp": result += "&"
            case "lt": result += "<"
            case "gt": result += ">"
            case "quot": result += "\""
            case "apos": result += "'"
            default:
                let number: UInt32? = reference.hasPrefix("#x") || reference.hasPrefix("#X")
                    ? UInt32(reference.dropFirst(2), radix: 16)
                    : reference.hasPrefix("#") ? UInt32(reference.dropFirst()) : nil
                guard let number, let scalar = Unicode.Scalar(number) else {
                    throw Malformed(description: "unknown reference &\(reference); in “\(value)”")
                }
                result.unicodeScalars.append(scalar)
            }
            rest = rest[rest.index(after: semicolon)...]
        }
        return result + rest
    }
}
