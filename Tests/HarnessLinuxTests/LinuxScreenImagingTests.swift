import Foundation
import HarnessCore
import HarnessImaging
import HarnessProtocol
import Testing
@testable import HarnessLinux

struct LinuxScreenImagingTests {
    private let tsv = """
        level\tpage_num\tblock_num\tpar_num\tline_num\tword_num\tleft\ttop\twidth\theight\tconf\ttext
        1\t1\t0\t0\t0\t0\t0\t0\t1080\t2400\t-1\t
        4\t1\t1\t1\t1\t0\t100\t200\t300\t40\t-1\t
        5\t1\t1\t1\t1\t1\t100\t200\t120\t40\t96\tTap
        5\t1\t1\t1\t1\t2\t240\t200\t160\t40\t95\tme
        5\t1\t2\t1\t1\t1\t500\t900\t200\t50\t91\tGREET
        """

    @Test func groupsWordsIntoLines() {
        let lines = LinuxScreenImaging.lines(fromTSV: tsv)
        #expect(lines.map(\.text) == ["Tap me", "GREET"])
    }

    @Test func matchesLikeTheMacDoes() throws {
        let lines = LinuxScreenImaging.lines(fromTSV: tsv)
        let all = lines.compactMap { LinuxScreenImaging.match(nil, exact: false, in: $0, pointsPerPixel: 0.5) }
        #expect(all.map(\.text) == ["Tap me", "GREET"])
        #expect(all[0].frame == CGRect(x: 50, y: 100, width: 150, height: 20))
        let part = try #require(LinuxScreenImaging.match("me", exact: false, in: lines[0], pointsPerPixel: 1))
        #expect(part.text == "me" && part.line == "Tap me")
        #expect(part.frame == CGRect(x: 240, y: 200, width: 160, height: 40))
        #expect(LinuxScreenImaging.match("tap me", exact: true, in: lines[0], pointsPerPixel: 1)?.text == "Tap me")
        #expect(LinuxScreenImaging.match("tap", exact: true, in: lines[0], pointsPerPixel: 1) == nil)
        #expect(LinuxScreenImaging.match("nothing", exact: false, in: lines[0], pointsPerPixel: 1) == nil)
    }

    @Test func rendersResizedCroppedAndLabeled() throws {
        let png = PNG.encode(Bitmap(width: 400, height: 800, color: .white))
        let imaging = LinuxScreenImaging(path: "/nonexistent")
        let whole = try imaging.render(png, request: ScreenRender(maxSize: 400, screenSize: CGSize(width: 400, height: 800)))
        #expect(whole.width == 200 && whole.height == 400)
        #expect(whole.scale == 0.5)
        let node = UINode(ref: "a7", role: "AXButton", frame: Rect(x: 10, y: 10, width: 100, height: 40))
        let cropped = try imaging.render(png, request: ScreenRender(
            maxSize: 0, screenSize: CGSize(width: 400, height: 800), crop: CGRect(x: 100, y: 200, width: 50, height: 60),
            grid: 50, labels: [node]
        ))
        #expect(cropped.width == 50 && cropped.height == 60)
        #expect(cropped.crop == Rect(x: 100, y: 200, width: 50, height: 60))
        #expect(throws: ScreenImagingError.self) { try imaging.render(Data("nope".utf8), request: ScreenRender(maxSize: 0, screenSize: .zero)) }
    }

    @Test func saysHowToInstallTesseract() async {
        let imaging = LinuxScreenImaging(path: "/nonexistent")
        await #expect(throws: RPCError.self) {
            try await imaging.findText("x", exact: false, inPNG: PNG.encode(Bitmap(width: 1, height: 1)), size: CGSize(width: 1, height: 1))
        }
    }
}
