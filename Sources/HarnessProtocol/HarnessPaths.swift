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

    /// The CLI that talks to this variant's helper.
    public var commandName: String {
        switch self {
        case .dev: "macos-harness-dev"
        case .release: "macos-harness"
        }
    }

    public init?(bundleIdentifier: String) {
        guard let match = Self.allCases.first(where: { $0.bundleIdentifier == bundleIdentifier }) else { return nil }
        self = match
    }

    /// Every binary this project signs uses an identifier starting with this.
    public static let signingIdentifierPrefix = "io.github.therogue76.macos-harness"
}

/// The product's names, kept in one place so a rename touches one file.
public enum HarnessProduct {
    /// The command-line tool's name, also used for the product's folders, socket directory and MCP server.
    public static let commandName = "macos-harness"
}

public enum HarnessPaths {
    /// The user's real home directory, even when $HOME is overridden; looked up once.
    public static let homeDirectory: String = {
        if let entry = unsafe getpwuid(getuid()), let dir = unsafe entry.pointee.pw_dir {
            return unsafe String(cString: dir)
        }
        return NSHomeDirectory()
    }()

    /// Where the helper listens: Application Support on macOS or `$XDG_RUNTIME_DIR` on Linux, or a
    /// per-user directory under /tmp when that is unset or too long for a socket.
    public static func socketPath(
        for variant: HarnessVariant, home: String = homeDirectory,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        let name = HarnessProduct.commandName
        let file = "\(variant.rawValue).sock"
        #if os(macOS)
        let preferred: String? = "\(home)/Library/Application Support/\(name)/\(file)"
        #else
        let preferred = absolute(environment["XDG_RUNTIME_DIR"]).map { "\($0)/\(name)/\(file)" }
        #endif
        if let preferred, preferred.utf8.count < 100 {
            return preferred
        }
        return "/tmp/\(name)-\(getuid())/\(file)"
    }

    /// The policy file, shared by the dev and release builds.
    public static func policyFile(
        home: String = homeDirectory, environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        #if os(macOS)
        "\(home)/.config/\(HarnessProduct.commandName)/policy.yaml"
        #else
        "\(absolute(environment["XDG_CONFIG_HOME"]) ?? "\(home)/.config")/\(HarnessProduct.commandName)/policy.yaml"
        #endif
    }

    /// Where the product keeps its logs, flow results and build logs: `~/Library/Logs` on macOS,
    /// `$XDG_STATE_HOME` on Linux.
    public static func logsDirectory(
        home: String = homeDirectory, environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        #if os(macOS)
        "\(home)/Library/Logs/\(HarnessProduct.commandName)"
        #else
        "\(absolute(environment["XDG_STATE_HOME"]) ?? "\(home)/.local/state")/\(HarnessProduct.commandName)"
        #endif
    }

    /// Where the helper writes its journal, one JSON Lines file per agent session.
    public static func journalDirectory(
        for variant: HarnessVariant, home: String = homeDirectory,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        "\(logsDirectory(home: home, environment: environment))/\(variant == .dev ? "journal-dev" : "journal")"
    }

    /// An XDG base directory value, ignored unless it is an absolute path as the specification requires.
    static func absolute(_ path: String?) -> String? {
        guard let path, path.hasPrefix("/") else { return nil }
        return path
    }
}
