import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import HarnessProtocol
import ScreenCaptureKit

@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

extension Spikes {
    /// S10: what reaches an app's windows on Spaces that aren't showing: whether `AXWindows` lists
    /// them, whether a remote token finds their elements, and whether their trees can be read
    /// and pressed, their pictures captured, and background clicks and keys reach them.
    static func offSpace(_ arguments: [String]) async throws -> String {
        let usage = "offspace <app> [press=<button title>] [field=<text field placeholder>] [tries=<n>] [all]"
        guard let query = arguments.first else { throw RPCError(code: RPCErrorCode.invalidParams, message: "usage: \(usage)") }
        func option(_ name: String) -> String? {
            arguments.dropFirst().first { $0.hasPrefix(name + "=") }.map { String($0.dropFirst(name.count + 1)) }
        }
        let pressTitle = option("press") ?? "Press me"
        let fieldPlaceholder = option("field") ?? "Type here"
        let tries = option("tries").flatMap(UInt64.init) ?? 5000
        let everyWindow = arguments.dropFirst().contains("all")
        let target = try await app(query)
        try requireAccessibility()
        let active = SkyLight.activeSpace()
        var lines = ["\(target.name) (pid \(target.pid)); the showing Space is \(active.map(String.init) ?? "?")"]

        let listed = (CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
            .filter { ($0[kCGWindowOwnerPID as String] as? pid_t) == target.pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
        let root = AX.application(target.pid)
        AX.setTimeout(root, seconds: 2)
        let axIDs = AX.elements(root, "AXWindows").compactMap { element -> CGWindowID? in
            var id: CGWindowID = 0
            return _AXUIElementGetWindow(element, &id) == .success ? id : nil
        }
        lines.append("AXWindows lists: \(axIDs.map(String.init).joined(separator: ", "))")
        for attribute in ["AXMainWindow", "AXFocusedWindow"] {
            var id: CGWindowID = 0
            let window = AX.element(root, attribute)
            let named = window.map { _AXUIElementGetWindow($0, &id) == .success ? "window \(id)" : "an element without a window ID" } ?? "nothing"
            lines.append("\(attribute) gives \(named)")
        }

        for info in listed {
            guard let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { continue }
            let title = info[kCGWindowName as String] as? String ?? ""
            let bounds = (info[kCGWindowBounds as String] as? [String: Any]).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) } ?? .zero
            let spaces = SkyLight.spaces(ofWindow: id) ?? []
            let showing = active.map { spaces.contains($0) } ?? false
            lines.append("")
            lines.append("window \(id) “\(title)” \(Int(bounds.width))x\(Int(bounds.height)) at (\(Int(bounds.minX)),\(Int(bounds.minY))), Spaces \(spaces.map(String.init).joined(separator: ",")), \(showing ? "on the showing Space" : "on another Space"), \(axIDs.contains(id) ? "in AXWindows" : "not in AXWindows")")
            guard everyWindow || !showing || !axIDs.contains(id) else { continue }

            let started = Date()
            guard let found = RemoteElements.lookup(pid: target.pid, id: id, tries: tries) else {
                lines.append("  remote token: no element for it among IDs 0..<\(tries) (\(milliseconds(since: started)) ms)")
                continue
            }
            lines.append("  remote token: element ID \(found.elementID) in \(milliseconds(since: started)) ms")
            let element = found.element
            AX.setTimeout(element, seconds: 2)
            let raw = AXReader(maxNodes: 2000, maxDepth: 40, timeBudget: 3).read(element)
            let labels = flattened(raw).compactMap { node in node.label ?? node.value }.prefix(8)
            lines.append("  tree: \(raw.count) elements; \(labels.map { "“\($0.prefix(30))”" }.joined(separator: " "))")

            func counter() -> String {
                flattened(AXReader(maxNodes: 2000, maxDepth: 40, timeBudget: 2).read(element))
                    .compactMap { $0.value ?? $0.label }.first { $0.hasPrefix("Presses") } ?? "no counter"
            }
            let button = descendants(of: element).first { AX.role($0) == "AXButton" && AX.string($0, "AXTitle") == pressTitle }
            if let button {
                let result = AX.perform(button, "AXPress")
                try? await Task.sleep(for: .milliseconds(300))
                lines.append("  AXPress “\(pressTitle)”: AXError \(result.rawValue); now \(counter())")
            } else {
                lines.append("  no button titled “\(pressTitle)”")
            }

            lines.append("  " + (await capture(window: id)))
            lines.append("  " + skyLightCapture(window: id))

            if let button, let frame = AX.frame(button) {
                let point = CGPoint(x: frame.midX, y: frame.midY)
                let sent = await BackgroundClick.click(
                    pid: target.pid, window: id, at: point, windowOrigin: bounds.origin, count: 1, button: .left, location: .window, focusFirst: true
                )
                try? await Task.sleep(for: .milliseconds(500))
                lines.append("  background click at window (\(Int(point.x - bounds.minX)),\(Int(point.y - bounds.minY))): \(sent ? "posted" : "not posted"); now \(counter())")
            }

            if let field = descendants(of: element).first(where: { AX.string($0, "AXPlaceholderValue") == fieldPlaceholder }) {
                let setResult = AX.set(field, "AXValue", "set by AX" as CFString)
                lines.append("  AX set-value on the field: AXError \(setResult.rawValue); value “\(AX.string(field, "AXValue") ?? "")”")
                _ = AX.set(field, "AXValue", "" as CFString)
                _ = AX.set(field, "AXFocused", kCFBooleanTrue)
                ActionService.postText("keys", to: target.pid)
                try? await Task.sleep(for: .milliseconds(300))
                lines.append("  background keys “keys” to the focused field: value “\(AX.string(field, "AXValue") ?? "")”")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// S10: moves a window, any app's, to a Space through SkyLight, and reports its Spaces before and after.
    static func moveToSpace(_ arguments: [String]) throws -> String {
        guard arguments.count == 2, let window = UInt32(arguments[0]), let space = UInt64(arguments[1]) else {
            throw RPCError(code: RPCErrorCode.invalidParams, message: "usage: movespace <window> <space>")
        }
        typealias MainConnection = @convention(c) () -> UInt32
        typealias MoveToSpace = @convention(c) (UInt32, CFArray, UInt64) -> Void
        _ = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_GLOBAL)
        let handle = UnsafeMutableRawPointer(bitPattern: -2)
        guard let connection = dlsym(handle, "SLSMainConnectionID").map({ unsafeBitCast($0, to: MainConnection.self) }),
              let move = dlsym(handle, "SLSMoveWindowsToManagedSpace").map({ unsafeBitCast($0, to: MoveToSpace.self) }) else {
            return "SLSMoveWindowsToManagedSpace doesn't resolve"
        }
        let before = SkyLight.spaces(ofWindow: window) ?? []
        move(connection(), [NSNumber(value: window)] as CFArray, space)
        usleep(300_000)
        let after = SkyLight.spaces(ofWindow: window) ?? []
        return "window \(window): Spaces \(before.map(String.init).joined(separator: ",")) → \(after.map(String.init).joined(separator: ","))"
    }

    private static func capture(window id: CGWindowID) async -> String {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let scWindow = content.windows.first(where: { $0.windowID == id }) else { return "ScreenCaptureKit: the window isn't listed" }
            let configuration = SCStreamConfiguration()
            configuration.width = Int(scWindow.frame.width)
            configuration.height = Int(scWindow.frame.height)
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: scWindow), configuration: configuration
            )
            return "ScreenCaptureKit: \(image.width)x\(image.height), \(isBlank(image) ? "blank" : "has content")"
        } catch {
            return "ScreenCaptureKit: \(error.localizedDescription)"
        }
    }

    /// A picture of the window through SkyLight's hardware capture, which window switchers use for
    /// windows on other Spaces.
    private static func skyLightCapture(window id: CGWindowID) -> String {
        guard let image = SkyLight.captureWindow(id) else { return "SkyLight capture: no image" }
        let url = URL(fileURLWithPath: HarnessPaths.homeDirectory)
            .appendingPathComponent("Library/Application Support/macos-harness/spikes/offspace-\(id).png")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let saved = (try? writePNG(image, to: url)) != nil ? " → \(url.path)" : ""
        return "SkyLight capture: \(image.width)x\(image.height), \(isBlank(image) ? "blank" : "has content")\(saved)"
    }

    private static func isBlank(_ image: CGImage) -> Bool {
        let width = 64, height = 64
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return true }
        let first = Array(pixels[0..<4])
        return stride(from: 0, to: pixels.count, by: 4).allSatisfy { Array(pixels[$0..<$0 + 4]) == first }
    }

    private static func flattened(_ node: RawNode) -> [RawNode] {
        [node] + node.children.flatMap(flattened)
    }

    private static func descendants(of element: AXUIElement) -> [AXUIElement] {
        AX.children(element).flatMap { [$0] + descendants(of: $0) }
    }

    private static func milliseconds(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }
}

