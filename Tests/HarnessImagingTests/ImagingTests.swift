import Foundation
import Testing
@testable import HarnessImaging

struct PNGTests {
    @Test func decodesAnRGBImageThatUsesEveryRowFilter() throws {
        let data = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAMAAAAFCAIAAAAPE8H1AAAAMElEQVR42mNgEDnBZXRCJOAEo5HIAi45BiBiMmK4AUHMKVwicvxvgIgFyONiYAAiACy4Cz14JbTdAAAAAElFTkSuQmCC"))
        let image = try PNG.decode(data)
        #expect(image.width == 3 && image.height == 5)
        for y in 0..<5 {
            for x in 0..<3 {
                let expected = Bitmap.Color(red: UInt8(10 * x + 50 * y), green: UInt8(20 + 30 * x), blue: UInt8(200 - 40 * y))
                #expect(image.color(x: x, y: y) == expected, "pixel \(x),\(y)")
            }
        }
        #expect(try PNG.size(of: data) == (3, 5))
    }

    @Test func decodesAPaletteWithTransparency() throws {
        let data = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAMAAABFaP0WAAAACVBMVEX/AAAA/wAAAP8tSs2KAAAAAnRSTlP/gAgPs2oAAAAOSURBVHjaY2BgZGBiAAAADgAE2+AyjgAAAABJRU5ErkJggg=="))
        let image = try PNG.decode(data)
        #expect(image.color(x: 0, y: 0) == Bitmap.Color(red: 255, green: 0, blue: 0))
        #expect(image.color(x: 1, y: 0) == Bitmap.Color(red: 0, green: 255, blue: 0, alpha: 128))
        #expect(image.color(x: 0, y: 1) == Bitmap.Color(red: 0, green: 0, blue: 255))
    }

    @Test func roundTripsWithEveryFilter() throws {
        var pixels: [UInt8] = []
        for index in 0..<(7 * 6) { pixels += [UInt8(index * 5 % 256), UInt8(index * 11 % 256), UInt8(255 - index), UInt8(index % 2 == 0 ? 255 : 90)] }
        let image = Bitmap(width: 7, height: 6, pixels: pixels)
        for filter in PNG.Filter.allCases {
            #expect(try PNG.decode(PNG.encode(image, filters: [filter])) == image, "\(filter)")
        }
        #expect(try PNG.decode(PNG.encode(image, filters: PNG.Filter.allCases)) == image)
        #expect(try PNG.decode(PNG.encode(image)) == image)
    }

    @Test func refusesWhatIsntAPNG() {
        #expect(throws: PNG.DecodeError.notPNG) { try PNG.decode(Data("hello".utf8)) }
        var broken = [UInt8](PNG.encode(Bitmap(width: 2, height: 2, color: .white)))
        broken.removeLast(30)
        #expect(throws: PNG.DecodeError.self) { try PNG.decode(Data(broken)) }
    }
}

struct BitmapTests {
    @Test func shrinksByAveraging() {
        var image = Bitmap(width: 4, height: 2, color: Bitmap.Color(red: 0, green: 0, blue: 0))
        image.fill(x: 0, y: 0, width: 1, height: 2, color: .white)
        let half = image.resized(by: 0.5)
        #expect(half.width == 2 && half.height == 1)
        #expect(half.color(x: 0, y: 0) == Bitmap.Color(red: 128, green: 128, blue: 128))
        #expect(half.color(x: 1, y: 0) == Bitmap.Color(red: 0, green: 0, blue: 0))
        #expect(image.resized(by: 2).width == 8)
    }

    @Test func cropsAndClips() throws {
        let image = Bitmap(width: 10, height: 10, color: .white)
        let cropped = try #require(image.cropped(x: 8, y: -2, width: 5, height: 5))
        #expect(cropped.width == 2 && cropped.height == 3)
        #expect(image.cropped(x: 20, y: 0, width: 5, height: 5) == nil)
    }

    @Test func blendsByAlpha() {
        var image = Bitmap(width: 1, height: 1, color: Bitmap.Color(red: 0, green: 0, blue: 0))
        image.fill(x: 0, y: 0, width: 1, height: 1, color: Bitmap.Color(red: 255, green: 255, blue: 255, alpha: 128))
        #expect(image.color(x: 0, y: 0) == Bitmap.Color(red: 128, green: 128, blue: 128))
    }
}

struct MarkupTests {
    @Test func everyRefCharacterHasAGlyph() {
        for character in "0123456789abcdefghijklmnopqrstuvwxyz-." {
            #expect(BitmapFont.glyphs[character]?.count == BitmapFont.glyphHeight, "\(character)")
            #expect(BitmapFont.glyphs[character]?.allSatisfy { $0.count == BitmapFont.glyphWidth } == true, "\(character)")
        }
    }

    @Test func labelsOutlineTheElementAndTagItsRef() {
        var image = Bitmap(width: 200, height: 200, color: .white)
        Markup.draw(labels: [Markup.Label(x: 50, y: 60, width: 80, height: 40, ref: "a12")], on: &image, scale: 1, origin: (0, 0))
        #expect(image.color(x: 129, y: 99) == Markup.accent)
        #expect(image.color(x: 51, y: 61) == Markup.accent)
        #expect(image.color(x: 100, y: 80) == .white)
    }

    @Test func gridLinesFallEverySpacing() {
        var image = Bitmap(width: 300, height: 300, color: Bitmap.Color(red: 0, green: 0, blue: 0))
        Markup.draw(grid: 100, on: &image, scale: 1, origin: (0, 0))
        #expect(image.color(x: 100, y: 250).blue > 0)
        #expect(image.color(x: 150, y: 250) == Bitmap.Color(red: 0, green: 0, blue: 0))
    }
}
