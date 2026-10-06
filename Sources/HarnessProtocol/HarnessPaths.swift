import Foundation

/// The dev build and the release build are separate apps with separate permissions and sockets.
public enum HarnessVariant: String, Sendable, CaseIterable {
    case dev
    case release

    public var bundleIdentifier: String {
        switch self {
        case .dev: "io.github.therogue76.macos-harness.dev"
        case .release: "io.github.therogue76.macos-harness"
        }
    }

    public var appName: String {
        switch self {
        case .dev: "macOS Harness Dev"
        case .release: "macOS Harness"
        }
    }

    public init?(bundleIdentifier: String) {
        guard let match = Self.allCases.first(where: { $0.bundleIdentifier == bundleIdentifier }) else { return nil }
        self = match
    }

    /// Every binary this project signs uses an identifier starting with this.
    public static let signingIdentifierPrefix = "io.github.therogue76.macos-harness"
}

public enum HarnessPaths {
    /// The user's real home directory, even when $HOME is overridden.
    public static var homeDirectory: String {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return String(cString: dir)
        }
        return NSHomeDirectory()
    }

    /// Where the helper listens: Application Support, or a per-user directory under /tmp when that
    /// path is too long for a socket.
    public static func socketPath(for variant: HarnessVariant, home: String = homeDirectory) -> String {
        let preferred = "\(home)/Library/Application Support/macos-harness/\(variant.rawValue).sock"
        if preferred.utf8.count < 100 {
            return preferred
        }
        return "/tmp/macos-harness-\(getuid())/\(variant.rawValue).sock"
    }
}
