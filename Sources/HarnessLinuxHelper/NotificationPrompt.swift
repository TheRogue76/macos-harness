import Foundation
import HarnessCore
import HarnessHelperCore
import HarnessLinux
import HarnessProtocol

/// Asks the user to pair an agent through a desktop notification with Allow, This session and
/// Deny buttons.
struct NotificationPrompt: Sendable {
    let appName: String

    /// What a notification shows: its title, body and buttons.
    struct Content: Equatable {
        var title: String
        var body: String
        var actions: [DesktopNotifications.Action]
    }

    /// The user's answer, or deny when the notification is dismissed or times out.
    func ask(_ caller: CallerIdentity, timeout: Double) async -> PairingCoordinator.Decision {
        let content = pairing(for: caller)
        let choice = await DesktopNotifications.ask(
            appName: appName, title: content.title, body: content.body, actions: content.actions, critical: true, timeout: .seconds(timeout)
        )
        return Self.decision(for: choice)
    }

    func pairing(for caller: CallerIdentity) -> Content {
        let chain = caller.chain.map(\.name).joined(separator: " ← ")
        let folder = caller.workingDirectory.map { "\nWorking in \($0)" } ?? ""
        return Content(
            title: "Allow \(caller.displayName) to use \(appName)?",
            body: "It wants to see and operate your apps and devices.\n\(chain)\(folder)",
            actions: [.init("allow", "Allow"), .init("session", "This session"), .init("deny", "Deny")]
        )
    }

    /// Offers to set up a permission an agent needed; true when the user chose Set up.
    func offerSetup(_ item: PermissionsMethod.Item) async -> Bool {
        let content = setup(for: item)
        let choice = await DesktopNotifications.ask(appName: appName, title: content.title, body: content.body, actions: content.actions, timeout: .seconds(60))
        return choice == "setup"
    }

    func setup(for item: PermissionsMethod.Item) -> Content {
        Content(title: "\(appName) needs a permission: \(item.name)", body: item.detail, actions: [.init("setup", "Set up")])
    }

    /// Says how setting up went.
    func tell(_ title: String, _ body: String) async {
        await DesktopNotifications.tell(appName: appName, title: title, body: body)
    }

    /// The decision for the button chosen, if any.
    static func decision(for choice: String?) -> PairingCoordinator.Decision {
        switch choice {
        case "allow": .allow
        case "session": .session
        default: .deny
        }
    }
}
