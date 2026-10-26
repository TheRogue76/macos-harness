import Foundation
import HarnessCore
import HarnessWayland
import Testing
@testable import HarnessLinux

struct HiddenTreesTests {
    private func folder() throws -> String {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("hidden-trees-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    private func write(_ text: String, to path: String) {
        _ = FileManager.default.createFile(atPath: path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o755])
    }

    @Test func recognizesChromiumBesideItsResources() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(atPath: root) }
        write("binary", to: "\(root)/chrome")
        write("", to: "\(root)/icudtl.dat")
        write("", to: "\(root)/v8_context_snapshot.bin")
        try FileManager.default.createSymbolicLink(atPath: "\(root)/link", withDestinationPath: "\(root)/chrome")
        #expect(HiddenTrees.isChromium(executable: "\(root)/chrome"))
        #expect(HiddenTrees.isChromium(executable: "\(root)/link"))
    }

    @Test func recognizesLaunchersThatStartElectron() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(atPath: root) }
        write("#!/usr/bin/env sh\nELECTRON_RUN_AS_NODE=1 \"$VSCODE_PATH/code\" \"$@\"\n", to: "\(root)/code")
        write("#!/bin/sh\nexec /usr/bin/gnome-calculator \"$@\"\n", to: "\(root)/calc")
        write("plain binary", to: "\(root)/tool")
        #expect(HiddenTrees.isChromium(executable: "\(root)/code"))
        #expect(!HiddenTrees.isChromium(executable: "\(root)/calc"))
        #expect(!HiddenTrees.isChromium(executable: "\(root)/tool"))
        #expect(!HiddenTrees.isChromium(executable: "\(root)/missing"))
    }

    @Test func addsTheFlagOnceForChromium() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(atPath: root) }
        write("#!/bin/bash\nexec /opt/google/chrome/chrome \"$@\"\n", to: "\(root)/google-chrome")
        let (added, notice) = HiddenTrees.launchArguments(for: "\(root)/google-chrome", given: [])
        #expect(added == [HiddenTrees.flag])
        #expect(notice?.kind == "treeEnabled")
        #expect(HiddenTrees.launchArguments(for: "\(root)/google-chrome", given: [HiddenTrees.flag]).0.isEmpty)
        write("#!/bin/sh\necho hi\n", to: "\(root)/other")
        #expect(HiddenTrees.launchArguments(for: "\(root)/other", given: []).0.isEmpty)
    }
}

struct CompositorTests {
    private func window(_ pid: Int32, _ title: String, focused: Bool = false) -> CompositorWindow {
        CompositorWindow(pid: pid, title: title, appID: nil, frame: .zero, focused: focused, visible: true, output: nil)
    }

    @Test func matchesAnAppsWindowByPidThenTitle() {
        let windows = [window(1, "Calculator"), window(2, "Notes — a"), window(2, "Notes — b", focused: true)]
        #expect(Compositors.match(windows, pid: 1, title: "anything")?.title == "Calculator")
        #expect(Compositors.match(windows, pid: 2, title: "Notes — a")?.title == "Notes — a")
        #expect(Compositors.match(windows, pid: 2, title: "Other")?.title == "Notes — b")
        #expect(Compositors.match(windows, pid: 3, title: "Calculator") == nil)
        #expect(Compositors.match(windows, pid: nil, title: "Calculator") == nil)
    }
}

struct LinuxInputTests {
    @Test func mapsModifiersToXKBMasksWithCommandAsControl() throws {
        #expect(try LinuxDesktop.xkbModifiers([.command]) == XKBKeymap.control)
        #expect(try LinuxDesktop.xkbModifiers([.shift, .option]) == XKBKeymap.shift | XKBKeymap.alt)
        #expect(try LinuxDesktop.xkbModifiers([]) == 0)
    }

    @Test func namesKeysForChords() throws {
        #expect(LinuxDesktop.keysym(try KeyChord.parse("return").key) == "Return")
        #expect(LinuxDesktop.keysym(try KeyChord.parse("cmd+a").key) == "U0061")
        #expect(LinuxDesktop.keysym(try KeyChord.parse("delete").key) == "BackSpace")
        #expect(LinuxDesktop.keysym(try KeyChord.parse("pagedown").key) == "Next")
        #expect(LinuxDesktop.keysym(try KeyChord.parse("f5").key) == "F5")
    }
}

struct GnomeCompositorTests {
    @Test func readsTheExtensionsWindowList() throws {
        let list = try JSONSerialization.jsonObject(with: Data("""
            [{"id": 3507259647, "pid": 1215686, "title": "Harness Fixture", "wmClass": "harness-fixture", "appId": "io.github.therogue76.HarnessFixture",
              "x": 200, "y": 106, "width": 880, "height": 620, "focused": true, "minimized": false, "monitor": 0},
             {"id": 7, "pid": 9, "title": "Hidden", "x": 0, "y": 0, "width": 10, "height": 10, "focused": false, "minimized": true, "monitor": 1}]
            """.utf8))
        let windows = GnomeCompositor.windows(from: list)
        #expect(windows.count == 2)
        #expect(windows[0].id == 3_507_259_647)
        #expect(windows[0].pid == 1_215_686)
        #expect(windows[0].frame == CGRect(x: 200, y: 106, width: 880, height: 620))
        #expect(windows[0].focused && windows[0].visible)
        #expect(windows[0].appID == "io.github.therogue76.HarnessFixture")
        #expect(!windows[1].visible)
        #expect(windows[1].output == "1")
        #expect(GnomeCompositor.windows(from: "not a list").isEmpty)
    }
}

struct GnomeInputTests {
    @Test func namesKeysymsForThePortal() {
        #expect(GnomeInput.keysym("U0061") == 0x61)
        #expect(GnomeInput.keysym("U00E9") == 0xE9)
        #expect(GnomeInput.keysym("U20AC") == 0x0100_20AC)
        #expect(GnomeInput.keysym("Return") == 0xFF0D)
        #expect(GnomeInput.keysym("F5") == 0xFFC2)
        #expect(GnomeInput.keysym("Nope") == 0)
    }

    @Test func holdsTheKeysOfEachModifier() {
        #expect(GnomeInput.modifierKeysyms(XKBKeymap.control | XKBKeymap.shift) == [0xFFE1, 0xFFE3])
        #expect(GnomeInput.modifierKeysyms(0).isEmpty)
    }
}
