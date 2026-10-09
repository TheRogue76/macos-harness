import AppKit
import ApplicationServices
import Foundation
import HarnessProtocol

/// Typing, scrolling and buttons for simulator targets, through Device Hub's window.
enum SimulatorInput {
    /// Key codes of a US keyboard for the characters that need no Shift.
    static let plainKeys: [Character: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
        "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25,
        "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "\n": 36, "l": 37,
        "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "\t": 48, " ": 49,
        "`": 50,
    ]

    /// Characters typed with Shift and the key they share.
    static let shiftedKeys: [Character: Character] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
        "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`",
    ]

    static let shiftKey: CGKeyCode = 56

    /// The key code for a character on the simulator's US hardware keyboard, and whether it needs Shift.
    static func key(for character: Character) -> (code: CGKeyCode, shift: Bool)? {
        if let code = plainKeys[character] { return (code, false) }
        if let base = shiftedKeys[character], let code = plainKeys[base] { return (code, true) }
        if character.isUppercase, let lower = character.lowercased().first, let code = plainKeys[lower] { return (code, true) }
        if character == "\r" { return (36, false) }
        return nil
    }

    /// The characters of `text` a US hardware keyboard can't type.
    static func untypable(_ text: String) -> [Character] {
        var seen: [Character] = []
        for character in text where key(for: character) == nil && !seen.contains(character) {
            seen.append(character)
        }
        return seen
    }

    /// Types `text` into the simulator's focused field with key events sent to Device Hub, which
    /// passes them to the simulator's hardware keyboard.
    static func type(_ text: String, pid: pid_t) async throws {
        let missing = untypable(text)
        guard missing.isEmpty else {
            throw RPCError(
                code: RPCErrorCode.invalidParams,
                message: "The simulator's keyboard can't type \(missing.map { "“\($0)”" }.joined(separator: ", ")); use set-value on the field instead."
            )
        }
        let source = CGEventSource(stateID: .privateState)
        for character in text {
            guard let (code, shift) = key(for: character) else { continue }
            if shift { post(shiftKey, down: true, flags: .maskShift, source: source, pid: pid) }
            post(code, down: true, flags: shift ? .maskShift : [], source: source, pid: pid)
            post(code, down: false, flags: shift ? .maskShift : [], source: source, pid: pid)
            if shift { post(shiftKey, down: false, flags: [], source: source, pid: pid) }
            try await Task.sleep(for: .milliseconds(12))
        }
    }

    static func post(_ code: CGKeyCode, down: Bool, flags: CGEventFlags, source: CGEventSource?, pid: pid_t) {
        let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
        event?.flags = flags
        event?.postToPid(pid)
    }

    /// Labels of the software keyboard's Return key, which apps rename.
    static let returnLabels: Set<String> = [
        "return", "search", "go", "done", "send", "next", "join", "route", "continue", "emergency call", "enter",
    ]

    /// The software keyboard's key for a combination (return, delete, space), when the keyboard shows.
    static func softwareKey(for combo: KeyCombo, in window: WindowService.Window) -> AXUIElement? {
        let buttons = AX.children(window.content).filter { AX.role($0) == "AXButton" }
        guard let letter = buttons.first(where: { ["q", "Q"].contains(AX.label($0) ?? "") }), let top = AX.frame(letter)?.minY else {
            return nil
        }
        let keys = buttons.filter { (AX.frame($0)?.minY ?? 0) >= top - 1 }
        let wanted: Set<String>
        switch combo.keyCode {
        case 36, 76: wanted = returnLabels
        case 51: wanted = ["delete"]
        case 49: wanted = ["space"]
        default: return nil
        }
        return keys.first { wanted.contains((AX.label($0) ?? "").lowercased()) }
    }

    /// A direction to scroll content in: `down` brings what's below into view.
    enum Direction: String {
        case up, down, left, right

        var action: String {
            switch self {
            case .up: "AXScrollUpByPage"
            case .down: "AXScrollDownByPage"
            case .left: "AXScrollLeftByPage"
            case .right: "AXScrollRightByPage"
            }
        }
    }

    /// The element, or the nearest element around it inside the screen, that can scroll a page
    /// in the direction.
    static func scroller(from element: AXUIElement, direction: Direction, screen: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = element
        while let node = current, !CFEqual(node, screen) {
            if AX.actions(node).contains(direction.action) { return node }
            current = AX.element(node, "AXParent")
        }
        return nil
    }

    /// The largest element on the screen that can scroll a page in the direction.
    static func mainScroller(in screen: AXUIElement, direction: Direction) -> AXUIElement? {
        var best: (element: AXUIElement, area: CGFloat)?
        SimulatorScreens.visit(screen, maxDepth: 6) { element in
            if AX.actions(element).contains(direction.action), let frame = AX.frame(element) {
                let area = frame.width * frame.height
                if area > (best?.area ?? 0) { best = (element, area) }
                return .skip
            }
            return .descend
        }
        return best?.element
    }

    /// Whether a visible frame's center is clear of the bars at the screen's top and bottom.
    static func inReach(_ visible: CGRect?, window: WindowService.Window) -> Bool {
        guard let visible else { return false }
        let screen = window.space.frame
        return visible.midY >= screen.minY + screen.height * 0.08 && visible.midY <= screen.maxY - screen.height * 0.06
    }

    /// Scrolls one page at a time until the element is on the simulator's screen. Returns whether
    /// it got there.
    static func scrollIntoView(_ element: AXUIElement, window: WindowService.Window) async -> Bool {
        let screen = window.space.frame
        let band = screen.insetBy(dx: 0, dy: 0).divided(atDistance: screen.height * 0.14, from: .minYEdge).remainder
            .divided(atDistance: screen.height * 0.12, from: .maxYEdge).remainder
        for _ in 0..<12 {
            guard let frame = AX.frame(element) else { return false }
            let direction: Direction
            if frame.midY > band.maxY {
                direction = .down
            } else if frame.midY < band.minY {
                direction = .up
            } else if frame.midX > screen.maxX {
                direction = .right
            } else if frame.midX < screen.minX {
                direction = .left
            } else {
                return true
            }
            guard let scroller = scroller(from: element, direction: direction, screen: window.content),
                  AX.perform(scroller, direction.action) == .success else { return false }
            try? await Task.sleep(for: .milliseconds(700))
        }
        return false
    }

    /// Scrolls the element (or the nearest container that can, or else the screen's main
    /// scrolling view) by whole pages. Returns how many pages moved.
    static func scrollPages(from element: AXUIElement?, direction: Direction, pages: Int, window: WindowService.Window) async -> Int {
        let found = element.flatMap { Self.scroller(from: $0, direction: direction, screen: window.content) }
            ?? Self.mainScroller(in: window.content, direction: direction)
        guard let scroller = found else { return 0 }
        var moved = 0
        for index in 0..<max(1, pages) {
            guard AX.actions(scroller).contains(direction.action), AX.perform(scroller, direction.action) == .success else { break }
            moved += 1
            if index < pages - 1 { try? await Task.sleep(for: .milliseconds(500)) }
        }
        return moved
    }

    /// Presses a hardware button or device control through Device Hub.
    static func press(_ button: SimulatorButton, window: WindowService.Window, hub: AppRef) async throws -> String {
        switch button {
        case .home:
            guard let home = control(identifier: "app.grid.3x3", in: window.element) else {
                return try await menu(["Controls", "Home"], window: window, hub: hub)
            }
            let before = screenSignature(window)
            try check(AX.perform(home, "AXPress"), "press Home")
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline {
                try await Task.sleep(for: .milliseconds(300))
                if screenSignature(window) != before { return "pressed Home" }
            }
            if before.contains(where: { $0.hasPrefix("AXButton|Safari") || $0.hasPrefix("AXButton|Settings") }) {
                return "pressed Home"
            }
            return try await menu(["Controls", "Home"], window: window, hub: hub)
        case .rotateLeft, .rotateRight:
            guard let rotate = SimulatorScreens.button(named: "Rotate Left", in: window.element) else {
                throw RPCError(code: RPCErrorCode.failed, message: "Device Hub's window has no Rotate button.")
            }
            for index in 0..<(button == .rotateLeft ? 1 : 3) {
                try check(AX.perform(rotate, "AXPress"), "rotate")
                if index < 2, button == .rotateRight { try await Task.sleep(for: .milliseconds(600)) }
            }
            return button == .rotateLeft ? "rotated left" : "rotated right"
        case .lock: return try await menu(["Controls", "Lock"], window: window, hub: hub)
        case .siri: return try await menu(["Controls", "Siri"], window: window, hub: hub)
        case .appSwitcher: return try await menu(["Controls", "App Switcher"], window: window, hub: hub)
        case .action: return try await menu(["Controls", "Action Button"], window: window, hub: hub)
        }
    }

    /// Chooses a Device Hub menu item for the window's simulator. Menu items act on the key
    /// window, so this brings Device Hub forward with that window in front.
    static func menu(_ path: [String], window: WindowService.Window, hub: AppRef) async throws -> String {
        _ = AX.set(window.element, "AXMain", kCFBooleanTrue)
        _ = AX.perform(window.element, "AXRaise")
        let result = try await AppControl.menuSelect(.init(app: "\(hub.pid)", path: path, activate: true, diff: false))
        return "chose \(path.joined(separator: " › ")) (\(result.via))"
    }

    /// The roles and labels on the simulator's screen, to tell whether it changed.
    static func screenSignature(_ window: WindowService.Window) -> [String] {
        AX.children(window.content).prefix(40).map { "\(AX.role($0))|\(AX.label($0) ?? "")" }
    }

    static func control(identifier: String, in window: AXUIElement) -> AXUIElement? {
        var found: AXUIElement?
        SimulatorScreens.visit(window, maxDepth: 8) { element in
            if AX.string(element, "AXIdentifier") == identifier {
                found = element
                return .stop
            }
            return AX.string(element, "AXSubrole") == SimulatorScreens.screenSubrole || AX.role(element) == "AXOutline" ? .skip : .descend
        }
        return found
    }

    static func check(_ error: AXError, _ what: String) throws {
        guard error == .success || error == .cannotComplete else {
            throw RPCError(code: RPCErrorCode.failed, message: "Couldn't \(what) (AX error \(error.rawValue)).")
        }
    }
}

