import Foundation

/// The folder where the CLI keeps screenshots it wasn't told where to save, and their clean-up.
public enum TemporaryScreenshots {
    /// How long a screenshot stays: long enough for the agent that asked to read it.
    public static let lifetime: TimeInterval = 3600

    public static var directory: URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("macos-harness", isDirectory: true)
    }

    /// Deletes the folder's PNGs last changed more than `lifetime` ago, and returns how many.
    @discardableResult
    public static func prune(_ directory: URL = directory, now: Date = Date(), lifetime: TimeInterval = lifetime) -> Int {
        let manager = FileManager.default
        let files = (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var removed = 0
        for file in files where file.pathExtension.lowercased() == "png" {
            let changed = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now
            if now.timeIntervalSince(changed) > lifetime, (try? manager.removeItem(at: file)) != nil {
                removed += 1
            }
        }
        return removed
    }
}
