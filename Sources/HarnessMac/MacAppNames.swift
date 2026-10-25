import AppKit
import Foundation
import HarnessCore
import HarnessProtocol

extension PolicyStore {
    /// A store for the policy file that knows apps by their name and bundle ID, running or installed.
    public static func mac(path: String = HarnessPaths.policyFile()) -> PolicyStore {
        PolicyStore(path: path, appNames: MacAppNames.names)
    }
}

/// How the policy names a Mac app.
enum MacAppNames {
    /// The app's name and bundle ID, plus the query, whether it's running or only installed.
    @Sendable static func names(_ query: String) async -> [String?] {
        if let app = try? await MainActor.run(body: { try AppResolver.resolve(query) }) {
            return [app.name, app.bundleIdentifier, query]
        }
        if let url = await MainActor.run(body: { AppControl.appURL(for: query) }), let bundle = Bundle(url: url) {
            let name = (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? url.deletingPathExtension().lastPathComponent
            return [name, bundle.bundleIdentifier, query]
        }
        return [query]
    }
}
