import CoreGraphics
import Foundation
import HarnessProtocol
import Vision

/// Finds text drawn in a window with on-device text recognition, for text the accessibility tree
/// doesn't have (canvases, hidden trees).
public enum OCRService {
    /// Text found in the window: what was asked for, where it is in window points, and the line it's in.
    public struct Found: Sendable, Equatable {
        public var text: String
        public var line: String
        public var frame: CGRect
    }

    /// Places in the window where `query` appears (each line once), or every line when `query` is nil.
    public static func find(_ query: String?, exact: Bool, in window: WindowService.Window, app: AppRef) async throws -> [Found] {
        let image = try await ScreenshotService.image(of: window, app: app, maxSize: 0)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        let size = CGSize(width: window.info.frame.width, height: window.info.frame.height)
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return match(query, exact: exact, in: candidate, size: size)
        }
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
        let frame = Rect(x: found.frame.minX, y: found.frame.minY, width: found.frame.width, height: found.frame.height)
        return UINode(
            ref: "o\(index)", role: "AXStaticText", subrole: "AXOCRText", label: found.text,
            value: found.line == found.text ? nil : found.line, frame: frame,
            hit: Point(x: (found.frame.midX).rounded(), y: (found.frame.midY).rounded())
        )
    }
}
