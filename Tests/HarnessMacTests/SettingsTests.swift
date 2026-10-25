import ApplicationServices
import CoreGraphics
import Foundation
import HarnessClient
import HarnessProtocol
import Testing
@testable import HarnessCore
@testable import HarnessMac

/// Defaults kept in memory for one test, so nothing is written to the user's preferences.
private final class ScratchDefaults {
    let defaults: UserDefaults = MemoryDefaults()
}

private final class MemoryDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Any] = [:]

    convenience init() {
        self.init(suiteName: nil)!
    }

    override func object(forKey defaultName: String) -> Any? { values[defaultName] }
    override func data(forKey defaultName: String) -> Data? { values[defaultName] as? Data }
    override func bool(forKey defaultName: String) -> Bool { values[defaultName] as? Bool ?? false }
    override func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
    override func set(_ value: Bool, forKey defaultName: String) { values[defaultName] = value }
    override func removeObject(forKey defaultName: String) { values[defaultName] = nil }
}

struct SettingsStoreTests {
    @Test func everythingIsOnUntilTheUserTurnsItOff() {
        let scratch = ScratchDefaults()
        let settings = SettingsStore(defaults: scratch.defaults)
        #expect(settings.backgroundRoute)
        #expect(settings.windowOutline)
        #expect(settings.outlineReads)
        #expect(settings.drivingPanel)
        #expect(settings.summary == DoctorMethod.Settings())
    }

    @Test func choicesPersistAcrossLaunches() {
        let scratch = ScratchDefaults()
        let first = SettingsStore(defaults: scratch.defaults)
        first.backgroundRoute = false
        first.windowOutline = false
        first.drivingPanel = false
        let relaunched = SettingsStore(defaults: scratch.defaults)
        #expect(!relaunched.backgroundRoute)
        #expect(!relaunched.windowOutline)
        #expect(relaunched.outlineReads)
        #expect(!relaunched.drivingPanel)
        #expect(relaunched.summary == DoctorMethod.Settings(backgroundRoute: false, windowOutline: false, outlineReads: true, drivingPanel: false))
        relaunched.backgroundRoute = true
        #expect(SettingsStore(defaults: scratch.defaults).backgroundRoute)
    }

    @Test func keepsTheEarlierReadsSwitch() {
        let scratch = ScratchDefaults()
        scratch.defaults.set(false, forKey: "showActivityOnScreen")
        let settings = SettingsStore(defaults: scratch.defaults)
        #expect(!settings.outlineReads)
        #expect(settings.windowOutline)
    }
}

struct BackgroundRouteSettingTests {
    private let window = WindowService.Window(
        info: WindowInfo(
            id: 1, app: AppRef(name: "Test", bundleIdentifier: nil, pid: getpid()), title: "Test",
            frame: Rect(x: 100, y: 50, width: 400, height: 300), onScreen: true, minimized: false,
            focused: true, main: true, subrole: nil, hasSheet: false
        ),
        element: AXUIElementCreateApplication(getpid())
    )
    private let inside = CGPoint(x: 200, y: 100)
    private let onScreen: (UInt32) -> Bool = { _ in true }
    /// Whether this Mac has the private calls the route needs.
    private let available = SkyLight.missing.isEmpty

    private func params(_ action: PointerAction, dy: Double = 0, real: Bool? = nil) -> PointerMethod.Params {
        PointerMethod.Params(target: Target(app: "Test"), action: action, dy: dy, diff: true, real: real)
    }

    private func settings(backgroundRoute: Bool, in scratch: ScratchDefaults) -> SettingsStore {
        let settings = SettingsStore(defaults: scratch.defaults)
        settings.backgroundRoute = backgroundRoute
        return settings
    }

    @Test func onClicksAndScrollsTryTheBackground() {
        let scratch = ScratchDefaults()
        let on = settings(backgroundRoute: true, in: scratch)
        for action in [PointerAction.click, .doubleClick, .rightClick] {
            #expect((BackgroundInput.route(for: params(action), at: inside, in: window, settings: on, isOnScreen: onScreen) != nil) == available)
            #expect(BackgroundInput.turnedOffNotice(for: params(action), at: inside, in: window, settings: on, isOnScreen: onScreen) == nil)
        }
        #expect((BackgroundInput.route(for: params(.scroll, dy: -200), at: inside, in: window, settings: on, isOnScreen: onScreen) != nil) == available)
        #expect(BackgroundInput.routes(at: inside, in: window, settings: on, isOnScreen: onScreen) == available)
    }

    @Test func offTheyGoStraightToTheRealMouseAndSayWhy() {
        let scratch = ScratchDefaults()
        let off = settings(backgroundRoute: false, in: scratch)
        for action in [PointerAction.click, .doubleClick, .rightClick] {
            #expect(BackgroundInput.route(for: params(action), at: inside, in: window, settings: off, isOnScreen: onScreen) == nil)
            let notice = BackgroundInput.turnedOffNotice(for: params(action), at: inside, in: window, settings: off, isOnScreen: onScreen)
            #expect((notice?.kind == "backgroundOff") == available)
        }
        #expect(BackgroundInput.route(for: params(.scroll, dy: -200), at: inside, in: window, settings: off, isOnScreen: onScreen) == nil)
        let scroll = BackgroundInput.turnedOffNotice(for: params(.scroll, dy: -200), at: inside, in: window, settings: off, isOnScreen: onScreen)
        #expect((scroll?.message.contains("the scroll used the real mouse") ?? false) == available)
    }

