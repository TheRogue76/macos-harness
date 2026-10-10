import ArgumentParser
import Foundation
import HarnessClient
import HarnessProtocol

/// A window-relative point, for targets without an element.
struct PointOptions: ParsableArguments {
    @Option(help: "Window-relative x in points; the device's points for sim:, pixels for android: (instead of an element).")
    var x: Double?
    @Option(help: "Window-relative y in points; the device's points for sim:, pixels for android: (instead of an element).")
    var y: Double?

    var point: Point? {
        guard let x, let y else { return nil }
        return Point(x: x, y: y)
    }
}

struct ModifierOptions: ParsableArguments {
    @Option(help: "Keys held during the action, comma-separated: cmd,shift,opt,ctrl.")
    var modifiers: String?

    var list: [String] {
        modifiers?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } ?? []
    }
}

enum PointerRunner {
    static func run(_ params: PointerMethod.Params, output: OutputOptions) throws {
        try reportingErrors(json: output.json) {
            let result = try HarnessConnection.openAnnouncingPairing().call(PointerMethod.self, params)
            output.json ? try Output.json(result) : print(Render.action(result))
        }
    }
}

struct Click: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Click with the real mouse (moves your cursor, then puts it back). Prefer `press` when the element has an AX action.",
        discussion: "Brings the app to the front, waits until you're not using the mouse or keyboard, and refuses if another app's window covers the point."
    )
    @OptionGroup var element: ElementOptions
    @OptionGroup var point: PointOptions
    @OptionGroup var target: TargetOptions
    @Flag(help: "Right-click (opens context menus; their items come back as refs).")
    var right = false
    @Option(help: "Clicks: 2 for a double-click.")
    var count = 1
    @OptionGroup var modifiers: ModifierOptions
    @OptionGroup var diff: DiffOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        let action: PointerAction = right ? .rightClick : (count >= 2 ? .doubleClick : .click)
        try PointerRunner.run(
            .init(target: target.target, action: action, element: element.selector, point: point.point,
                  modifiers: modifiers.list, diff: !diff.noDiff),
            output: output
        )
    }
}

struct Hover: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Move the real cursor over an element and stay, for tooltips and hover states."
    )
    @OptionGroup var element: ElementOptions
    @OptionGroup var point: PointOptions
    @OptionGroup var target: TargetOptions
    @Option(help: "Seconds to stay.")
    var dwell = 1.2
    @OptionGroup var diff: DiffOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        try PointerRunner.run(
            .init(target: target.target, action: .hover, element: element.selector, point: point.point, hold: dwell, diff: !diff.noDiff),
            output: output
        )
    }
}

struct LongPress: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "long-press",
        abstract: "Press and hold with the real mouse: a long press on a simulator, a held click on the Mac."
    )
    @OptionGroup var element: ElementOptions
    @OptionGroup var point: PointOptions
    @OptionGroup var target: TargetOptions
    @Option(help: "Seconds to hold.")
    var hold = 1.0
    @OptionGroup var diff: DiffOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        try PointerRunner.run(
            .init(target: target.target, action: .longPress, element: element.selector, point: point.point, hold: hold, diff: !diff.noDiff),
            output: output
        )
    }
}

struct Swipe: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Swipe with the real mouse: press, move the given distance, release. On a simulator this is a finger swipe.",
        discussion: "Directions are where the finger moves, so swiping up scrolls a list down. Without an element it starts at the center of the simulator's screen."
    )
    @OptionGroup var element: ElementOptions
    @OptionGroup var point: PointOptions
    @OptionGroup var target: TargetOptions
    @Option(help: "Points to move left.") var left: Double = 0
    @Option(help: "Points to move right.") var right: Double = 0
    @Option(help: "Points to move up.") var up: Double = 0
    @Option(help: "Points to move down.") var down: Double = 0
    @Option(help: "Seconds the move takes.") var duration = 0.3
    @OptionGroup var diff: DiffOptions
    @OptionGroup var output: OutputOptions

    func validate() throws {
        if left == 0, right == 0, up == 0, down == 0 { throw ValidationError("Say how far: --left, --right, --up or --down points.") }
    }

    func run() throws {
        try PointerRunner.run(
            .init(target: target.target, action: .swipe, element: element.selector, point: point.point,
                  dx: right - left, dy: down - up, duration: duration, diff: !diff.noDiff),
            output: output
        )
    }
}

