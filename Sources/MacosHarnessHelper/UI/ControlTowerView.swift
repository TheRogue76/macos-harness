import HarnessCore
import SwiftUI

/// Things the panel asks the app to do.
struct TowerActions {
    var openSetup: () -> Void
    var editPolicy: () -> Void
    var showJournal: () -> Void
    var restart: () -> Void
    var quit: () -> Void
}

/// The menu bar panel: who's driving what, permissions, recent activity, and the big stop button.
/// While a pairing request waits, it shows that instead.
struct ControlTowerView: View {
    @ObservedObject var activity: ActivityCenter
    @ObservedObject var pairing: PairingCoordinator
    @ObservedObject var permissions: PermissionsModel
    @ObservedObject var settings: HelperSettings
    var title: String
    var actions: TowerActions

    var body: some View {
        Group {
            if let request = pairing.pending.first {
                PairingView(request: request, othersWaiting: pairing.pending.count - 1) { decision in
                    pairing.resolve(request.id, decision)
                }
            } else {
                dashboard
            }
        }
        .padding(16)
        .frame(width: 400)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var dashboard: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            sessionList
            readiness
            recentList
            stopButton
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            AppMark()
            Text(title).font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 8)
            statusPill
            settingsMenu
        }
        .frame(height: 28)
    }

    private var settingsMenu: some View {
        Menu {
            Button("Set Up Permissions…", action: actions.openSetup)
            Menu("Paired Agents") {
                if pairing.paired.isEmpty {
                    Text("None yet")
                }
                ForEach(pairing.paired, id: \.key) { agent in
                    Button("Revoke \(agent.displayName)") { pairing.revoke(key: agent.key) }
                }
            }
            Toggle("Show Activity on Screen", isOn: $settings.showActivityOnScreen)
            Divider()
            Button("Edit Policy…", action: actions.editPolicy)
            Button("Show Journal", action: actions.showJournal)
            Divider()
            Button("Restart Helper", action: actions.restart)
            Button("Quit \(title)", action: actions.quit)
        } label: {
            IconButtonFace(systemName: "gearshape")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Settings")
        .help("Settings")
    }

    @ViewBuilder private var statusPill: some View {
        if activity.allStopped {
            pill("Stopped", accent: true)
        } else if !activity.sessions.isEmpty {
            pill("\(activity.sessions.count) driving", accent: true)
        } else {
            pill("Idle", accent: false)
        }
    }

    private func pill(_ text: String, accent: Bool) -> some View {
        HStack(spacing: 6) {
            if accent {
                Dot(color: Theme.accent, size: 6)
            }
            Text(text)
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(accent ? Theme.accentText : Theme.textSecondary)
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(Capsule().fill(accent ? Theme.accentTint : Theme.chip))
    }

    @ViewBuilder private var sessionList: some View {
        let idleStopped = activity.stoppedAgents
            .filter { key, _ in !activity.sessions.contains { $0.agentKey == key } }
            .sorted { $0.value < $1.value }
        if activity.sessions.isEmpty && idleStopped.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("No agent is working right now").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Text("Agents connect through the macos-harness command. Their sessions show up here as they work.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
        }
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 8) {
                ForEach(activity.sessions) { session in
                    SessionCard(
                        session: session,
                        thumbnail: session.lastWindowID.flatMap { activity.thumbnails[$0] },
                        stopped: activity.isStopped(session.agentKey),
                        now: context.date
                    ) {
                        if activity.isStopped(session.agentKey) {
                            activity.resume(key: session.agentKey)
                        } else {
                            activity.stop(key: session.agentKey, name: session.agentName)
                        }
                    }
                }
            }
        }
        ForEach(idleStopped, id: \.key) { key, name in
            HStack {
                Dot(color: Theme.accent)
                Text("\(name) is stopped").foregroundStyle(Theme.textPrimary)
                Spacer()
                Button("Resume") { activity.resume(key: key) }.buttonStyle(.tower(.outline))
            }
            .font(.system(size: 13))
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
        }
    }

    @ViewBuilder private var readiness: some View {
        HStack(spacing: 8) {
            if permissions.screenRecording && permissions.accessibility {
                Dot(color: Theme.success)
                Text("Screen Recording and Accessibility are on").foregroundStyle(Theme.textSecondary).lineLimit(1)
            } else {
                permissionChip("Screen Recording", granted: permissions.screenRecording)
                permissionChip("Accessibility", granted: permissions.accessibility)
            }
            Spacer(minLength: 8)
            Text(pairedText).foregroundStyle(Theme.textMuted).lineLimit(1)
        }
        .font(.system(size: 12))
    }

    private var pairedText: String {
        switch pairing.paired.count {
        case 0: "No agents paired"
        case 1: "1 agent paired"
        case let count: "\(count) agents paired"
        }
    }

    private func permissionChip(_ name: String, granted: Bool) -> some View {
        Button(action: actions.openSetup) {
            Chip {
                Dot(color: granted ? Theme.success : Theme.accent)
                Text(name)
            }
        }
        .buttonStyle(.plain)
        .help(granted ? "\(name) is granted" : "\(name) is missing; click to set it up")
    }

    private var recentList: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "Recent")
            if activity.recent.isEmpty {
                Text("Nothing yet").font(.system(size: 12)).foregroundStyle(Theme.textMuted)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 5) {
                    ForEach(activity.recent.prefix(5)) { entry in
                        GridRow {
                            Text(entry.date, format: .dateTime.hour().minute())
                                .monospacedDigit()
                                .foregroundStyle(Theme.textMuted)
                                .frame(width: 40, alignment: .leading)
                            Text(entry.agentName).foregroundStyle(Theme.textSecondary).lineLimit(1)
                                .frame(width: 88, alignment: .leading)
                            Text(entry.shortSummary)
                                .foregroundStyle(entry.failed ? Theme.accentText : Theme.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                }
                .font(.system(size: 12))
            }
        }
        .padding(.top, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Rectangle().fill(Theme.divider).frame(height: 1) }
    }

    @ViewBuilder private var stopButton: some View {
        if activity.allStopped {
            Button { activity.resumeAll() } label: {
                Text("Resume all agents").frame(maxWidth: .infinity)
            }
            .buttonStyle(.tower(.primary, height: 36))
        } else {
            Button { activity.stopAll() } label: {
                HStack(spacing: 10) {
                    Text("Stop all agents")
                    Text("⌃⌥⌘.").fontWeight(.medium).opacity(0.85)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.tower(.accent, height: 36))
        }
    }
}

