import CoreGraphics
import Foundation
import HarnessProtocol
import Vision
import HarnessCore

/// Finds text drawn in a window with on-device text recognition, for text the accessibility tree
/// doesn't have (canvases, hidden trees).
public enum OCRService {
    /// Text found in the window: what was asked for, where it is in window points, and the line it's in.
    public typealias Found = TextMatch

    /// Places in the window where `query` appears (each line once), or every line when `query` is nil.
    public static func find(_ query: String?, exact: Bool, in window: WindowService.Window, app: AppRef) async throws -> [Found] {
        try await read(query, exact: exact, in: window, app: app).matches
    }

    /// One pass over the window: the places `query` appears, as `find` gives them, and every line
    /// it read, top to bottom.
    public static func read(_ query: String?, exact: Bool, in window: WindowService.Window, app: AppRef) async throws -> (matches: [Found], lines: [String]) {
        let image = try await ScreenshotService.image(of: window, app: app, maxSize: 0)
        return try read(query, exact: exact, image: image, size: window.space.size)
    }

    /// Places in an image where `query` appears, in the coordinates of a target `size` across.
    public static func find(_ query: String?, exact: Bool, image: CGImage, size: CGSize) throws -> [Found] {
        try read(query, exact: exact, image: image, size: size).matches
    }

    /// One pass over an image: the places `query` appears, and every line, top to bottom.
    static func read(_ query: String?, exact: Bool, image: CGImage, size: CGSize) throws -> (matches: [Found], lines: [String]) {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        let candidates = (request.results ?? []).compactMap { observation in
            observation.topCandidates(1).first.map { (box: observation.boundingBox, text: $0) }
        }
        let matches = candidates.compactMap { match(query, exact: exact, in: $0.text, size: size) }
        return (matches, inReadingOrder(candidates.map { ($0.box, $0.text.string) }))
    }

    /// Lines by their Vision boxes (normalized, origin at the bottom left): rows top to bottom, a row
    /// being the lines whose middles sit within half a line's height of its first, each left to right.
    static func inReadingOrder(_ lines: [(box: CGRect, text: String)]) -> [String] {
        var rows: [[(box: CGRect, text: String)]] = []
        for line in lines.sorted(by: { $0.box.midY > $1.box.midY }) {
            if let first = rows.last?.first, first.box.midY - line.box.midY <= first.box.height / 2 {
                rows[rows.count - 1].append(line)
            } else {
                rows.append([line])
            }
        }
        return rows.flatMap { row in row.sorted { $0.box.minX < $1.box.minX }.map(\.text) }
    }

    static func match(_ query: String?, exact: Bool, in candidate: VNRecognizedText, size: CGSize) -> Found? {
        let line = candidate.string
        guard let query, !query.isEmpty else {
            return (try? candidate.boundingBox(for: line.startIndex..<line.endIndex)).map {
                Found(text: line, line: line, frame: windowRect($0.boundingBox, size: size))
            }
        }
        if exact {
            guard line.compare(query, options: [.caseInsensitive]) == .orderedSame,
                  let box = try? candidate.boundingBox(for: line.startIndex..<line.endIndex) else { return nil }
            return Found(text: line, line: line, frame: windowRect(box.boundingBox, size: size))
        }
        guard let range = line.range(of: query, options: [.caseInsensitive]),
              let box = try? candidate.boundingBox(for: range) else { return nil }
        return Found(text: String(line[range]), line: line, frame: windowRect(box.boundingBox, size: size))
    }

    /// A Vision box (normalized, origin at the bottom left) in window points (origin at the top left).
    static func windowRect(_ box: CGRect, size: CGSize) -> CGRect {
        CGRect(x: box.minX * size.width, y: (1 - box.maxY) * size.height, width: box.width * size.width, height: box.height * size.height)
    }

    /// Found text as an element without a ref: it can't be pressed, but its click point can be.
    public static func node(_ found: Found, index: Int) -> UINode {
        found.node(index: index)
    }
}
