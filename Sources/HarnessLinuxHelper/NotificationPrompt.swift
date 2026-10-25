import Foundation
import HarnessCore
import HarnessHelperCore
import HarnessProtocol

/// Asks the user to pair an agent through a desktop notification with Allow, This session and
/// Deny buttons, shown by `notify-send`.
struct NotificationPrompt: Sendable {
    let executable: String
    let appName: String

    /// The prompt, when `notify-send` is on the path.
    static func find(appName: String, path: String? = ProcessInfo.processInfo.environment["PATH"]) -> NotificationPrompt? {
        let directories = (path ?? "/usr/bin:/bin").split(separator: ":").map(String.init)
        guard let found = directories.map({ "\($0)/notify-send" }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return nil
        }
        return NotificationPrompt(executable: found, appName: appName)
    }

    /// The user's answer, or deny when the notification is dismissed or times out.
    func ask(_ caller: CallerIdentity, timeout: Double) async -> PairingCoordinator.Decision {
        let output = try? await ToolRunner.run(executable, arguments(for: caller, timeout: timeout), timeout: timeout + 5)
        return Self.decision(fromOutput: output?.text ?? "")
    }

    func arguments(for caller: CallerIdentity, timeout: Double) -> [String] {
        let chain = caller.chain.map(\.name).joined(separator: " ← ")
        let folder = caller.workingDirectory.map { "\nWorking in \($0)" } ?? ""
        return [
            "--app-name=\(appName)", "--urgency=critical", "--expire-time=\(Int(timeout * 1000))",
            "--action=allow=Allow", "--action=session=This session", "--action=deny=Deny",
            "Allow \(caller.displayName) to use \(appName)?",
            "It wants to see and operate your apps and devices.\n\(chain)\(folder)",
        ]
    }

    /// The decision for what `notify-send` printed: the chosen action's name.
    static func decision(fromOutput output: String) -> PairingCoordinator.Decision {
        switch output.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "allow": .allow
        case "session": .session
        default: .deny
        }
    }
}