extension Spikes {
    /// Clicks a menu bar extra with the real mouse, keeping what it opens, and reports the windows
    /// it opened and which accessibility paths reach them.
    static func extraClick(_ arguments: [String]) async throws -> String {
        guard arguments.count >= 2 else { throw RPCError(code: RPCErrorCode.invalidParams, message: "usage: extraclick <app> <extra>") }
        let target = try await app(arguments[0])
        try requireAccessibility()
        let app = AppRef(name: target.name, bundleIdentifier: nil, pid: target.pid)
        let appElement = AX.application(target.pid)
        let elements = MenuExtras.extraElements(of: appElement)
        let location = try MenuExtras.locate([arguments[1]], in: elements.map(MenuExtras.info), appName: target.name)
        let extra = elements[location.index]
        guard let frame = AX.frame(extra) else { return "the extra has no frame" }
        func onScreen() -> [[String: Any]] {
            (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [])
                .filter { ($0[kCGWindowOwnerPID as String] as? pid_t) == target.pid }
        }
        let before = Set(onScreen().compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value })
        var lines = ["extra “\(arguments[1])” at \(Int(frame.midX)),\(Int(frame.midY))"]
        let session = try await RealInputSession.begin(app: app, window: nil, context: .unattended, keyboard: false)
        try await session.click(at: CGPoint(x: frame.midX, y: frame.midY))
        await session.end()
        _ = await session.finish(keepFront: true)
        try? await Task.sleep(for: .milliseconds(700))
        for entry in onScreen() {
            guard let id = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value, !before.contains(id) else { continue }
            let layer = entry[kCGWindowLayer as String] as? Int ?? -1
            lines.append("new window \(id), layer \(layer)")
            for attribute in ["AXFocusedWindow", "AXMainWindow"] {
                let window = AX.element(appElement, attribute)
                lines.append("  \(attribute): \(window.flatMap(WindowService.windowID(of:)).map { "window \($0)" } ?? "none")")
            }
            let listed = AX.elements(appElement, "AXWindows").compactMap(WindowService.windowID(of:))
            lines.append("  in AXWindows: \(listed.contains(id))")
            if let element = RemoteElements.window(pid: target.pid, id: id) {
                let raw = AXReader(maxNodes: 200, maxDepth: 20, timeBudget: 2).read(element)
                lines.append("  remote lookup: found; \(raw.count) elements, role \(raw.role)/\(raw.subrole ?? "-")")
            } else {
                lines.append("  remote lookup: not found")
            }
        }
        if lines.count == 1 { lines.append("no new window") }
        return lines.joined(separator: "\n")
    }
}
