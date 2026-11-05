import Foundation
import HarnessProtocol

/// The agent skill in pi's skills folder: where `setup pi` writes it, and the copy under its name
/// before 2.0 that it replaces.
public enum PiSkill {
    /// pi's skills folder under `home`.
    public static func skillsDirectory(home: String) -> String {
        "\(home)/.pi/agent/skills"
    }

    /// The SKILL.md that `setup pi` writes.
    public static func file(home: String) -> String {
        "\(skillsDirectory(home: home))/\(HarnessProduct.skillName)/SKILL.md"
    }

    /// The folder of the skill under its name before 2.0 when it holds a SKILL.md this product
    /// installed, one whose front matter names it `legacySkillName`; nil when there's none or it's
    /// someone else's.
    public static func legacyFolder(home: String) -> String? {
        let folder = "\(skillsDirectory(home: home))/\(HarnessProduct.legacySkillName)"
        guard let text = try? String(contentsOfFile: "\(folder)/SKILL.md", encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else { return nil }
        return lines[1..<end].contains("name: \(HarnessProduct.legacySkillName)") ? folder : nil
    }

    /// Removes the old skill's SKILL.md, and its folder when nothing else is left in it.
    public static func removeLegacy(_ folder: String) throws {
        let manager = FileManager.default
        try manager.removeItem(atPath: "\(folder)/SKILL.md")
        if (try? manager.contentsOfDirectory(atPath: folder))?.isEmpty == true {
            try manager.removeItem(atPath: folder)
        }
    }

    /// What `setup pi` says after replacing the old skill.
    public static let replacedNotice =
        "Replaced the \(HarnessProduct.legacySkillName) skill with \(HarnessProduct.skillName) in pi."
}
