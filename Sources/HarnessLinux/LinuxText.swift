#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import HarnessCore
import HarnessProtocol

/// Text recognition on desktop apps, for content without an accessibility tree: the window's
/// pixels from the compositor, read by Tesseract, as on Android.
extension LinuxDesktop {
    /// Where text recognition finds `query` in the window (every line when it's nil), in the
    /// window's points.
    static func recognizeText(_ query: String?, exact: Bool, in place: Place) async throws -> [TextMatch] {
        let compositor = try await Compositors.required(for: "--ocr")
        guard let placed = place.placed else {
            throw RPCError(code: RPCErrorCode.failed, message: "\(compositor.name) doesn't show \(place.ref.name)'s window, so its pixels can't be read.")
        }
        let (png, _) = try await compositor.capture(placed)
        let size = CGSize(width: place.info.frame.width, height: place.info.frame.height)
        return try await ScreenImagingProvider.imaging().findText(query, exact: exact, inPNG: png, size: size)
    }

    /// The one place text recognition finds the selector's text, preferring a line that is
    /// exactly that text, or why there isn't one.
    static func recognizedPoint(_ selector: ElementSelector, in place: Place) async throws -> CGPoint {
        guard let text = selector.text, !text.isEmpty else {
            throw RPCError(code: RPCErrorCode.invalidParams, message: "OCR needs the text to look for.")
        }
        let found = try await recognizeText(text, exact: selector.exact, in: place)
        let exact = found.filter { $0.line.compare(text, options: .caseInsensitive) == .orderedSame }
        let candidates = exact.isEmpty ? found : exact
        guard let first = candidates.first else {
            throw RPCError(code: RPCErrorCode.notFound, message: "Text recognition didn't find “\(text)” in the window.")
        }
        guard candidates.count == 1 else {
            let places = candidates.prefix(8).map { "“\($0.line)” @\(Int($0.frame.midX)),\(Int($0.frame.midY))" }.joined(separator: "; ")
            throw RPCError(code: RPCErrorCode.failed, message: "“\(text)” appears \(candidates.count) times: \(places). Click one with --x and --y, or be more specific.")
        }
        return CGPoint(x: first.frame.midX, y: first.frame.midY)
    }
}
