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
    /// Finds the helper the CLI belongs to: the .app named by `MACOS_HARNESS_APP`, then the .app
    /// this executable lives in, then the usual install locations, dev build first.
    public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment) -> HelperLocation? {
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
