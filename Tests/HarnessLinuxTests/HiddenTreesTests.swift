import Foundation
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
