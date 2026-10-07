import ArgumentParser
import Foundation
import HarnessClient
import HarnessProtocol

/// Which element to act on: a ref from `snapshot`/`find`, or what it says and is.
struct ElementOptions: ParsableArguments {
    @Argument(help: "Ref from snapshot or find, e.g. k12.")
    var ref: String?

    @Option(help: "Match label, value or identifier containing this text.")
    var text: String?

    @Option(help: "Role, e.g. button, textfield, switch, tab.")
    var role: String?

    @Option(name: .customLong("id"), help: "Exact accessibility identifier.")
    var identifier: String?

    @Flag(help: "--text must match the whole label, value or identifier.")
    var exact = false

    @Flag(help: "Find --text in the window's pixels with text recognition (for the pointer commands).")
    var ocr = false

    var selector: ElementSelector? {
        let selector = ElementSelector(ref: ref, text: text, role: role, identifier: identifier, exact: exact, ocr: ocr ? true : nil)
        return selector.isEmpty ? nil : selector
    }
}

struct DiffOptions: ParsableArguments {
    @Flag(name: .customLong("no-diff"), help: "Don't wait for the UI to settle or report changes.")
    var noDiff = false
}

/// Shared runner for the element actions.
struct ElementActionRunner {
    static func run(
        _ action: ElementAction, target: TargetOptions, element: ElementSelector?, value: String? = nil,
        count: Int = 1, real: Bool = false, diff: DiffOptions, output: OutputOptions
    ) throws {
        try reportingErrors(json: output.json) {
            let result = try HarnessConnection.openAnnouncingPairing().call(
                ActMethod.self,
                .init(target: target.target, element: element, action: action, value: value, count: count, diff: !diff.noDiff, real: real)
            )
            output.json ? try Output.json(result) : print(Render.action(result))
        }
    }
}

struct Press: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Press a button, checkbox, tab, menu button or any element with a press action (through AX; your cursor stays put)."
    )
    @OptionGroup var element: ElementOptions
    @OptionGroup var target: TargetOptions
    @OptionGroup var diff: DiffOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        try ElementActionRunner.run(.press, target: target, element: element.selector, diff: diff, output: output)
    }
}

struct SetValue: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set-value",
        abstract: "Set a text field, slider, checkbox or other value directly."
    )
    @OptionGroup var element: ElementOptions
    @Option(name: .shortAndLong, help: "The new value.")
    var value: String
    @OptionGroup var target: TargetOptions
    @OptionGroup var diff: DiffOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        try ElementActionRunner.run(.setValue, target: target, element: element.selector, value: value, diff: diff, output: output)
    }
}

struct Focus: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Give an element keyboard focus.")
    @OptionGroup var element: ElementOptions
    @OptionGroup var target: TargetOptions
    @OptionGroup var diff: DiffOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        try ElementActionRunner.run(.focus, target: target, element: element.selector, diff: diff, output: output)
    }
}

struct Select: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Select a row, tab or item.")
    @OptionGroup var element: ElementOptions
    @OptionGroup var target: TargetOptions
    @OptionGroup var diff: DiffOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        try ElementActionRunner.run(.select, target: target, element: element.selector, diff: diff, output: output)
    }
}

struct ScrollTo: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "scroll-to", abstract: "Scroll an element into view.")
    @OptionGroup var element: ElementOptions
    @OptionGroup var target: TargetOptions
    @OptionGroup var diff: DiffOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        try ElementActionRunner.run(.scrollTo, target: target, element: element.selector, diff: diff, output: output)
    }
}

struct Increment: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Step a slider or stepper up.")
    @OptionGroup var element: ElementOptions
    @Option(help: "How many steps.")
    var count = 1
    @OptionGroup var target: TargetOptions
    @OptionGroup var diff: DiffOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        try ElementActionRunner.run(.increment, target: target, element: element.selector, count: count, diff: diff, output: output)
    }
}

struct Decrement: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Step a slider or stepper down.")
    @OptionGroup var element: ElementOptions
    @Option(help: "How many steps.")
    var count = 1
    @OptionGroup var target: TargetOptions
    @OptionGroup var diff: DiffOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        try ElementActionRunner.run(.decrement, target: target, element: element.selector, count: count, diff: diff, output: output)
    }
}

struct TypeText: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "type",
        abstract: "Type text at the cursor of the focused element (or --into a ref), without moving your cursor."
    )
    @Argument(help: "The text to type.")
    var text: String
    @Option(help: "Ref of the element to type into; defaults to the app's focused element.")
    var into: String?
    @Flag(help: "Send real keystrokes to the frontmost app (for apps that ignore the other ways).")
    var real = false
    @OptionGroup var target: TargetOptions
    @OptionGroup var diff: DiffOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        try ElementActionRunner.run(
            .type, target: target, element: into.map { ElementSelector(ref: $0) }, value: text, real: real, diff: diff, output: output
        )
    }
}

struct Key: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Send a key or shortcut to an app, e.g. return, esc, cmd+s, ⇧⌘N (US key positions)."
    )
    @Argument(help: "The key combination.")
    var combo: String
    @Flag(help: "Send a real keystroke to the frontmost app (reaches shortcuts background keys miss).")
    var real = false
    @OptionGroup var target: TargetOptions
    @OptionGroup var diff: DiffOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        try ElementActionRunner.run(.key, target: target, element: nil, value: combo, real: real, diff: diff, output: output)
    }
}

