import Foundation
import HarnessClient
import HarnessProtocol
import Testing

@Suite struct PiSkillTests {
    private func temporaryHome() throws -> String {
        let home = NSTemporaryDirectory() + "pi-home-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        return home
    }

    private func writeLegacySkill(_ text: String, home: String) throws -> String {
        let folder = "\(PiSkill.skillsDirectory(home: home))/\(HarnessProduct.legacySkillName)"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try text.write(toFile: "\(folder)/SKILL.md", atomically: true, encoding: .utf8)
        return folder
    }

    @Test func theSkillGoesUnderItsNewName() {
        #expect(PiSkill.file(home: "/Users/someone") == "/Users/someone/.pi/agent/skills/otto/SKILL.md")
    }

    @Test func findsTheOldSkillThisProductInstalled() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        #expect(PiSkill.legacyFolder(home: home) == nil)
        let folder = try writeLegacySkill("---\nname: macos-harness\ndescription: See and operate macOS apps\n---\n\n# macOS Harness\n", home: home)
        #expect(PiSkill.legacyFolder(home: home) == folder)
    }

    @Test func leavesSomeoneElsesSkillInThatFolderAlone() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        _ = try writeLegacySkill("---\nname: my-own-skill\n---\n\nname: macos-harness\n", home: home)
        #expect(PiSkill.legacyFolder(home: home) == nil)
        try "name: macos-harness\n".write(
            toFile: "\(PiSkill.skillsDirectory(home: home))/\(HarnessProduct.legacySkillName)/SKILL.md", atomically: true, encoding: .utf8
        )
        #expect(PiSkill.legacyFolder(home: home) == nil)
    }

    @Test func removingTheOldSkillKeepsAFolderThatHoldsOtherFiles() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let folder = try writeLegacySkill("---\nname: macos-harness\n---\n", home: home)
        try "mine".write(toFile: "\(folder)/notes.md", atomically: true, encoding: .utf8)
        try PiSkill.removeLegacy(folder)
        #expect(!FileManager.default.fileExists(atPath: "\(folder)/SKILL.md"))
        #expect(FileManager.default.fileExists(atPath: "\(folder)/notes.md"))

        try FileManager.default.removeItem(atPath: "\(folder)/notes.md")
        _ = try writeLegacySkill("---\nname: macos-harness\n---\n", home: home)
        try PiSkill.removeLegacy(folder)
        #expect(!FileManager.default.fileExists(atPath: folder))
    }

    @Test func saysWhatItReplaced() {
        #expect(PiSkill.replacedNotice == "Replaced the macos-harness skill with otto in pi.")
    }
}
