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
        case .dev: "\(HarnessProduct.displayName) Dev"
        case .release: HarnessProduct.displayName
        }
    }

    /// The CLI that talks to this variant's helper.
    public var commandName: String {
        switch self {
        case .dev: "\(HarnessProduct.commandName)-dev"
        case .release: HarnessProduct.commandName
        }
    }

    /// The app ID this variant's helper, panel and autostart entry go by on Linux.
    public var linuxAppID: String {
        switch self {
        case .dev: "\(HarnessProduct.linuxAppID)Dev"
        case .release: HarnessProduct.linuxAppID
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
    /// The product's name as people read it, in messages, titles and menus.
    public static let displayName = "macOS Harness"

    /// The command-line tool's name, also the stem of the product's temporary files.
    public static let commandName = "macos-harness"

    /// The helper executable's name, next to the CLI or inside the Mac app.
    public static let helperName = "\(commandName)-helper"

    /// The Linux Control Tower executable's name, next to the helper.
    public static let towerName = "\(commandName)-tower"

    /// The name of the product's folders (Application Support, Logs, `~/.config`, `$XDG_RUNTIME_DIR`,
    /// `~/.local/state`), the socket directory among them.
    public static let folderName = "otto"

    /// The folders' name before 2.0, which the helper moves to `folderName` when it starts.
    public static let legacyFolderName = "macos-harness"

    /// The name of the packages, the repository and the Homebrew cask.
    public static let packageName = "macos-harness"

    /// The name `setup` registers the MCP server under in each agent host, and the server reports.
    public static let mcpServerName = "macos-harness"

    /// The prefix of every environment variable the product reads or sets.
    public static let environmentPrefix = "OTTO_"

    /// The prefix before 2.0, still read when the variable with `environmentPrefix` isn't set.
    public static let legacyEnvironmentPrefix = "MACOS_HARNESS_"

    /// The product's environment variable called `name` after the prefix.
    public static func environmentVariable(_ name: String) -> String {
        environmentPrefix + name
    }

    /// The value of the product's variable called `name` after the prefix, or else of its name
    /// before 2.0.
    public static func environmentValue(
        _ name: String, in environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        environment[environmentPrefix + name] ?? environment[legacyEnvironmentPrefix + name]
    }

    /// The stem of the product's Linux app IDs and D-Bus names; variants and parts add to it.
    public static let linuxAppID = "io.github.therogue76.MacosHarness"

    /// The D-Bus object path matching `linuxAppID`.
    public static let linuxObjectPath = "/io/github/therogue76/MacosHarness"

    /// The stem of the product's icon names in the Linux icon theme.
    public static let linuxIconName = "macos-harness"

    /// The GNOME Shell extension's UUID.
    public static let gnomeExtensionUUID = "macos-harness@therogue76.github.io"

    /// The D-Bus name and interface the GNOME Shell extension serves.
    public static let gnomeExtensionBusName = "org.gnome.Shell.Extensions.MacosHarness"

    /// The D-Bus object path the GNOME Shell extension serves.
    public static let gnomeExtensionObjectPath = "/org/gnome/Shell/Extensions/MacosHarness"
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
        let name = HarnessProduct.folderName
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
        "\(configDirectory(home: home, environment: environment))/\(HarnessProduct.folderName)/policy.yaml"
    }

    /// The policy file's path before 2.0, read while there's no file at `policyFile`.
    public static func legacyPolicyFile(
        home: String = homeDirectory, environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        "\(configDirectory(home: home, environment: environment))/\(HarnessProduct.legacyFolderName)/policy.yaml"
    }

    /// Where the product keeps its logs, flow results and build logs: `~/Library/Logs` on macOS,
    /// `$XDG_STATE_HOME` on Linux.
    public static func logsDirectory(
        home: String = homeDirectory, environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        "\(logsParent(home: home, environment: environment))/\(HarnessProduct.folderName)"
    }

    /// Where the helper writes its journal, one JSON Lines file per agent session.
    public static func journalDirectory(
        for variant: HarnessVariant, home: String = homeDirectory,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        "\(logsDirectory(home: home, environment: environment))/\(variant == .dev ? "journal-dev" : "journal")"
    }

    /// Moves each of the product's folders from its name before 2.0 to its new one when the old
    /// folder exists and the new one doesn't, and otherwise leaves the old folder where it is. Safe
    /// to call on every start; returns the folders it moved.
    @discardableResult
    public static func migrateLegacyFolders(
        home: String = homeDirectory, environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> [(from: String, to: String)] {
        var moved: [(from: String, to: String)] = []
        for parent in folderParents(home: home, environment: environment) {
            let old = "\(parent)/\(HarnessProduct.legacyFolderName)"
            let new = "\(parent)/\(HarnessProduct.folderName)"
            guard fileManager.fileExists(atPath: old), !fileManager.fileExists(atPath: new) else { continue }
            if (try? fileManager.moveItem(atPath: old, toPath: new)) != nil {
                moved.append((old, new))
            }
        }
        return moved
    }

    /// The folders that hold one of the product's folders worth keeping: the policy's and the
    /// logs'. The ones holding sockets (Application Support, `$XDG_RUNTIME_DIR`) aren't moved, so a
    /// 1.x helper still running keeps its socket, and the new helper makes its own.
    static func folderParents(home: String, environment: [String: String]) -> [String] {
        [configDirectory(home: home, environment: environment), logsParent(home: home, environment: environment)]
    }

    /// The folder that holds the policy's folder: `~/.config`, or `$XDG_CONFIG_HOME` on Linux.
    static func configDirectory(home: String, environment: [String: String]) -> String {
        #if os(macOS)
        "\(home)/.config"
        #else
        absolute(environment["XDG_CONFIG_HOME"]) ?? "\(home)/.config"
        #endif
    }

    /// The folder that holds the logs folder: `~/Library/Logs`, or `$XDG_STATE_HOME` on Linux.
    static func logsParent(home: String, environment: [String: String]) -> String {
        #if os(macOS)
        "\(home)/Library/Logs"
        #else
        absolute(environment["XDG_STATE_HOME"]) ?? "\(home)/.local/state"
        #endif
    }

    /// An XDG base directory value, ignored unless it is an absolute path as the specification requires.
    static func absolute(_ path: String?) -> String? {
        guard let path, path.hasPrefix("/") else { return nil }
        return path
    }
}
