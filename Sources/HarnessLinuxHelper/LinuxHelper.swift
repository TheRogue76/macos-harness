import Foundation
import HarnessCore
import HarnessHelperCore
import HarnessLinux
import HarnessProtocol

/// The headless Linux helper: serves the socket, asks the user to pair agents through a desktop
/// notification, and drives Android devices. Linux desktop apps aren't supported yet.
@MainActor
final class LinuxHelper {
    let variant: HarnessVariant
    let activity: ActivityCenter
    let pairing: PairingCoordinator
    let policy = PolicyStore()
    let journal: Journal
    let prompt: NotificationPrompt?
    let server: SocketServer

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        variant = environment["MACOS_HARNESS_VARIANT"] == HarnessVariant.dev.rawValue ? .dev : .release
        let defaults = UserDefaults(suiteName: variant.bundleIdentifier) ?? .standard
        let unattended = environment["MACOS_HARNESS_LAUNCH"] == "child" && environment["MACOS_HARNESS_AUTO_APPROVE"] == "1"
        activity = ActivityCenter(defaults: defaults)
        pairing = PairingCoordinator(store: PairingStore(defaults: defaults), approvesEveryone: unattended)
        journal = Journal(directory: HarnessPaths.journalDirectory(for: variant))
        prompt = NotificationPrompt.find(appName: variant.appName)
        let router = Router(gate: pairing, observer: HelperObserver(activity: activity, policy: policy, journal: journal, whereStopped: ""))
        let processes = LinuxProcesses()
        server = SocketServer(path: HarnessPaths.socketPath(for: variant), router: router) { processes.identifyPeer($0) }
        LinuxHandlers.register(on: router, helper: self)
        let pairing = pairing
        pairing.onNewRequest = { [prompt] request in
            guard let prompt else { return pairing.resolve(request.id, .deny) }
            Task { @MainActor in
                let decision = await prompt.ask(request.caller, timeout: PairingCoordinator.approvalTimeout)
                pairing.resolve(request.id, decision)
            }
        }
    }

    func start() throws {
        try server.start()
        Task { await journal.prune() }
    }

    /// The session, desktop and distribution `doctor` reports.
    func linuxStatus(environment: [String: String] = ProcessInfo.processInfo.environment) -> DoctorMethod.LinuxStatus {
        DoctorMethod.LinuxStatus(
            session: environment["XDG_SESSION_TYPE"], desktop: environment["XDG_CURRENT_DESKTOP"],
            distribution: Self.distribution(), pairingPrompt: prompt == nil ? nil : "desktop notifications"
        )
    }

    /// The distribution's pretty name from os-release, e.g. "Ubuntu 26.04.1 LTS".
    nonisolated static func distribution(osRelease path: String = "/etc/os-release") -> String? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") where line.hasPrefix("PRETTY_NAME=") {
            return String(line.dropFirst("PRETTY_NAME=".count)).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return nil
    }
}
