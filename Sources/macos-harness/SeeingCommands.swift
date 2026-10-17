import ArgumentParser
import Foundation
import HarnessClient
import HarnessProtocol

struct TargetOptions: ParsableArguments {
    @Option(name: .shortAndLong, help: "App name, bundle ID or pid; sim:<device> for an iOS Simulator; android:<device> for an Android emulator or phone.")
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
        discussion: "Refs stay valid while the element exists, and later commands accept them. Coordinates are window-relative points. --since last shows only what changed since your previous snapshot of the window (with the same --root and limits); --query keeps only matching elements and the elements they're in."
    )

    @OptionGroup var target: TargetOptions

    @Option(help: "Start from this ref, e.g. to expand a node marked \"+N more\".")
    var root: String?

    @Option(help: "Most elements to show.")
    var maxNodes = 250

    @Option(help: "Deepest level to show.")
    var maxDepth = 40

    @Option(help: "last: show only what changed since your previous snapshot of this window.")
    var since: String?

    @Option(help: "Show only elements whose label, value or identifier contains this, and the elements they're in.")
    var query: String?

    @Flag(help: "Show where each link goes (a web page's own address is always shown).")
    var links = false

    @OptionGroup var output: OutputOptions

    func validate() throws {
        if let since, since != "last" { throw ValidationError("--since takes `last`.") }
    }

    func run() throws {
        try reportingErrors(json: output.json) {
            let result = try HarnessConnection.openAnnouncingPairing().call(
                SnapshotMethod.self,
                .init(target: target.target, root: root, maxNodes: maxNodes, maxDepth: maxDepth, since: since, query: query, links: links ? true : nil)
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

    @Flag(help: "Show where each matching link goes.")
    var links = false

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
                .init(
                    target: target.target, text: text, role: role, identifier: identifier, exact: exact,
                    limit: ocr ? Swift.max(limit, 200) : limit, ocr: ocr ? true : nil, links: links ? true : nil
                )
            )
            output.json ? try Output.json(result) : print(Render.find(result))
        }
    }
}

struct Collect: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Gather every item of a long list, scrolling it, and print each item once with its text and links.",
        discussion: "For lists that show only part of themselves at a time: web timelines and feeds, long tables, iOS and Android lists. Name the items with --role (article for a web page's posts, row, cell), --text or --id. It scrolls by bringing the last item into view, or a background scroll, never the real mouse, and stops at --max, --until, the end of the list, or after --max-seconds; --continue then carries on without repeating items."
    )

    @OptionGroup var target: TargetOptions

    @Option(help: "Role of the items, e.g. article, row, cell.")
    var role: String?

    @Option(help: "The items' label, value or identifier contains this text.")
    var text: String?

    @Option(name: .customLong("id"), help: "The items' exact accessibility identifier.")
    var identifier: String?

    @Flag(help: "--text must match the whole label, value or identifier.")
    var exact = false

    @Option(help: "Ref of the list or scroll area to read and scroll (default: the window).")
    var within: String?

    @Option(help: "Tell items apart by their first link whose URL contains this (e.g. /status/) instead of by their text.")
    var key: String?

    @Option(help: "Most items to return (at most 500).")
    var max = 50

    @Option(help: "Stop after the first item whose text contains this.")
    var until: String?

    @Option(help: "Longest time to keep scrolling, in seconds.")
    var maxSeconds: Double = 45

    @Flag(name: .customLong("continue"), help: "Leave out items this session already got from this list.")
    var continuing = false

    @OptionGroup var output: OutputOptions

    func validate() throws {
        guard role != nil || text != nil || identifier != nil else {
            throw ValidationError("Say which elements are the items: --role (article, row, cell…), --text or --id.")
        }
    }

    func run() throws {
        try reportingErrors(json: output.json) {
            let result = try HarnessConnection.openAnnouncingPairing().call(
                CollectMethod.self,
                .init(
                    target: target.target, item: ElementSelector(text: text, role: role, identifier: identifier, exact: exact),
                    within: within, key: key, max: max, until: until, maxSeconds: maxSeconds, continue: continuing ? true : nil
                )
            )
            output.json ? try Output.json(result) : print(Render.collect(result))
        }
    }
}

struct Read: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Read an element in full: its whole label and value, the text inside it, and its links.",
        discussion: "Snapshots and find shorten long labels and values; read gives them whole, with all the text inside the element in reading order (a post's author, text and counts, say) and where each link inside it goes. Without an element it reads the whole window."
    )

    @Argument(help: "Ref from snapshot or find, e.g. k12.")
    var ref: String?

    @OptionGroup var target: TargetOptions

    @Option(help: "Match label, value or identifier containing this text.")
    var text: String?

    @Option(help: "Role, e.g. group, link, textarea.")
    var role: String?

    @Option(name: .customLong("id"), help: "Exact accessibility identifier.")
    var identifier: String?

    @Flag(help: "--text must match the whole label, value or identifier.")
    var exact = false

    @OptionGroup var output: OutputOptions

    func run() throws {
        try reportingErrors(json: output.json) {
            let selector = ElementSelector(ref: ref, text: text, role: role, identifier: identifier, exact: exact)
            let result = try HarnessConnection.openAnnouncingPairing().call(
                ReadMethod.self, .init(target: target.target, element: selector.isEmpty ? nil : selector)
            )
            output.json ? try Output.json(result) : print(Render.read(result))
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

    @Option(name: .shortAndLong, help: "Where to write the PNG; defaults to a temporary file, deleted after an hour.")
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
            let unit = result.window.android != nil ? "screen pixel" : result.window.simulator != nil ? "simulator point" : "point"
            var lines = ["\(url.path)", "\(result.width)x\(result.height) px, scale \(result.scale) px per \(unit), window \(result.window.id) \"\(result.window.title)\""]
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
        let directory = TemporaryScreenshots.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        TemporaryScreenshots.prune(directory)
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
        abstract: "Show an app's menus with shortcuts and enabled state, or its menu bar extras.",
        discussion: """
            With no path, lists the menu bar. `menu -a TextEdit File` lists the File menu.
            With --extras, lists the app's menu bar extras (status items on the right of the menu bar), \
            e.g. `menu --extras -a "Control Center"` for most of the system's own (others belong to SystemUIServer). \
            `menu --extras -a App Extra` presses that extra, lists the menu it shows and closes it again.
            """
    )

    @Argument(help: "Menu titles to descend through, e.g. File \"Open Recent\"; with --extras, an extra's name first (optional when the app has one).")
    var path: [String] = []

    @Option(name: .shortAndLong, help: "App name, bundle ID or pid.")
    var app: String

    @Option(help: "Levels to show below the path.")
    var depth = 1

    @Flag(help: "Read the app's menu bar extras (status items) instead of its menu bar.")
    var extras = false

    @OptionGroup var output: OutputOptions

    func run() throws {
        try reportingErrors(json: output.json) {
            let result = try HarnessConnection.openAnnouncingPairing().call(
                MenuMethod.self, .init(app: app, path: path, depth: depth, extras: extras ? true : nil)
            )
            output.json ? try Output.json(result) : print(Render.menu(result, path: path, extras: extras))
        }
    }
}
