import Foundation
import HarnessProtocol

/// Where the helper app is and which socket it listens on.
public struct HelperLocation: Sendable, Equatable {
    public var variant: HarnessVariant
    public var appURL: URL?
    public var socketPath: String

    public init(variant: HarnessVariant, appURL: URL?, socketPath: String) {
        self.variant = variant
        self.appURL = appURL
        self.socketPath = socketPath
    }
}

public enum HelperLocator {
    /// Finds the helper the CLI belongs to. On macOS: the .app named by `MACOS_HARNESS_APP`, then
    /// the .app this executable lives in, then the usual install locations, dev build first. On
    /// Linux: the helper binary named by `MACOS_HARNESS_APP`, then `macos-harness-helper` next to
    /// this executable or in `../libexec/macos-harness`, or else just the socket when it exists
    /// (systemd starts the helper on the first connection).
    public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment) -> HelperLocation? {
        #if os(Linux)
        return locateLinux(environment: environment, executable: executableURL())
        #else
        var candidates: [URL] = []
        if let override = environment["MACOS_HARNESS_APP"] {
            candidates.append(URL(fileURLWithPath: override))
        }
        if let enclosing = enclosingAppBundle(of: executableURL()) {
            candidates.append(enclosing)
        }
        let home = HarnessPaths.homeDirectory
        for variant in [HarnessVariant.dev, .release] {
            candidates.append(URL(fileURLWithPath: "\(home)/Applications/\(variant.appName).app"))
            candidates.append(URL(fileURLWithPath: "/Applications/\(variant.appName).app"))
        }
        for url in candidates {
            if let identifier = Bundle(url: url)?.bundleIdentifier,
               let variant = HarnessVariant(bundleIdentifier: identifier) {
                return HelperLocation(variant: variant, appURL: url, socketPath: HarnessPaths.socketPath(for: variant))
            }
        }
        return nil
        #endif
    }

    /// The Linux helper binary and the variant it runs as: dev when this CLI's name ends in
    /// `-dev` or `MACOS_HARNESS_VARIANT` says so.
    static func locateLinux(
        environment: [String: String], executable: URL, socketExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> HelperLocation? {
        let isDev = environment["MACOS_HARNESS_VARIANT"] == HarnessVariant.dev.rawValue || executable.lastPathComponent.hasSuffix("-dev")
        let variant: HarnessVariant = isDev ? .dev : .release
        let directory = executable.deletingLastPathComponent()
        var candidates: [URL] = []
        if let override = environment["MACOS_HARNESS_APP"] {
            candidates.append(URL(fileURLWithPath: override))
        }
        candidates.append(directory.appendingPathComponent("macos-harness-helper"))
        candidates.append(directory.deletingLastPathComponent().appendingPathComponent("libexec/macos-harness/macos-harness-helper"))
        let socketPath = HarnessPaths.socketPath(for: variant, environment: environment)
        guard let helper = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            return socketExists(socketPath) ? HelperLocation(variant: variant, appURL: nil, socketPath: socketPath) : nil
        }
        return HelperLocation(variant: variant, appURL: helper, socketPath: socketPath)
    }

    static func executableURL() -> URL {
        #if os(macOS)
        var size: UInt32 = 0
        unsafe _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard unsafe _NSGetExecutablePath(&buffer, &size) == 0 else {
            return URL(fileURLWithPath: CommandLine.arguments[0])
        }
        return URL(fileURLWithPath: String(nulTerminated: buffer)).resolvingSymlinksInPath()
        #else
        guard let path = try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe") else {
            return URL(fileURLWithPath: CommandLine.arguments[0])
        }
        return URL(fileURLWithPath: path)
        #endif
    }

    static func enclosingAppBundle(of url: URL) -> URL? {
        var current = url
        while current.path != "/" {
            if current.pathExtension == "app" { return current }
            current.deleteLastPathComponent()
        }
        return nil
    }
}
