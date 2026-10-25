import Foundation
import HarnessCore
import HarnessProtocol

/// The launch arguments a `launch` passes: the caller's, the appearance, language and locale
/// presets, and the flag that keeps Chromium apps working when other windows cover them.
enum LaunchArguments {
    /// The Chromium switch that stops a covered window from being throttled.
    static let keepAwake = "--disable-backgrounding-occluded-windows"

    /// The arguments that set the appearance, language and locale for this app only.
    static func presets(_ params: LaunchMethod.Params) throws -> [String] {
        var arguments: [String] = []
        if let appearance = params.appearance {
            switch appearance.lowercased() {
            case "dark": arguments += ["-AppleInterfaceStyle", "Dark", "-NSRequiresAquaSystemAppearance", "NO"]
            case "light": arguments += ["-NSRequiresAquaSystemAppearance", "YES"]
            default: throw RPCError(code: RPCErrorCode.invalidParams, message: "appearance is light or dark, not \(appearance).")
            }
        }
        if let language = try code(params.language, named: "language") {
            arguments += ["-AppleLanguages", "(\(language))"]
        }
        if let locale = try code(params.locale, named: "locale") {
            arguments += ["-AppleLocale", locale]
        }
        return arguments
    }

    /// Every argument for a fresh launch of an app built on `engine` (nil for other apps).
    static func all(_ params: LaunchMethod.Params, engine: HiddenTrees.Engine?) throws -> [String] {
        var arguments = params.arguments + (try presets(params))
        if engine != nil, params.allowIdleWhenCovered != true, !arguments.contains(keepAwake) {
            arguments.append(keepAwake)
        }
        return arguments
    }

    /// A language or locale code, checked to be letters, digits, `-` and `_` only.
    static func code(_ value: String?, named name: String) throws -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        guard value.range(of: "^[A-Za-z]{2,3}([-_][A-Za-z0-9]{2,8})*$", options: .regularExpression) != nil else {
            throw RPCError(code: RPCErrorCode.invalidParams, message: "\(name) is a code such as fr, pt-BR or fr_FR, not \(value).")
        }
        return value
    }
}
