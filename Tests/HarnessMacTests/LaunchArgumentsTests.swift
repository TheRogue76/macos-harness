import Foundation
@testable import HarnessClient
import HarnessProtocol
import Testing
@testable import HarnessCore
@testable import HarnessMac

struct LaunchArgumentsTests {
    @Test func presetsBecomeArgumentsForThatApp() throws {
        let params = LaunchMethod.Params(app: "TextEdit", appearance: "dark", language: "fr", locale: "fr_FR")
        #expect(try LaunchArguments.presets(params) == [
            "-AppleInterfaceStyle", "Dark", "-NSRequiresAquaSystemAppearance", "NO", "-AppleLanguages", "(fr)", "-AppleLocale", "fr_FR",
        ])
        #expect(try LaunchArguments.presets(LaunchMethod.Params(app: "TextEdit", appearance: "light")) == ["-NSRequiresAquaSystemAppearance", "YES"])
        #expect(try LaunchArguments.presets(LaunchMethod.Params(app: "TextEdit")).isEmpty)
    }

    @Test func badPresetsAreRefused() {
        #expect(throws: RPCError.self) { try LaunchArguments.presets(LaunchMethod.Params(app: "x", appearance: "sepia")) }
        #expect(throws: RPCError.self) { try LaunchArguments.presets(LaunchMethod.Params(app: "x", language: "fr) (de")) }
        #expect(throws: RPCError.self) { try LaunchArguments.presets(LaunchMethod.Params(app: "x", locale: "f")) }
        #expect(throws: Never.self) { try LaunchArguments.presets(LaunchMethod.Params(app: "x", language: "pt-BR", locale: "zh_Hant_TW")) }
    }

    @Test func chromiumAppsKeepWorkingWhenCovered() throws {
        let plain = LaunchMethod.Params(app: "Visual Studio Code", arguments: ["--new-window"])
        #expect(try LaunchArguments.all(plain, engine: .electron) == ["--new-window", LaunchArguments.keepAwake])
        #expect(try LaunchArguments.all(plain, engine: nil) == ["--new-window"])
        var optedOut = plain
        optedOut.allowIdleWhenCovered = true
        #expect(try LaunchArguments.all(optedOut, engine: .chromium) == ["--new-window"])
        let already = LaunchMethod.Params(app: "Chrome", arguments: [LaunchArguments.keepAwake])
        #expect(try LaunchArguments.all(already, engine: .chromium) == [LaunchArguments.keepAwake])
    }

    @Test func flowsTakeThePresets() throws {
        let flow = try FlowParser.parse("""
            name: Dark French TextEdit
            app: TextEdit
            setup:
              - launch: { app: TextEdit, appearance: dark, language: fr, allow_idle_when_covered: true }
            steps:
              - wait: { role: window }
            """)
        guard case let .launch(params, _) = flow.setup.first?.action else {
            Issue.record("expected a launch step")
            return
        }
        #expect(params.appearance == "dark")
        #expect(params.language == "fr")
        #expect(params.allowIdleWhenCovered == true)
        #expect(throws: FlowError.self) {
            try FlowParser.parse("name: x\napp: TextEdit\nsteps:\n  - launch: { app: TextEdit, appearance: sepia }\n")
        }
    }
}

struct ScreenLockTests {
    @Test func aLockedOrSwitchedAwaySessionCounts() {
        #expect(ScreenLock.isLocked(["CGSSessionScreenIsLocked": true, "kCGSSessionOnConsoleKey": true]))
        #expect(ScreenLock.isLocked(["kCGSSessionOnConsoleKey": false]))
        #expect(!ScreenLock.isLocked(["kCGSSessionOnConsoleKey": true]))
        #expect(!ScreenLock.isLocked([:]))
    }
}
