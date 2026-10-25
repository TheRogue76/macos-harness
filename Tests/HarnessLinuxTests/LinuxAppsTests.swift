import Foundation
import Testing
@testable import HarnessLinux

struct LinuxAppsTests {
    @Test func splitsExecLinesWithoutFieldCodes() {
        #expect(LinuxApps.execWords("gnome-calculator") == ["gnome-calculator"])
        #expect(LinuxApps.execWords("/usr/bin/code --new-window %F") == ["/usr/bin/code", "--new-window"])
        #expect(LinuxApps.execWords("\"/opt/My App/run\" --name \"a b\" %u") == ["/opt/My App/run", "--name", "a b"])
        #expect(LinuxApps.execWords("env FOO=1 app --pct 100%%") == ["env", "FOO=1", "app", "--pct", "100%"])
    }

    @Test func readsTheMainGroupOfADesktopEntry() throws {
        let entry = try #require(LinuxApps.DesktopEntry("""
            [Desktop Entry]
            Type=Application
            Name=Calculator
            Name[de]=Rechner
            Exec=gnome-calculator
            [Desktop Action new]
            Exec=gnome-calculator --new
            """))
        #expect(entry.name == "Calculator")
        #expect(entry.exec == "gnome-calculator")
        #expect(!entry.hidden)
        #expect(LinuxApps.DesktopEntry("[Desktop Entry]\nType=Link\nName=Docs\nURL=x")?.hidden == true)
        #expect(LinuxApps.DesktopEntry("[Other]\nName=x") == nil)
    }

    @Test func matchesNamesIgnoringCaseAndSeparators() {
        #expect(LinuxApps.matches("Harness Fixture", "harness-fixture"))
        #expect(LinuxApps.matches("harness_fixture", "HarnessFixture"))
        #expect(!LinuxApps.matches("Harness", "harness-fixture"))
        #expect(!LinuxApps.matches("", ""))
    }

    @Test func findsDesktopEntriesThenProgramsBesideTheHelper() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("linux-apps-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: root) }
        let applications = "\(root)/data/applications"
        let bin = "\(root)/bin"
        let helper = "\(root)/helper"
        for directory in [applications, bin, helper] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
        func program(_ path: String) throws {
            _ = FileManager.default.createFile(atPath: path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        }
        try program("\(bin)/calc-tool")
        try program("\(helper)/harness-fixture")
        try "[Desktop Entry]\nType=Application\nName=Calculator\nExec=calc-tool --basic %U\n"
            .write(toFile: "\(applications)/org.example.Calculator.desktop", atomically: true, encoding: .utf8)
        let environment = ["HOME": root, "XDG_DATA_HOME": "\(root)/data", "XDG_DATA_DIRS": "\(root)/none", "PATH": bin]

        let byName = LinuxApps.command(for: "calculator", environment: environment, helperDirectory: helper)
        #expect(byName == LinuxApps.Command(executable: "\(bin)/calc-tool", arguments: ["--basic"]))
        #expect(LinuxApps.command(for: "org.example.Calculator", environment: environment, helperDirectory: helper) == byName)
        #expect(LinuxApps.command(for: "Harness Fixture", environment: environment, helperDirectory: helper)?.executable == "\(helper)/harness-fixture")
        #expect(LinuxApps.command(for: "calc-tool", environment: environment, helperDirectory: helper)?.executable == "\(bin)/calc-tool")
        #expect(LinuxApps.command(for: "\(bin)/calc-tool", environment: environment, helperDirectory: helper)?.executable == "\(bin)/calc-tool")
        #expect(LinuxApps.command(for: "Nothing", environment: environment, helperDirectory: helper) == nil)
    }

    @Test func knowsWhenAProcessIsGone() {
        #expect(LinuxApps.isAlive(getpid()))
        #expect(!LinuxApps.isAlive(999_999_999))
    }
}