struct MenuSelect: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "menu-select",
        abstract: "Choose a menu item by path, e.g. menu-select -a TextEdit Format Font Bold.",
        discussion: "Brings the app to the front first (most menu items act on its key window); your cursor doesn't move."
    )
    @Argument(help: "Menu titles down to the item.")
    var path: [String]
    @Option(name: .shortAndLong, help: "App name, bundle ID or pid.")
    var app: String
    @Flag(name: .customLong("no-activate"), help: "Don't bring the app to the front first.")
    var noActivate = false
    @OptionGroup var diff: DiffOptions
    @OptionGroup var output: OutputOptions

    func run() throws {
        try reportingErrors(json: output.json) {
            let result = try HarnessConnection.openAnnouncingPairing().call(
                MenuSelectMethod.self, .init(app: app, path: path, activate: !noActivate, diff: !diff.noDiff)
            )
            output.json ? try Output.json(result) : print(Render.action(result))
        }
    }
}

struct WindowCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "window",
        abstract: "Activate, move, resize, minimize, restore, full-screen or close a window."
    )
    @Argument(help: "One of: \(WindowActionMethod.Action.allCases.map(\.rawValue).joined(separator: ", ")).")
    var action: String
    @OptionGroup var target: TargetOptions
    @Option(help: "Left edge for move, in global points.") var x: Double?
    @Option(help: "Top edge for move, in global points.") var y: Double?
    @Option(help: "Width for resize, in points.") var width: Double?
    @Option(help: "Height for resize, in points.") var height: Double?
    @OptionGroup var output: OutputOptions

    func run() throws {
        guard let kind = WindowActionMethod.Action(rawValue: action) else {
            throw ValidationError("Unknown window action \(action).")
        }
        try reportingErrors(json: output.json) {
            let result = try HarnessConnection.openAnnouncingPairing().call(
                WindowActionMethod.self,
                .init(target: target.target, action: kind, x: x, y: y, width: width, height: height)
            )
            output.json ? try Output.json(result) : print(Render.action(result))
        }
    }
}

struct Launch: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Launch an app (in the background unless --activate) and wait for its first window."
    )
    @Argument(help: "App name, bundle ID or path to an .app.")
    var app: String
    @Option(name: .customLong("open"), help: "A file to open with it (repeatable).")
    var files: [String] = []
    @Option(name: .customLong("arg"), help: "A launch argument (repeatable); write values starting with - as --arg=--flag.")
    var arguments: [String] = []
    @Option(name: .customLong("env"), help: "KEY=VALUE environment variable (repeatable).")
    var environment: [String] = []
    @Flag(help: "Bring it to the front.")
    var activate = false
    @Flag(help: "Start another copy even if it's running (for a browser with its own profile); target it by its pid.")
    var newInstance = false
    @Option(help: "Seconds to wait for a window.")
    var timeout = 15.0
    @OptionGroup var output: OutputOptions

    func run() throws {
        var env: [String: String] = [:]
        for pair in environment {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { throw ValidationError("--env takes KEY=VALUE, got \(pair).") }
            env[parts[0]] = parts[1]
        }
        let paths = files.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).path }
        try reportingErrors(json: output.json) {
            let result = try HarnessConnection.openAnnouncingPairing().call(
                LaunchMethod.self,
.init(app: app, arguments: arguments, environment: env, open: paths, activate: activate, timeout: timeout, newInstance: newInstance ? true : nil)
            )
            output.json ? try Output.json(result) : print(Render.launch(result))
        }
    }
}

struct Quit: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Quit an app (asks it nicely unless --force).")
    @Argument(help: "App name, bundle ID or pid.")
    var app: String
    @Flag(help: "Kill it; unsaved work is lost.")
    var force = false
    @Option(help: "Seconds to wait for it to quit.")
    var timeout = 5.0
    @OptionGroup var output: OutputOptions

    func run() throws {
        try reportingErrors(json: output.json) {
            let result = try HarnessConnection.openAnnouncingPairing().call(
                QuitMethod.self, .init(app: app, force: force, timeout: timeout)
            )
            output.json ? try Output.json(result) : print(result.message)
            if !result.quit { throw ExitCode.failure }
        }
    }
}

struct Wait: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Wait until an element appears (or with --gone, disappears).")
    @OptionGroup var element: ElementOptions
    @OptionGroup var target: TargetOptions
    @Flag(help: "Wait for it to disappear.")
    var gone = false
    @Option(help: "Seconds before giving up.")
    var timeout = 10.0
    @OptionGroup var output: OutputOptions

    func run() throws {
        guard let selector = element.selector else {
            throw ValidationError("Say what to wait for: a ref, --text, --role or --id.")
        }
        try reportingErrors(json: output.json) {
            let result = try HarnessConnection.openAnnouncingPairing().call(
                WaitMethod.self, .init(target: target.target, element: selector, gone: gone, timeout: timeout)
            )
            output.json ? try Output.json(result) : print(Render.wait(result, gone: gone))
            if !result.satisfied { throw ExitCode.failure }
        }
    }
}
