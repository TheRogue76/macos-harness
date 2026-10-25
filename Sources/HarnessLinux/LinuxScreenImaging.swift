import Foundation
import HarnessCore
import HarnessImaging
import HarnessProtocol

/// Device screenshots rendered in Swift, and text recognition through the `tesseract` command.
public struct LinuxScreenImaging: ScreenImaging {
    let tesseract: String?

    public init(path: String? = ProcessInfo.processInfo.environment["PATH"]) {
        let directories = (path ?? "/usr/bin:/bin").split(separator: ":").map(String.init)
        tesseract = directories.map { "\($0)/tesseract" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public func render(_ png: Data, request: ScreenRender) throws -> RenderedScreen {
        var image = try Self.decode(png)
        let longest = max(image.width, image.height)
        if request.maxSize > 0, longest > request.maxSize {
            image = image.resized(by: Double(request.maxSize) / Double(longest))
        }
        let scale = Double(image.width) / max(Double(request.screenSize.width), 1)
        var crop: Rect?
        if let frame = request.crop {
            let left = (Double(frame.minX) * scale).rounded(.down), top = (Double(frame.minY) * scale).rounded(.down)
            let right = (Double(frame.maxX) * scale).rounded(.up), bottom = (Double(frame.maxY) * scale).rounded(.up)
            if let cropped = image.cropped(x: Int(left), y: Int(top), width: Int(right - left), height: Int(bottom - top)) {
                image = cropped
                crop = Rect(x: Double(frame.minX), y: Double(frame.minY), width: Double(frame.width), height: Double(frame.height))
            }
        }
        let origin = (x: crop?.x ?? 0, y: crop?.y ?? 0)
        if let spacing = request.grid {
            Markup.draw(grid: spacing, on: &image, scale: scale, origin: origin)
        }
        if let labels = request.labels {
            let boxes = labels.compactMap { node in
                node.frame.map { Markup.Label(x: $0.x, y: $0.y, width: $0.width, height: $0.height, ref: node.ref) }
            }
            Markup.draw(labels: boxes, on: &image, scale: scale, origin: origin)
        }
        return RenderedScreen(png: PNG.encode(image), width: image.width, height: image.height, scale: scale, crop: crop)
    }

    public func findText(_ query: String?, exact: Bool, inPNG png: Data, size: CGSize) async throws -> [TextMatch] {
        guard let tesseract else {
            throw RPCError(
                code: RPCErrorCode.failed,
                message: "Text recognition on Linux needs Tesseract: install the tesseract-ocr package (tesseract on Fedora and Arch)."
            )
        }
        let pixels = try PNG.size(of: png)
        let output = try await ToolRunner.run(tesseract, ["stdin", "stdout", "--psm", "11", "tsv"], input: png, timeout: 60).text
        let pointsPerPixel = Double(size.width) / Double(max(pixels.width, 1))
        return Self.lines(fromTSV: output).compactMap { Self.match(query, exact: exact, in: $0, pointsPerPixel: pointsPerPixel) }
    }

    static func decode(_ png: Data) throws -> Bitmap {
        do {
            return try PNG.decode(png)
        } catch {
            throw ScreenImagingError.unreadable
        }
    }

    /// A line Tesseract read: its words and their boxes, in image pixels.
    struct Line: Equatable {
        struct Word: Equatable {
            var text: String
            var left: Double
            var top: Double
            var width: Double
            var height: Double
        }

        var words: [Word]

        var text: String { words.map(\.text).joined(separator: " ") }
    }

    /// The lines in Tesseract's TSV output, in reading order.
    static func lines(fromTSV tsv: String) -> [Line] {
        var order: [String] = []
        var lines: [String: Line] = [:]
        for row in tsv.split(separator: "\n").dropFirst() {
            let fields = row.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 12, fields[0] == "5" else { continue }
            let text = fields[11...].joined(separator: "\t").trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, let left = Double(fields[6]), let top = Double(fields[7]),
                  let width = Double(fields[8]), let height = Double(fields[9]) else { continue }
            let key = "\(fields[1]).\(fields[2]).\(fields[3]).\(fields[4])"
            if lines[key] == nil {
                order.append(key)
                lines[key] = Line(words: [])
            }
            lines[key]?.words.append(Line.Word(text: text, left: left, top: top, width: width, height: height))
        }
        return order.compactMap { lines[$0] }
    }

    /// Where `query` appears in `line`, as the matched text, the line and the box around the words
    /// it covers in target points; every line when `query` is nil.
    static func match(_ query: String?, exact: Bool, in line: Line, pointsPerPixel: Double) -> TextMatch? {
        let text = line.text
        guard let query, !query.isEmpty else { return found(text, in: line, words: line.words, scale: pointsPerPixel) }
        if exact {
            guard text.compare(query, options: [.caseInsensitive]) == .orderedSame else { return nil }
            return found(text, in: line, words: line.words, scale: pointsPerPixel)
        }
        guard let range = text.range(of: query, options: [.caseInsensitive]) else { return nil }
        let start = text.distance(from: text.startIndex, to: range.lowerBound)
        let end = text.distance(from: text.startIndex, to: range.upperBound)
        var offset = 0
        var covered: [Line.Word] = []
        for word in line.words {
            let wordEnd = offset + word.text.count
            if wordEnd > start && offset < end { covered.append(word) }
            offset = wordEnd + 1
        }
        return found(String(text[range]), in: line, words: covered, scale: pointsPerPixel)
    }

    static func found(_ text: String, in line: Line, words: [Line.Word], scale: Double) -> TextMatch? {
        guard let first = words.first else { return nil }
        var left = first.left, top = first.top, right = first.left + first.width, bottom = first.top + first.height
        for word in words.dropFirst() {
            left = min(left, word.left)
            top = min(top, word.top)
            right = max(right, word.left + word.width)
            bottom = max(bottom, word.top + word.height)
        }
        let frame = CGRect(x: left * scale, y: top * scale, width: (right - left) * scale, height: (bottom - top) * scale)
        return TextMatch(text: text, line: line.text, frame: frame)
    }
}
