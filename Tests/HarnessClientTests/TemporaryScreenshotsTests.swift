import Foundation
import HarnessClient
import Testing

struct TemporaryScreenshotsTests {
    @Test func oldScreenshotsGoAndEverythingElseStays() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("screenshot-prune-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let now = Date()
        func file(_ name: String, age: TimeInterval) throws -> URL {
            let url = folder.appendingPathComponent(name)
            try Data("x".utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: url.path)
            return url
        }
        let old = try file("TextEdit-1-1.png", age: 7200)
        let fresh = try file("TextEdit-1-2.png", age: 60)
        let notOurs = try file("notes.txt", age: 7200)
        #expect(TemporaryScreenshots.prune(folder, now: now) == 1)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
        #expect(FileManager.default.fileExists(atPath: notOurs.path))
    }

    @Test func aMissingFolderIsFine() {
        #expect(TemporaryScreenshots.prune(URL(fileURLWithPath: "/nonexistent/macos-harness-\(UUID().uuidString)")) == 0)
    }
}
