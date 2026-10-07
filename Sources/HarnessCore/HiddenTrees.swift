import AppKit
import ApplicationServices
import Foundation
import HarnessProtocol

/// Switches on the accessibility tree of Chromium-based apps (Electron, CEF, Chrome and its
/// relatives), which build it only when an assistive app asks.
public actor HiddenTrees {
    public static let shared = HiddenTrees()

    public enum Engine: String, Sendable {
        case electron = "Electron"
        case cef = "Chromium Embedded Framework"
        case chromium = "Chromium"
    }

    private var engines: [pid_t: Engine?] = [:]
    private var enabled: Set<pid_t> = []

    /// Makes sure the app's tree is on before it's read; returns a notice the first time it had to
    /// switch it on.
    public func prepare(_ app: AppRef) async -> Notice? {
        guard !enabled.contains(app.pid), let engine = engine(for: app) else { return nil }
        enabled.insert(app.pid)
        let element = AX.application(app.pid)
        let before = Self.size(of: element)
        AX.set(element, "AXManualAccessibility", kCFBooleanTrue)
        guard before < Self.populated else { return nil }
        var after = await Self.waitForGrowth(of: element, from: before)
        if after <= before {
            AX.set(element, "AXEnhancedUserInterface", kCFBooleanTrue)
            after = await Self.waitForGrowth(of: element, from: before)
        }
        guard after > before else {
            return Notice(
                kind: "treeHidden",
                message: "\(app.name) (\(engine.rawValue)) keeps most of its accessibility tree hidden. Quit it and launch it again with `launch \"\(app.name)\" --arg=--force-renderer-accessibility`, or work from screenshots."
            )
        }
        return Notice(
            kind: "treeEnabled",
            message: "Switched on \(app.name)'s accessibility tree (\(engine.rawValue) apps build it only when asked); it may run a little slower until it quits."
        )
    }

    /// The Chromium engine the app is built on, or nil for other apps.
    public func engine(for app: AppRef) -> Engine? {
        if let known = engines[app.pid] { return known }
        let found = Self.detect(bundle: NSRunningApplication(processIdentifier: app.pid)?.bundleURL)
        engines[app.pid] = found
        return found
    }

    static func detect(bundle: URL?) -> Engine? {
        guard let frameworks = bundle?.appendingPathComponent("Contents/Frameworks").path,
              let names = try? FileManager.default.contentsOfDirectory(atPath: frameworks) else { return nil }
        return detect(frameworks: names)
    }

    /// The engine a bundle's Frameworks folder names, if any.
    static func detect(frameworks names: [String]) -> Engine? {
        if names.contains("Electron Framework.framework") { return .electron }
        if names.contains("Chromium Embedded Framework.framework") { return .cef }
        let chromium = ["Chromium Framework", "Google Chrome Framework", "Microsoft Edge Framework", "Brave Browser Framework", "Arc Framework", "Vivaldi Framework", "Opera Framework"]
        if names.contains(where: { name in chromium.contains { name.hasPrefix($0) } }) { return .chromium }
        return nil
    }

    /// A first window with this many nodes already has its tree on.
    static let populated = 40

    /// Nodes in the app's first window, read quickly and capped.
    static func size(of app: AXUIElement) -> Int {
        guard let window = AX.children(app).first(where: { AX.role($0) == "AXWindow" }) else { return 0 }
        return AXReader(maxNodes: 3000, maxDepth: 60, timeBudget: 0.5).read(window).count
    }

    static func waitForGrowth(of app: AXUIElement, from before: Int) async -> Int {
        var size = before
        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(200))
            size = Self.size(of: app)
            if size > before + 5 { break }
        }
        return size
    }
}
