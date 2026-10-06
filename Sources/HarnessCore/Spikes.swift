import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import HarnessProtocol
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// M0 experiments. They run inside the helper so they use its permissions, and report
/// plain text that gets written up in knowledge/research/. Promote what survives into
/// real services in M1; delete the rest.
public enum Spikes {
    static let catalog = """
        permissions                 S1: the helper's own grants and who macOS holds responsible for each process
        windows <app>               S2: windows ScreenCaptureKit reports for an app
        capture <app>               S2: capture every window of an app to PNG, check for blank images
        axstats <app>               S3: size, depth, speed and labeling of an app's AX tree
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
        case "idle-counters": return await idleCounters()
        default:
            throw RPCError(code: RPCErrorCode.invalidParams, message: "unknown spike \(name); try `list`")
        }
    }

    // MARK: - M3 idle counters

    /// Do our own synthetic events reset the "seconds since last user input" counters?
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

    // MARK: - S1 permissions

    static func permissions(caller: CallerIdentity) -> String {
        var lines = [
            "helper pid \(getpid()), parent pid \(getppid())",
            "AXIsProcessTrusted: \(AXIsProcessTrusted())",
            "CGPreflightScreenCaptureAccess: \(CGPreflightScreenCaptureAccess())",
            "CGPreflightPostEventAccess: \(CGPreflightPostEventAccess())",
            "CGPreflightListenEventAccess: \(CGPreflightListenEventAccess())",
            "responsible for helper: \(responsiblePID(getpid()).map(String.init) ?? "unknown")",
            "caller chain (pid name → responsible pid):",
        ]
        for process in caller.chain {
            let responsible = responsiblePID(process.pid).map(String.init) ?? "?"
            lines.append("  \(process.pid) \(process.name) → \(responsible)")
        }
        return lines.joined(separator: "\n")
    }

    /// Private libsystem call, looked up at run time; spike use only.
    static func responsiblePID(_ pid: pid_t) -> pid_t? {
        typealias Function = @convention(c) (pid_t) -> pid_t
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else {
            return nil
        }
        return unsafeBitCast(symbol, to: Function.self)(pid)
    }

    // MARK: - S2 capture

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

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw RPCError(code: RPCErrorCode.failed, message: "can't write \(url.path)")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw RPCError(code: RPCErrorCode.failed, message: "can't write \(url.path)")
        }
    }

    /// Downsamples to 16x16 and counts distinct colors; a blank or solid capture has 1–2.
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

    // MARK: - S3 AX trees

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





    static func normalize(_ text: String?) -> String {
        (text ?? "").replacingOccurrences(of: "…", with: "...").trimmingCharacters(in: .whitespaces).lowercased()
    }




    // MARK: - helpers

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
