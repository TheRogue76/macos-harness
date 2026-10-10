import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import HarnessProtocol
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Diagnostic experiments that run inside the helper with its permissions and report plain text.
public enum Spikes {
    static let catalog = """
        permissions                 S1: the helper's own grants and who macOS holds responsible for each process
        windows <app>               S2: windows ScreenCaptureKit reports for an app
        capture <app>               S2: capture every window of an app to PNG, check for blank images
        axstats <app>               S3: size, depth, speed and labeling of an app's AX tree
        axtree <app> [lines]        S7: an app's raw AX tree of windows, one element per line
        axperform <app> <id> <act>  S7: perform an AX action on the first element with an identifier
        simfocus <app>              S7: what has keyboard focus in Device Hub, then focus the simulator's screen
        axattrs <app> <role>        S7: every attribute and value of the elements with a role
        appattrs <app>              the app element's attributes, and the children of its menu bars
        corners <app>               the measured corner radius of each of an app's windows on screen
        screen <x> <y> <w> <h> [n]  capture part of the screen, the helper's own windows included, to PNG
        """

    public static func run(_ name: String, arguments: [String], caller: CallerIdentity) async throws -> String {
        func argument(_ index: Int, _ usage: String) throws -> String {
            guard index < arguments.count else {
                throw RPCError(code: RPCErrorCode.invalidParams, message: "usage: \(usage)")
            }
            return arguments[index]
        }
        switch name {
        case "list": return catalog
        case "permissions": return permissions(caller: caller)
        case "windows": return try await windows(try argument(0, "windows <app>"))
        case "capture": return try await capture(try argument(0, "capture <app>"))
        case "axstats": return try await axStats(try argument(0, "axstats <app>"))
        case "axtree": return try await axTree(try argument(0, "axtree <app> [lines]"), maxLines: Int(arguments.dropFirst().first ?? "") ?? 800)
        case "axperform":
            return try await axPerform(
                try argument(0, "axperform <app> <id> <action>"), identifier: try argument(1, "axperform <app> <id> <action>"),
                action: try argument(2, "axperform <app> <id> <action>"))
        case "simfocus": return try await simFocus(try argument(0, "simfocus <app>"))
        case "appattrs": return try await appAttributes(try argument(0, "appattrs <app>"))
        case "axattrs": return try await axAttributes(try argument(0, "axattrs <app> <role>"), role: try argument(1, "axattrs <app> <role>"))
        case "idle-counters": return await idleCounters()
        case "corners": return try await corners(try argument(0, "corners <app>"))
        case "screen":
            let usage = "screen <x> <y> <w> <h> [name]"
            let numbers = try (0..<4).map { index -> CGFloat in
                guard let value = Double(try argument(index, usage)) else {
                    throw RPCError(code: RPCErrorCode.invalidParams, message: "usage: \(usage)")
                }
                return CGFloat(value)
            }
            return try await screen(CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3]), name: arguments.count > 4 ? arguments[4] : "screen")
        default:
            throw RPCError(code: RPCErrorCode.invalidParams, message: "unknown spike \(name); try `list`")
        }
    }

    /// Reports whether synthetic events reset the "seconds since last user input" counters.
    static func idleCounters() async -> String {
        func read() -> String {
            let kinds: [(String, CGEventType)] = [("mouseMoved", .mouseMoved), ("keyDown", .keyDown), ("leftMouseDown", .leftMouseDown)]
            return kinds.map { name, type in
                String(format: "%@ hid=%.2f combined=%.2f", name,
                       CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: type),
                       CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: type))
            }.joined(separator: "; ")
        }
        var lines = ["before: " + read()]
        let location = CGEvent(source: nil)?.location ?? .zero
        for state in [CGEventSourceStateID.privateState, .hidSystemState] {
            let source = CGEventSource(stateID: state)
            CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: location, mouseButton: .left)?
                .post(tap: .cghidEventTap)
            try? await Task.sleep(for: .milliseconds(200))
            lines.append("after synthetic move (source \(state == .privateState ? "private" : "hid")): " + read())
        }
        return lines.joined(separator: "\n")
    }

    static func permissions(caller: CallerIdentity) -> String {
        var lines = [
            "helper pid \(getpid()), parent pid \(getppid())",
            "AXIsProcessTrusted: \(AXIsProcessTrusted())",
            "CGPreflightScreenCaptureAccess: \(CGPreflightScreenCaptureAccess())",
            "CGPreflightPostEventAccess: \(CGPreflightPostEventAccess())",
            "CGPreflightListenEventAccess: \(CGPreflightListenEventAccess())",
            "responsible for helper: \(ProcessInspector.responsiblePID(of: getpid()).map(String.init) ?? "unknown")",
            "caller chain (pid name → responsible pid):",
        ]
        for process in caller.chain {
            let responsible = ProcessInspector.responsiblePID(of: process.pid).map(String.init) ?? "?"
            lines.append("  \(process.pid) \(process.name) → \(responsible)")
        }
        return lines.joined(separator: "\n")
    }

    static func app(_ query: String) async throws -> (pid: pid_t, name: String) {
        guard let app = await RunningApps.find(query) else {
            throw RPCError(code: RPCErrorCode.failed, message: "\(query) isn't running")
        }
        return app
    }

    static func shareableWindows(of pid: pid_t) async throws -> [SCWindow] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        return content.windows.filter {
            $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.frame.width > 50 && $0.frame.height > 50
        }
    }

    static func windows(_ query: String) async throws -> String {
        let target = try await app(query)
        let windows = try await shareableWindows(of: target.pid)
        var lines = ["\(target.name): \(windows.count) normal windows"]
        for window in windows {
            lines.append(
                "  id \(window.windowID) \"\(window.title ?? "")\" onScreen=\(window.isOnScreen) "
                    + "active=\(window.isActive) frame=\(describe(window.frame))"
            )
        }
        return lines.joined(separator: "\n")
    }

    static func capture(_ query: String) async throws -> String {
        let target = try await app(query)
        let windows = try await shareableWindows(of: target.pid)
        let directory = URL(fileURLWithPath: HarnessPaths.homeDirectory)
            .appendingPathComponent("Library/Application Support/macos-harness/spikes", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var lines = ["\(target.name): capturing \(windows.count) windows"]
        for window in windows.prefix(6) {
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let configuration = SCStreamConfiguration()
            let scale = CGFloat(filter.pointPixelScale)
            configuration.width = Int(filter.contentRect.width * scale)
            configuration.height = Int(filter.contentRect.height * scale)
            configuration.showsCursor = false
            configuration.ignoreShadowsSingleWindow = true
            let started = Date()
            do {
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
                let milliseconds = Int(Date().timeIntervalSince(started) * 1000)
                let url = directory.appendingPathComponent("\(target.name)-\(window.windowID).png")
                try writePNG(image, to: url)
                lines.append("  contentRect=\(describe(filter.contentRect)) scale=\(filter.pointPixelScale) windowFrame=\(describe(window.frame))")
                lines.append(
                    "  id \(window.windowID) \"\(window.title ?? "")\" onScreen=\(window.isOnScreen) "
                        + "→ \(image.width)x\(image.height) in \(milliseconds) ms, "
                        + "\(distinctColors(image)) distinct colors (≤2 means blank) → \(url.path)"
                )
            } catch {
                lines.append("  id \(window.windowID) \"\(window.title ?? "")\" failed: \(error)")
            }
        }
        return lines.joined(separator: "\n")
    }

    static func corners(_ query: String) async throws -> String {
        let target = try await app(query)
        let windows = try await shareableWindows(of: target.pid).filter(\.isOnScreen)
        var lines = ["\(target.name): \(windows.count) windows on screen"]
        for window in windows {
            let radius = await WindowCorners.measure(windowID: window.windowID)
            lines.append("  id \(window.windowID) \"\(window.title ?? "")\" \(describe(window.frame)) radius \(radius.map { String(format: "%.1f", $0) } ?? "unknown")")
        }
        return lines.joined(separator: "\n")
    }

    static func screen(_ rect: CGRect, name: String) async throws -> String {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.max(by: { $0.frame.intersection(rect).area < $1.frame.intersection(rect).area }),
              display.frame.intersects(rect) else {
            throw RPCError(code: RPCErrorCode.failed, message: "\(describe(rect)) isn't on a display")
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let scale = CGFloat(filter.pointPixelScale)
        let visible = rect.intersection(display.frame)
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = visible.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        configuration.width = Int(visible.width * scale)
        configuration.height = Int(visible.height * scale)
        configuration.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        let directory = URL(fileURLWithPath: HarnessPaths.homeDirectory)
            .appendingPathComponent("Library/Application Support/macos-harness/spikes", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(name).png")
        try writePNG(image, to: url)
        return "captured \(describe(visible)) at \(scale)x → \(url.path)"
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw RPCError(code: RPCErrorCode.failed, message: "can't write \(url.path)")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw RPCError(code: RPCErrorCode.failed, message: "can't write \(url.path)")
        }
    }

    /// The number of distinct colors in a 16×16 downsample of the image.
    static func distinctColors(_ image: CGImage) -> Int {
        let side = 16
        var pixels = [UInt32](repeating: 0, count: side * side)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        return drawn ? Set(pixels).count : 0
    }

    struct TreeStats {
        var nodes = 0
        var maxDepth = 0
        var withIdentifier = 0
        var interactive = 0
        var unlabeledInteractive: [String] = []
        var roles: [String: Int] = [:]
    }

    static func walk(
        _ element: AXUIElement, depth: Int, maxDepth: Int, stats: inout TreeStats,
        lines: inout [String], maxLines: Int
    ) {
        stats.nodes += 1
        stats.maxDepth = max(stats.maxDepth, depth)
        let role = AX.role(element)
        stats.roles[role, default: 0] += 1
        let identifier = AX.string(element, "AXIdentifier")
        let label = AX.label(element)
        if identifier != nil { stats.withIdentifier += 1 }
        if AX.interactiveRoles.contains(role) {
            stats.interactive += 1
            if label == nil && identifier == nil && stats.unlabeledInteractive.count < 10 {
                stats.unlabeledInteractive.append("\(role) at \(AX.frame(element).map(describe) ?? "?")")
            }
        }
        if lines.count < maxLines {
            var line = String(repeating: "  ", count: depth) + role
            if let subrole = AX.string(element, "AXSubrole") { line += "/\(subrole)" }
            if let label { line += " \"\(label.prefix(60))\"" }
            if let value = AX.value(element) { line += " value=\"\(value.prefix(40))\"" }
            if let identifier { line += " id=\(identifier)" }
            if let frame = AX.frame(element) { line += " \(describe(frame))" }
            let actions = AX.actions(element).filter { $0 != "AXShowMenu" && $0 != "AXScrollToVisible" }
            if !actions.isEmpty { line += " [\(actions.joined(separator: ","))]" }
            lines.append(line)
        }
        guard depth < maxDepth else { return }
        for child in AX.children(element) {
            walk(child, depth: depth + 1, maxDepth: maxDepth, stats: &stats, lines: &lines, maxLines: maxLines)
        }
    }

    static func axStats(_ query: String) async throws -> String {
        let target = try await app(query)
        try requireAccessibility()
        let root = AX.application(target.pid)
        AX.setTimeout(root, seconds: 2)

        var report = ["\(target.name) (pid \(target.pid))"]
        for (label, roots) in [("windows", AX.elements(root, "AXWindows")), ("menu bar", AX.element(root, "AXMenuBar").map { [$0] } ?? [])] {
            var stats = TreeStats()
            var lines: [String] = []
            let started = Date()
            for element in roots {
                walk(element, depth: 0, maxDepth: 60, stats: &stats, lines: &lines, maxLines: 0)
            }
            let milliseconds = Int(Date().timeIntervalSince(started) * 1000)
            let topRoles = stats.roles.sorted { $0.value > $1.value }.prefix(6).map { "\($0.key)×\($0.value)" }
            report.append(
                "  \(label): \(roots.count) roots, \(stats.nodes) nodes, depth \(stats.maxDepth), \(milliseconds) ms, "
                    + "\(stats.interactive) interactive (\(stats.unlabeledInteractive.count) unlabeled), "
                    + "\(stats.withIdentifier) with identifiers"
            )
            report.append("    roles: \(topRoles.joined(separator: ", "))")
            if !stats.unlabeledInteractive.isEmpty {
                report.append("    unlabeled: \(stats.unlabeledInteractive.joined(separator: "; "))")
            }
        }
        return report.joined(separator: "\n")
    }

    static func axTree(_ query: String, maxLines: Int) async throws -> String {
        let target = try await app(query)
        try requireAccessibility()
        let root = AX.application(target.pid)
        AX.setTimeout(root, seconds: 2)
        var stats = TreeStats()
        var lines = ["\(target.name) (pid \(target.pid))"]
        for window in AX.elements(root, "AXWindows") {
            walk(window, depth: 0, maxDepth: 60, stats: &stats, lines: &lines, maxLines: maxLines)
        }
        return lines.joined(separator: "\n")
    }

    static func axPerform(_ query: String, identifier: String, action: String) async throws -> String {
        let target = try await app(query)
        try requireAccessibility()
        func first(_ element: AXUIElement) -> AXUIElement? {
            if AX.string(element, "AXIdentifier") == identifier { return element }
            for child in AX.children(element) {
                if let found = first(child) { return found }
            }
            return nil
        }
        let root = AX.application(target.pid)
        guard let element = AX.elements(root, "AXWindows").lazy.compactMap(first).first else {
            return "no element with id \(identifier)"
        }
        let started = Date()
        let result = AX.perform(element, action)
        return "\(action) on \(identifier): AXError \(result.rawValue) in \(Int(Date().timeIntervalSince(started) * 1000)) ms"
    }

    static func simFocus(_ query: String) async throws -> String {
        let target = try await app(query)
        try requireAccessibility()
        let root = AX.application(target.pid)
        func describeFocus() -> String {
            guard let focused = AX.element(root, "AXFocusedUIElement") else { return "nothing" }
            var chain: [String] = []
            var current: AXUIElement? = focused
            while let node = current, chain.count < 8 {
                chain.append("\(AX.role(node))\(AX.string(node, "AXSubrole").map { "/\($0)" } ?? "")")
                current = AX.element(node, "AXParent")
            }
            return chain.joined(separator: " < ")
        }
        var lines = ["before: \(describeFocus())"]
        for window in AX.elements(root, "AXWindows") {
            guard let group = SimulatorScreens.screenGroup(in: window) else { continue }
            var settable = DarwinBoolean(false)
            AXUIElementIsAttributeSettable(group, "AXFocused" as CFString, &settable)
            lines.append("window \(AX.string(window, "AXTitle") ?? "?"): group focus settable=\(settable.boolValue)")
            if let parent = AX.element(group, "AXParent") {
                var parentSettable = DarwinBoolean(false)
                AXUIElementIsAttributeSettable(parent, "AXFocused" as CFString, &parentSettable)
                lines.append("  parent \(AX.role(parent)) focus settable=\(parentSettable.boolValue)")
            }
            let result = AX.set(group, "AXFocused", kCFBooleanTrue)
            lines.append("  set group focused: \(result.rawValue)")
        }
        try await Task.sleep(for: .milliseconds(300))
        lines.append("after: \(describeFocus())")
        return lines.joined(separator: "\n")
    }

    static func axAttributes(_ query: String, role: String) async throws -> String {
        let target = try await app(query)
        try requireAccessibility()
        var lines: [String] = []
        func visit(_ element: AXUIElement, _ depth: Int) {
            if AX.role(element) == role, lines.count < 200 {
                var names: CFArray?
                AXUIElementCopyAttributeNames(element, &names)
                for name in (names as? [String]) ?? [] {
                    var settable = DarwinBoolean(false)
                    AXUIElementIsAttributeSettable(element, name as CFString, &settable)
                    let value = AX.attribute(element, name).map { String(describing: $0).prefix(80) } ?? "-"
                    lines.append("\(name)\(settable.boolValue ? " (settable)" : "") = \(value)")
                }
                lines.append("---")
            }
            guard depth < 30 else { return }
            AX.children(element).forEach { visit($0, depth + 1) }
        }
        AX.elements(AX.application(target.pid), "AXWindows").forEach { visit($0, 0) }
        return lines.joined(separator: "\n")
    }

    static func appAttributes(_ query: String) async throws -> String {
        let target = try await app(query)
        try requireAccessibility()
        let root = AX.application(target.pid)
        var names: CFArray?
        AXUIElementCopyAttributeNames(root, &names)
        var lines = ["\(target.name) (pid \(target.pid)): \(((names as? [String]) ?? []).joined(separator: ", "))"]
        for bar in ["AXMenuBar", "AXExtrasMenuBar"] {
            guard let element = AX.element(root, bar) else {
                lines.append("\(bar): none")
                continue
            }
            func describe(_ child: AXUIElement, _ depth: Int) {
                let actions = AX.actions(child).filter { !$0.contains("Name:") }.joined(separator: ",")
                lines.append("\(bar): \(String(repeating: "  ", count: depth))\(AX.role(child))/\(AX.string(child, "AXSubrole") ?? "-") title=\(AX.string(child, "AXTitle") ?? "-") desc=\(AX.string(child, "AXDescription") ?? "-") id=\(AX.string(child, "AXIdentifier") ?? "-") [\(actions)]")
                guard depth < 3 else { return }
                AX.children(child).prefix(10).forEach { describe($0, depth + 1) }
            }
            AX.children(element).prefix(30).forEach { describe($0, 0) }
        }
        return lines.joined(separator: "\n")
    }

    static func normalize(_ text: String?) -> String {
        (text ?? "").replacingOccurrences(of: "…", with: "...").trimmingCharacters(in: .whitespaces).lowercased()
    }

    static func requireAccessibility() throws {
        guard AXIsProcessTrusted() else {
            throw RPCError(code: RPCErrorCode.permissionMissing, message: "the helper doesn't have Accessibility permission")
        }
    }

    static func describe(_ rect: CGRect) -> String {
        "(\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))x\(Int(rect.height)))"
    }

    static func describe(_ point: CGPoint) -> String {
        "(\(Int(point.x)),\(Int(point.y)))"
    }
}