struct Drag: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Drag with the real mouse from an element or point to another (moving files, chess pieces, sliders).",
        discussion: """
            Stops and releases the button if you move the mouse or press ⌃⌥⌘. partway. To end in another window \
            or app, name it with --to-app and --to-window; --to, --to-text and --to-x/--to-y are then in that \
            window. That window is raised behind the app the drag starts in, and the drag is refused if anything \
            covers the drop point.
            """
    )
    @OptionGroup var element: ElementOptions
    @OptionGroup var point: PointOptions
    @Option(help: "Destination ref (from the destination app with --to-app).") var to: String?
    @Option(name: .customLong("to-text"), help: "Destination: element containing this text.") var toText: String?
    @Option(name: .customLong("to-role"), help: "Destination: role.") var toRole: String?
    @Option(name: .customLong("to-id"), help: "Destination: identifier.") var toIdentifier: String?
    @Option(name: .customLong("to-x"), help: "Destination x, relative to the destination window.") var toX: Double?
    @Option(name: .customLong("to-y"), help: "Destination y, relative to the destination window.") var toY: Double?
    @Option(name: .customLong("to-app"), help: "End the drag in this app (name, bundle ID or pid); defaults to -a.") var toApp: String?
    @Option(name: .customLong("to-window"), help: "End the drag in this window ID from `windows`; defaults to the destination app's focused window.") var toWindow: UInt32?
    @Option(help: "Seconds to hold before moving (helps drag-and-drop start).") var hold = 0.3
    @Option(help: "Seconds the move takes.") var duration = 0.6
    @OptionGroup var target: TargetOptions
    @OptionGroup var modifiers: ModifierOptions
    @OptionGroup var diff: DiffOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        let destination = ElementSelector(ref: to, text: toText, role: toRole, identifier: toIdentifier)
        let destinationPoint = toX.flatMap { x in toY.map { Point(x: x, y: $0) } }
        guard !destination.isEmpty || destinationPoint != nil else {
            throw ValidationError("Give a destination: --to <ref>, --to-text/--to-role/--to-id, or --to-x and --to-y.")
        }
        try PointerRunner.run(
            .init(target: target.target, action: .drag, element: element.selector, point: point.point,
                  to: destination.isEmpty ? nil : destination, toPoint: destinationPoint,
                  toTarget: target.target.drop(app: toApp, window: toWindow), modifiers: modifiers.list,
                  hold: hold, duration: duration, diff: !diff.noDiff),
            output: output
        )
    }
}

struct Scroll: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Scroll with the real wheel over an element or point, in pixels."
    )
    @OptionGroup var element: ElementOptions
    @OptionGroup var point: PointOptions
    @Option(help: "Pixels to scroll down.") var down = 0.0
    @Option(help: "Pixels to scroll up.") var up = 0.0
    @Option(help: "Pixels to scroll left.") var left = 0.0
    @Option(help: "Pixels to scroll right.") var right = 0.0
    @OptionGroup var target: TargetOptions
    @OptionGroup var diff: DiffOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        guard down + up + left + right > 0 else { throw ValidationError("Say how far: --down, --up, --left or --right (pixels).") }
        try PointerRunner.run(
            .init(target: target.target, action: .scroll, element: element.selector, point: point.point,
                  dx: left - right, dy: up - down, diff: !diff.noDiff),
            output: output
        )
    }
}
