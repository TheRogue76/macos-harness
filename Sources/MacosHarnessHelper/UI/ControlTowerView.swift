import HarnessCore
import SwiftUI

/// Things the panel asks the app to do.
struct TowerActions {
    var openSetup: () -> Void
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
        .padding(14)
        .frame(width: 400)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var dashboard: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            sessionList
            permissionChips
            recentList
            stopButton
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.textPrimary)
            Spacer()
            statusPill
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
                Button("Restart Helper", action: actions.restart)
                Button("Quit \(title)", action: actions.quit)
            } label: {
                Image(systemName: "gearshape").font(.system(size: 14))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 28, height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.chip))
            .accessibilityLabel("Settings")
        }
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
        let foreground: Color = accent ? Theme.accentText : Theme.textSecondary
        let fill: Color = accent ? Theme.accentTint : Theme.chip
        return Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(fill))
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
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.card))
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
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.card))
        }
    }

    private var permissionChips: some View {
        HStack(spacing: 8) {
            permissionChip("Screen Recording", granted: permissions.screenRecording)
            permissionChip("Accessibility", granted: permissions.accessibility)
            Chip { Text("\(pairing.paired.count) agent\(pairing.paired.count == 1 ? "" : "s") paired") }
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
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                    ForEach(activity.recent.prefix(5)) { entry in
                        GridRow {
                            Text(entry.date, format: .dateTime.hour().minute())
                                .monospacedDigit()
                                .foregroundStyle(Theme.textMuted)
                            Text(entry.agentName).foregroundStyle(Theme.textSecondary).lineLimit(1)
                            Text(entry.summary)
                                .foregroundStyle(entry.failed ? Theme.accentText : Theme.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                }
                .font(.system(size: 12))
            }
        }
    }

    @ViewBuilder private var stopButton: some View {
        if activity.allStopped {
            Button { activity.resumeAll() } label: {
                Text("Resume all agents").frame(maxWidth: .infinity)
            }
            .buttonStyle(.tower(.primary, height: 34))
        } else {
            Button { activity.stopAll() } label: {
                HStack(spacing: 10) {
                    Text("Stop all agents")
                    Text("⌃⌥⌘.").fontWeight(.medium).opacity(0.85)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.tower(.accent, height: 34))
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
                        Text("→ \(app)").foregroundStyle(Theme.textSecondary).lineLimit(1)
                    }
                }
                Text(stopped ? "stopped by you" : session.last.summary)
                    .foregroundStyle(stopped ? Theme.accentText : Theme.textPrimary)
                    .lineLimit(1)
                Text("step \(session.steps) · \(elapsedText(since: session.startedAt, now: now)) · \(session.last.kind)")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
            }
            .font(.system(size: 13))
            Spacer(minLength: 0)
            Button(stopped ? "Resume" : "Stop", action: toggle).buttonStyle(.tower(.outline))
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.card))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(live ? Theme.accent.opacity(0.45) : .clear, lineWidth: 1)
        )
    }

    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.inset)
            if let thumbnail {
                Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fit).padding(3)
            } else {
                Image(systemName: "macwindow").font(.system(size: 20)).foregroundStyle(Theme.textMuted)
            }
        }
        .frame(width: 84, height: 58)
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
    }
}