private struct SessionCard: View {
    var session: AgentSession
    var thumbnail: NSImage?
    var stopped: Bool
    var now: Date
    var toggle: () -> Void

    /// Whether the agent acted in the last 10 seconds and isn't stopped.
    private var live: Bool { now.timeIntervalSince(session.lastActivity) < 10 && !stopped }

    var body: some View {
        HStack(spacing: 12) {
            preview
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(session.agentName).font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.textPrimary)
                    if let app = session.lastApp {
                        Text("in \(app)").foregroundStyle(Theme.textSecondary).lineLimit(1)
                    }
                }
                Text(stopped ? "stopped by you" : session.last.shortSummary)
                    .foregroundStyle(stopped ? Theme.accentText : Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 6) {
                    if live {
                        Dot(color: Theme.accent, size: 6)
                    }
                    Text("\(sessionAge(of: session.lastActivity, now: now, live: live)) · step \(session.steps) · \(elapsedText(since: session.startedAt, now: now))")
                }
                .font(.system(size: 12))
                .foregroundStyle(Theme.textMuted)
            }
            .font(.system(size: 13))
            Spacer(minLength: 0)
            Button(stopped ? "Resume" : "Stop", action: toggle).buttonStyle(.tower(.outline))
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
    }

    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.inset)
            if let thumbnail {
                Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fit).padding(3)
            } else {
                Image(systemName: "macwindow").font(.system(size: 20)).foregroundStyle(Theme.textMuted)
            }
        }
        .frame(width: 84, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(live ? Theme.accent : Theme.border, lineWidth: live ? 2 : 1)
        )
    }
}

/// How long ago an agent last acted: "now" while it's live, else "38 s ago" or "4 min ago".
func sessionAge(of last: Date, now: Date, live: Bool) -> String {
    if live { return "now" }
    let seconds = max(0, Int(now.timeIntervalSince(last)))
    return seconds < 60 ? "\(seconds) s ago" : "\(seconds / 60) min ago"
}
