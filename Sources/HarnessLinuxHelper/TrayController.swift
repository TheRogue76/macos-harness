import Foundation
import HarnessCore
import HarnessHelperCore
import HarnessLinux
import HarnessProtocol
import Observation

/// The tray icon, as the Mac's menu bar icon: an orange dot while agents act or are stopped, a
/// pairing request waits, or a permission is missing, and a menu with the sessions, Stop all
/// and setup.
@MainActor
final class TrayController {
    let helper: LinuxHelper
    private var icon: TrayIcon?
    private var permissionsMissing = false

    init(helper: LinuxHelper) {
        self.helper = helper
    }

    /// Shows the icon and keeps it current; does nothing where no panel shows tray icons.
    func start() async {
        let variant = helper.variant
        do {
            icon = try await TrayIcon.show(
                id: "macos-harness\(variant == .dev ? "-dev" : "")", title: variant.appName, look: look(),
                onAction: { [weak self] action in Task { @MainActor in self?.perform(action) } },
                onActivate: {}
            )
        } catch {
            return
        }
        observe()
        Task { [weak self] in
            while let self, self.icon != nil {
                let missing = await LinuxPermissions.status().contains { $0.state == .missing }
                if missing != self.permissionsMissing {
                    self.permissionsMissing = missing
                    self.refresh()
                }
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private func observe() {
        withObservationTracking {
            _ = look()
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.refresh()
                self?.observe()
            }
        }
    }

    func refresh() {
        icon?.update(look())
    }

    /// What the icon and its menu show now.
    func look() -> TrayIcon.Look {
        let activity = helper.activity
        let name = helper.variant.appName
        let driving = activity.sessions.count
        let state = activity.allStopped ? "Stopped" : driving == 0 ? "Idle" : "● \(driving) driving"
        var items: [TrayIcon.Item] = [TrayIcon.Item("\(name) — \(state)", enabled: false)]
        if !helper.pairing.pending.isEmpty {
            items.append(TrayIcon.Item("Waiting for you to allow \(helper.pairing.pending.map(\.caller.displayName).joined(separator: ", "))", enabled: false))
        }
        for session in activity.sessions.sorted(by: { $0.lastActivity > $1.lastActivity }) {
            let place = session.lastApp.map { " in \($0)" } ?? ""
            items.append(TrayIcon.Item("\(activity.fullName(of: session))\(place) · step \(session.steps)", enabled: false))
            items.append(TrayIcon.Item("      \(session.last.shortSummary)", enabled: false))
        }
        let idleStopped = activity.stoppedAgents.filter { key, _ in !activity.sessions.contains { $0.agentKey == key } }
        for stopped in idleStopped.values.sorted() {
            items.append(TrayIcon.Item("\(stopped) · stopped", enabled: false))
        }
        items.append(.separatorLine)
        if activity.allStopped || !activity.stoppedAgents.isEmpty {
            items.append(TrayIcon.Item("Resume all agents", action: "resume"))
        }
        if !activity.allStopped {
            items.append(TrayIcon.Item("Stop all agents    Ctrl+Alt+Super+.", action: "stop"))
        }
        if permissionsMissing {
            items.append(TrayIcon.Item("Set up permissions…", action: "setup"))
        }
        items.append(TrayIcon.Item("Show journal", action: "journal"))
        items.append(.separatorLine)
        items.append(TrayIcon.Item("Quit \(name)", action: "quit"))
        let attention = driving > 0 || activity.allStopped || !activity.stoppedAgents.isEmpty || !helper.pairing.pending.isEmpty || permissionsMissing
        return TrayIcon.Look(tooltip: "\(name) — \(state)", attention: attention, items: items)
    }

    func perform(_ action: String) {
        switch action {
        case "stop":
            helper.activity.stopAll()
        case "resume":
            helper.activity.resumeAll()
        case "setup":
            Task {
                _ = try? await LinuxPermissions.run(.init(action: .grant))
                permissionsMissing = await LinuxPermissions.status().contains { $0.state == .missing }
                refresh()
            }
        case "journal":
            _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/xdg-open"), arguments: [helper.journal.directory])
        case "quit":
            icon?.close()
            exit(0)
        default:
            break
        }
    }
}
