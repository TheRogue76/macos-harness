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
    let prompt: NotificationPrompt
    let server: SocketServer
    private var tray: TrayController?
    private var offered: [String: Date] = [:]

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        variant = environment["MACOS_HARNESS_VARIANT"] == HarnessVariant.dev.rawValue ? .dev : .release
        let defaults = UserDefaults(suiteName: variant.bundleIdentifier) ?? .standard
        let unattended = environment["MACOS_HARNESS_LAUNCH"] == "child" && environment["MACOS_HARNESS_AUTO_APPROVE"] == "1"
        activity = ActivityCenter(defaults: defaults)
        pairing = PairingCoordinator(store: PairingStore(defaults: defaults), approvesEveryone: unattended)
        journal = Journal(directory: HarnessPaths.journalDirectory(for: variant))
        prompt = NotificationPrompt(appName: variant.appName)
        let router = Router(gate: pairing, observer: HelperObserver(activity: activity, policy: policy, journal: journal, whereStopped: ""))
        let processes = LinuxProcesses()
        server = SocketServer(path: HarnessPaths.socketPath(for: variant), router: router) { processes.identifyPeer($0) }
        LinuxHandlers.register(on: router, helper: self)
        let pairing = pairing
        pairing.onNewRequest = { [prompt] request in
            Task { @MainActor in
                let decision = await prompt.ask(request.caller, timeout: PairingCoordinator.approvalTimeout)
                pairing.resolve(request.id, decision)
            }
        }
        LinuxPermissions.onMissing { [weak self] item in
            Task { @MainActor in await self?.offerSetup(item) }
        }
    }

    /// Stops every agent when the user presses the stop shortcut, and says how to resume.
    func stopFromShortcut() async {
        activity.stopAll()
        await prompt.tell("Stopped every agent", "Run `\(variant.commandName) resume` to let them act again.")
    }

    /// Offers through a notification to set up a permission an agent needed, at most every ten
    /// minutes for each, and runs `permissions grant` when the user chooses Set up.
    func offerSetup(_ item: PermissionsMethod.Item) async {
        guard item.state == .missing else { return }
        if let last = offered[item.id], Date().timeIntervalSince(last) < 600 { return }
        offered[item.id] = Date()
        guard await prompt.offerSetup(item) else { return }
        do {
            let result = try await LinuxPermissions.run(.init(action: .grant))
            let missing = result.items.filter { $0.state == .missing }.map(\.name)
            let body = (result.notices + (missing.isEmpty ? [] : ["Still missing: \(missing.joined(separator: ", "))."])).joined(separator: " ")
            await prompt.tell(missing.isEmpty ? "\(variant.appName) is set up" : "\(variant.appName) isn't fully set up", body.isEmpty ? "Agents can use your apps now." : body)
        } catch {
            await prompt.tell("\(variant.appName) isn't set up", (error as? RPCError)?.message ?? "\(error)")
        }
    }

    func start() throws {
        ScreenImagingProvider.use(LinuxScreenImaging())
        if let activated = SocketServer.activatedSocket() {
            server.start(adopting: activated)
        } else {
            try server.start()
        }
        Task { await journal.prune() }
        let tray = TrayController(helper: self)
        self.tray = tray
        let appID = "io.github.therogue76.MacosHarness\(variant == .dev ? "Dev" : "")"
        let appName = variant.appName
        let folder = URL(fileURLWithPath: CommandLine.arguments.first ?? "").resolvingSymlinksInPath().deletingLastPathComponent().path
        let besideHelper = "\(folder)/\(variant.commandName)"
        let command = FileManager.default.isExecutableFile(atPath: besideHelper) ? besideHelper : variant.commandName
        Task { [weak self] in
            await LinuxShortcuts.shared.configure(appID: appID, appName: appName, command: command)
            await LinuxShortcuts.shared.start {
                Task { @MainActor in await self?.stopFromShortcut() }
            }
            await tray.start()
        }
    }

    /// The session, desktop and distribution `doctor` reports.
    func linuxStatus(environment: [String: String] = ProcessInfo.processInfo.environment) -> DoctorMethod.LinuxStatus {
        DoctorMethod.LinuxStatus(
            session: environment["XDG_SESSION_TYPE"], desktop: environment["XDG_CURRENT_DESKTOP"],
            distribution: Self.distribution(), pairingPrompt: "desktop notifications"
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
