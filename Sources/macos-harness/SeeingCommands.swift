import ArgumentParser
import Foundation
import HarnessClient
import HarnessProtocol

struct TargetOptions: ParsableArguments {
    @Option(name: .shortAndLong, help: "App name, bundle ID or pid.")
    var app: String

    @Option(name: .shortAndLong, help: "Window ID from `windows`; defaults to the focused window.")
    var window: UInt32?

    var target: Target { Target(app: app, window: window) }
}

struct Windows: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List windows, with the IDs other commands take.")

    @Option(name: .shortAndLong, help: "Only this app (name, bundle ID or pid).")
    var app: String?

    @OptionGroup var output: OutputOptions

    func run() throws {
        try reportingErrors(json: output.json) {
            let result = try HarnessConnection.openAnnouncingPairing().call(WindowsMethod.self, .init(app: app))
            output.json ? try Output.json(result) : print(Render.windows(result))
        }
    }
}

struct Snapshot: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show a window's UI as a tree of elements with refs (e12) and click points.",
        discussion: "Refs stay valid while the element exists, and later commands accept them. Coordinates are window-relative points."
    )

    @OptionGroup var target: TargetOptions

    @Option(help: "Start from this ref, e.g. to expand a node marked \"+N more\".")
    var root: String?

    @Option(help: "Most elements to show.")
    var maxNodes = 250

    @Option(help: "Deepest level to show.")
    var maxDepth = 40

    @OptionGroup var output: OutputOptions

    func run() throws {
        try reportingErrors(json: output.json) {
            let result = try HarnessConnection.openAnnouncingPairing().call(
                SnapshotMethod.self, .init(target: target.target, root: root, maxNodes: maxNodes, maxDepth: maxDepth)
            )
            output.json ? try Output.json(result) : print(Render.snapshot(result))
        }
    }
}

struct Find: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Find elements by text, role or identifier, including ones scrolled out of view."
    )

    @Argument(help: "Text to match against label, value or identifier.")
    var text: String?

    @OptionGroup var target: TargetOptions

    @Option(help: "Role, e.g. button, textfield, AXCheckBox.")
    var role: String?

    @Option(name: .customLong("id"), help: "Exact accessibility identifier.")
    var identifier: String?

    @Flag(help: "Match the whole text instead of a substring.")
    var exact = false

    @Option(help: "Most matches to return.")
    var limit = 20

    @Flag(help: "Look for the text in the window's pixels with text recognition (for text the tree doesn't have); without text, list every line read.")
    var ocr = false

    @OptionGroup var output: OutputOptions

    func validate() throws {
        guard text != nil || role != nil || identifier != nil || ocr else {
            throw ValidationError("Give some text, --role or --id to search for.")
        }
    }

    func run() throws {
        try reportingErrors(json: output.json) {
            let result = try HarnessConnection.openAnnouncingPairing().call(
                FindMethod.self,
                .init(target: target.target, text: text, role: role, identifier: identifier, exact: exact, limit: ocr ? Swift.max(limit, 200) : limit, ocr: ocr ? true : nil)
            )
            output.json ? try Output.json(result) : print(Render.find(result))
        }
    }
}

struct Screenshot: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Capture one window as PNG. Never includes other apps' windows.",
        discussion: "Prints the file path. Window-relative point = pixel / scale (plus the crop origin when cropped)."
    )

    @OptionGroup var target: TargetOptions

    @Option(help: "Crop to this element's ref.")
    var element: String?

    @Option(help: "Longest edge in pixels; 0 keeps full resolution.")
    var maxSize = 1600

    @Flag(help: "Draw ref labels on the elements you can act on.")
    var labels = false

    @Option(help: "Draw a grid of window coordinates every this many points (for canvases without a tree).")
    var grid: Int?

    @Option(name: .shortAndLong, help: "Where to write the PNG; defaults to a temporary file.")
    var out: String?

    @OptionGroup var output: OutputOptions

    func run() throws {
        try reportingErrors(json: output.json) {
            let result = try HarnessConnection.openAnnouncingPairing().call(
                ScreenshotMethod.self,
                .init(target: target.target, element: element, maxSize: maxSize, labels: labels, grid: grid)
            )
            guard let data = Data(base64Encoded: result.pngBase64) else {
                throw HarnessClientError.protocolError("screenshot data isn't valid base64")
            }
            let url = try destination(for: result.window)
            try data.write(to: url)
            if output.json {
                var copy = result
                copy.pngBase64 = ""
                try Output.json(ScreenshotFile(path: url.path, result: copy))
                return
            }
            var lines = ["\(url.path)", "\(result.width)x\(result.height) px, scale \(result.scale) px per point, window \(result.window.id) \"\(result.window.title)\""]
            if let crop = result.crop {
                lines.append("cropped to window-relative (\(Int(crop.x)),\(Int(crop.y)) \(Int(crop.width))x\(Int(crop.height)))")
            }
            if !result.labeledRefs.isEmpty {
                lines.append("labeled \(result.labeledRefs.count) elements: \(result.labeledRefs.prefix(40).joined(separator: " "))\(result.labeledRefs.count > 40 ? " …" : "")")
            }
            lines += result.notices.filter { $0.kind != "notFrontmost" }.map { "! \($0.message)" }
            print(lines.joined(separator: "\n"))
        }
    }

    func destination(for window: WindowInfo) throws -> URL {
        if let out { return URL(fileURLWithPath: out) }
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("macos-harness", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let app = window.app.name.replacingOccurrences(of: " ", with: "-")
        return directory.appendingPathComponent("\(app)-\(window.id)-\(stamp).png")
    }
}

struct ScreenshotFile: Encodable {
    var path: String
    var result: ScreenshotMethod.Result
}

struct Menu: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show an app's menus with shortcuts and enabled state.",
        discussion: "With no path, lists the menu bar. `menu -a TextEdit File` lists the File menu."
    )

    @Argument(help: "Menu titles to descend through, e.g. File \"Open Recent\".")
    var path: [String] = []

    @Option(name: .shortAndLong, help: "App name, bundle ID or pid.")
    var app: String

    @Option(help: "Levels to show below the path.")
    var depth = 1

    @OptionGroup var output: OutputOptions

    func run() throws {
        try reportingErrors(json: output.json) {
            let result = try HarnessConnection.openAnnouncingPairing().call(
                MenuMethod.self, .init(app: app, path: path, depth: depth)
            )
            output.json ? try Output.json(result) : print(Render.menu(result, path: path))
        }
    }
}