/// Finding elements that aren't on the simulator's screen yet. iOS lists only what's on screen,
/// so this scrolls the screen's main list a page at a time while looking.
enum SimulatorScrolling {
    /// The element the selector names, scrolling down (then back up) through the screen's main
    /// list until it appears.
    static func reveal(_ selector: ElementSelector, window: WindowService.Window, app: AppRef) async throws -> ResolvedElement {
        _ = await SimulatorScreens.waitForContent(window, timeout: 4)
        if selector.ref != nil || !ElementResolver.search(selector, window: window).isEmpty {
            return try await ElementResolver.resolve(selector, window: window, app: app, allowFocused: false)
        }
        for direction in [SimulatorInput.Direction.down, .up] {
            for _ in 0..<15 {
                guard let scroller = SimulatorInput.mainScroller(in: window.content, direction: direction),
                      AX.perform(scroller, direction.action) == .success else { break }
                let deadline = Date().addingTimeInterval(2)
                while Date() < deadline {
                    try await Task.sleep(for: .milliseconds(350))
                    if !ElementResolver.search(selector, window: window).isEmpty {
                        return try await ElementResolver.resolve(selector, window: window, app: app, allowFocused: false)
                    }
                }
            }
        }
        return try await ElementResolver.resolve(selector, window: window, app: app, allowFocused: false)
    }
}
