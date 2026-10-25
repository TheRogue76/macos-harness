import Foundation

/// The labels and grid drawn on screenshots, in the same colors as on macOS.
public enum Markup {
    static let accent = Bitmap.Color(red: 255, green: 41, blue: 140)
    static let gridLine = Bitmap.Color(red: 0, green: 191, blue: 255, alpha: 115)
    static let gridTag = Bitmap.Color(red: 0, green: 115, blue: 191, alpha: 217)

    /// A labeled box: its place in target points and its ref.
    public struct Label: Sendable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double
        public var ref: String

        public init(x: Double, y: Double, width: Double, height: Double, ref: String) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
            self.ref = ref
        }
    }

    /// Outlines each element and tags it with its ref, `scale` image pixels per target point, with
    /// the image's top-left corner at `origin` in target points.
    public static func draw(labels: [Label], on image: inout Bitmap, scale: Double, origin: (x: Double, y: Double)) {
        let fontScale = max(1, Int((max(10, 8 * scale) / Double(BitmapFont.glyphHeight)).rounded()))
        let padding = max(3, Int((2 * scale).rounded()))
        let line = max(1, Int((scale * 0.75).rounded()))
        for label in labels {
            let x = Int(((label.x - origin.x) * scale).rounded()), y = Int(((label.y - origin.y) * scale).rounded())
            let width = Int((label.width * scale).rounded()), height = Int((label.height * scale).rounded())
            image.stroke(x: x, y: y, width: width, height: height, lineWidth: line, color: accent)
            let text = BitmapFont.size(of: label.ref, scale: fontScale)
            image.fill(x: x, y: y, width: text.width + 2 * padding, height: text.height + 2 * padding, color: accent)
            BitmapFont.draw(label.ref, on: &image, x: x + padding, y: y + padding, scale: fontScale, color: .white)
        }
    }

    /// Lines every `spacing` target points, tagged with their coordinates.
    public static func draw(grid spacing: Double, on image: inout Bitmap, scale: Double, origin: (x: Double, y: Double)) {
        let fontScale = max(1, Int((max(9, 7 * scale) / Double(BitmapFont.glyphHeight)).rounded()))
        let padding = max(2, Int((1.5 * scale).rounded()))
        let line = max(1, Int((scale * 0.5).rounded()))
        let visible = (width: Double(image.width) / scale, height: Double(image.height) / scale)
        func tag(_ text: String, x: Int, y: Int) {
            let size = BitmapFont.size(of: text, scale: fontScale)
            image.fill(x: x, y: y, width: size.width + 2 * padding, height: size.height + 2 * padding, color: gridTag)
            BitmapFont.draw(text, on: &image, x: x + padding, y: y + padding, scale: fontScale, color: .white)
        }
        var x = (origin.x / spacing).rounded(.up) * spacing
        while x - origin.x < visible.width {
            let pixel = Int(((x - origin.x) * scale).rounded())
            image.fill(x: pixel, y: 0, width: line, height: image.height, color: gridLine)
            tag("\(Int(x))", x: pixel + 2, y: 2)
            x += spacing
        }
        var y = (origin.y / spacing).rounded(.up) * spacing
        while y - origin.y < visible.height {
            let pixel = Int(((y - origin.y) * scale).rounded())
            image.fill(x: 0, y: pixel, width: image.width, height: line, color: gridLine)
            if y > 0 { tag("\(Int(y))", x: 2, y: pixel + 2) }
            y += spacing
        }
    }
}
