import Foundation

/// An 8-bit RGBA image held in memory, top row first.
public struct Bitmap: Sendable, Equatable {
    public let width: Int
    public let height: Int
    /// Four bytes per pixel (red, green, blue, alpha), row after row.
    public private(set) var pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(width > 0 && height > 0 && pixels.count == width * height * 4)
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public init(width: Int, height: Int, color: Color = .clear) {
        self.init(width: width, height: height, pixels: Array([color.red, color.green, color.blue, color.alpha].repeating(width * height)))
    }

    /// A color with straight (not premultiplied) alpha.
    public struct Color: Sendable, Equatable {
        public var red: UInt8
        public var green: UInt8
        public var blue: UInt8
        public var alpha: UInt8

        public init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8 = 255) {
            self.red = red
            self.green = green
            self.blue = blue
            self.alpha = alpha
        }

        public static let clear = Color(red: 0, green: 0, blue: 0, alpha: 0)
        public static let white = Color(red: 255, green: 255, blue: 255)
    }

    /// The color at a pixel.
    public func color(x: Int, y: Int) -> Color {
        let index = (y * width + x) * 4
        return Color(red: pixels[index], green: pixels[index + 1], blue: pixels[index + 2], alpha: pixels[index + 3])
    }

    /// The image scaled by `factor`, averaging the source pixels each new pixel covers when it
    /// shrinks and taking the nearest when it grows.
    public func resized(by factor: Double) -> Bitmap {
        let newWidth = max(1, Int((Double(width) * factor).rounded()))
        let newHeight = max(1, Int((Double(height) * factor).rounded()))
        var out = [UInt8](repeating: 0, count: newWidth * newHeight * 4)
        let scaleX = Double(width) / Double(newWidth)
        let scaleY = Double(height) / Double(newHeight)
        for y in 0..<newHeight {
            let top = min(height - 1, Int(Double(y) * scaleY))
            let bottom = max(top + 1, min(height, Int((Double(y + 1) * scaleY).rounded(.up))))
            for x in 0..<newWidth {
                let left = min(width - 1, Int(Double(x) * scaleX))
                let right = max(left + 1, min(width, Int((Double(x + 1) * scaleX).rounded(.up))))
                var sums = [0, 0, 0, 0]
                for sourceY in top..<bottom {
                    var index = (sourceY * width + left) * 4
                    for _ in left..<right {
                        for channel in 0..<4 { sums[channel] += Int(pixels[index + channel]) }
                        index += 4
                    }
                }
                let count = (bottom - top) * (right - left)
                let target = (y * newWidth + x) * 4
                for channel in 0..<4 { out[target + channel] = UInt8((sums[channel] + count / 2) / count) }
            }
        }
        return Bitmap(width: newWidth, height: newHeight, pixels: out)
    }

    /// The part of the image inside a rectangle of pixels, clipped to the image; nil when nothing of
    /// it is inside.
    public func cropped(x: Int, y: Int, width cropWidth: Int, height cropHeight: Int) -> Bitmap? {
        let left = max(0, x), top = max(0, y)
        let right = min(width, x + cropWidth), bottom = min(height, y + cropHeight)
        guard right > left, bottom > top else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity((right - left) * (bottom - top) * 4)
        for row in top..<bottom {
            let start = (row * width + left) * 4
            out.append(contentsOf: pixels[start..<(start + (right - left) * 4)])
        }
        return Bitmap(width: right - left, height: bottom - top, pixels: out)
    }

    /// Paints a rectangle of pixels, blending by the color's alpha and clipping to the image.
    public mutating func fill(x: Int, y: Int, width fillWidth: Int, height fillHeight: Int, color: Color) {
        let left = max(0, x), top = max(0, y)
        let right = min(width, x + fillWidth), bottom = min(height, y + fillHeight)
        guard right > left, bottom > top else { return }
        let alpha = Int(color.alpha)
        let source = [Int(color.red), Int(color.green), Int(color.blue)]
        for row in top..<bottom {
            var index = (row * width + left) * 4
            for _ in left..<right {
                for channel in 0..<3 {
                    let below = Int(pixels[index + channel])
                    pixels[index + channel] = UInt8((source[channel] * alpha + below * (255 - alpha) + 127) / 255)
                }
                pixels[index + 3] = UInt8(min(255, alpha + Int(pixels[index + 3]) * (255 - alpha) / 255))
                index += 4
            }
        }
    }

    /// Draws a rectangle's outline `lineWidth` pixels thick, inside its bounds.
    public mutating func stroke(x: Int, y: Int, width boxWidth: Int, height boxHeight: Int, lineWidth: Int, color: Color) {
        let line = max(1, min(lineWidth, boxWidth, boxHeight))
        fill(x: x, y: y, width: boxWidth, height: line, color: color)
        fill(x: x, y: y + boxHeight - line, width: boxWidth, height: line, color: color)
        fill(x: x, y: y + line, width: line, height: boxHeight - 2 * line, color: color)
        fill(x: x + boxWidth - line, y: y + line, width: line, height: boxHeight - 2 * line, color: color)
    }
}

extension Array {
    /// The array's elements repeated `count` times.
    func repeating(_ count: Int) -> [Element] {
        var result: [Element] = []
        result.reserveCapacity(self.count * count)
        for _ in 0..<count { result.append(contentsOf: self) }
        return result
    }
}