    @Test func offPressesWithoutAnActionClickWithTheRealMouse() {
        let scratch = ScratchDefaults()
        let off = settings(backgroundRoute: false, in: scratch)
        #expect(!BackgroundInput.routes(at: inside, in: window, settings: off, isOnScreen: onScreen))
        let notice = BackgroundInput.turnedOffNotice(.click(count: 1, button: .left), at: inside, in: window, settings: off, isOnScreen: onScreen)
        #expect((notice?.kind == "backgroundOff") == available)
    }

    @Test func offSaysNothingForWhatNeverTriedTheBackground() {
        let scratch = ScratchDefaults()
        let off = settings(backgroundRoute: false, in: scratch)
        #expect(BackgroundInput.turnedOffNotice(for: params(.click, real: true), at: inside, in: window, settings: off, isOnScreen: onScreen) == nil)
        #expect(BackgroundInput.turnedOffNotice(for: params(.hover), at: inside, in: window, settings: off, isOnScreen: onScreen) == nil)
        #expect(BackgroundInput.turnedOffNotice(for: params(.drag), at: inside, in: window, settings: off, isOnScreen: onScreen) == nil)
        #expect(BackgroundInput.turnedOffNotice(for: params(.click), at: inside, in: window, settings: off, isOnScreen: { _ in false }) == nil)
        #expect(BackgroundInput.turnedOffNotice(for: params(.click), at: CGPoint(x: 5, y: 5), in: window, settings: off, isOnScreen: onScreen) == nil)
    }
}

struct ClearRecentTests {
    private func entry(_ agent: String, at seconds: TimeInterval) -> ActivityEntry {
        ActivityEntry(
            date: Date(timeIntervalSince1970: seconds), agentKey: agent, agentName: agent, method: "snapshot",
            summary: "read", kind: "reading", app: "App"
        )
    }

    @Test func clearsTheListButNotTheSessions() {
        var tracker = SessionTracker(idleTimeout: 120)
        tracker.record(entry("codex", at: 0))
        tracker.record(entry("pi", at: 10))
        tracker.clearRecent()
        #expect(tracker.recent.isEmpty)
        #expect(tracker.active(at: Date(timeIntervalSince1970: 20)).count == 2)
        tracker.record(entry("codex", at: 30))
        #expect(tracker.recent.count == 1)
        #expect(tracker.active(at: Date(timeIntervalSince1970: 40)).first { $0.agentKey == "codex" }?.steps == 2)
    }
}

struct PairingRevokeTests {
    @Test func revokingOneAgentKeepsTheOthers() {
        let scratch = ScratchDefaults()
        let store = PairingStore(defaults: scratch.defaults)
        store.approve(key: "Codex|2DC432GLL2|codex", displayName: "Codex")
        store.approve(key: "Demo Agent|DEMO123456|preview", displayName: "Demo Agent")
        #expect(store.all.map(\.displayName) == ["Codex", "Demo Agent"])
        store.revoke(key: "Demo Agent|DEMO123456|preview")
        #expect(!store.isPaired("Demo Agent|DEMO123456|preview"))
        #expect(store.isPaired("Codex|2DC432GLL2|codex"))
        #expect(PairingStore(defaults: scratch.defaults).all.map(\.key) == ["Codex|2DC432GLL2|codex"])
    }
}

struct DoctorSettingsTests {
    private func report(_ settings: DoctorMethod.Settings?) -> DoctorMethod.Result {
        DoctorMethod.Result(
            helperVersion: HarnessVersion.string, protocolVersion: HarnessVersion.protocolVersion, bundleIdentifier: "test",
            bundlePath: "/Applications/macOS Harness.app", helperPID: 1, macOSVersion: "27.0", permissions: .init(accessibility: true, screenRecording: true),
            secureInputEnabled: false, caller: CallerInfo(displayName: "Codex", identityKey: "Codex|X|codex", paired: true, chain: []),
            settings: settings
        )
    }

    @Test func showsTheSettings() {
        let text = Render.doctor(report(DoctorMethod.Settings()), socketPath: "/tmp/socket")
        #expect(text.contains("  settings: background clicks on, window outline on (reads too), driving panel on"))
        #expect(!text.contains("Background clicks off"))
    }

    @Test func callsOutTheRealMouseWhenTheRouteIsOff() {
        let settings = DoctorMethod.Settings(backgroundRoute: false, windowOutline: true, outlineReads: false, drivingPanel: false)
        let text = Render.doctor(report(settings), socketPath: "/tmp/socket")
        #expect(text.contains("- Background clicks off: clicks and scrolls always use the real mouse"))
        #expect(text.contains("  settings: background clicks off, window outline on (actions only), driving panel off"))
        #expect(Render.isHealthy(report(settings)))
    }

    @Test func olderHelpersLeaveThemOut() throws {
        #expect(!Render.doctor(report(nil), socketPath: "/tmp/socket").contains("settings:"))
        var json = try JSONEncoder().encode(report(nil))
        let decoded = try JSONDecoder().decode(DoctorMethod.Result.self, from: json)
        #expect(decoded.settings == nil)
        json = try JSONEncoder().encode(report(DoctorMethod.Settings(backgroundRoute: false)))
        #expect(try JSONDecoder().decode(DoctorMethod.Result.self, from: json).settings?.backgroundRoute == false)
    }
}
