import HarnessCore
import SwiftUI

/// The panel's settings page: how agents' clicks reach windows, what the helper draws on screen,
/// the recent activity list and the paired agents.
struct SettingsView: View {
    @ObservedObject var settings: HelperSettings
    @ObservedObject var activity: ActivityCenter
    @ObservedObject var pairing: PairingCoordinator
    var back: () -> Void

    /// How many paired agents the list shows before it scrolls.
    private static let visiblePairings = 5
    private static let pairingRowHeight: CGFloat = 48

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            section("Input") {
                SettingRow(
                    title: "Clicks and scrolls in the background",
                    detail: "Agents click and scroll windows without your mouse. Off, they always use the real mouse, which waits until you're idle and brings the app to the front.",
                    isOn: $settings.backgroundRoute
                )
            }
            section("On screen", note: "These change only what you see; agents can do the same things, and ⌃⌥⌘. still stops them.") {
                SettingRow(title: "Window outline", detail: "An orange ring and tab on the window an agent acts in.", isOn: $settings.windowOutline)
                rowDivider
                SettingRow(title: "Also when agents read", detail: "Outline windows agents read or capture, too.", isOn: $settings.outlineReads)
                    .disabled(!settings.windowOutline)
                    .opacity(settings.windowOutline ? 1 : 0.5)
                rowDivider
                SettingRow(
                    title: "Driving panel and click ripple",
                    detail: "“Agent is driving” with Pause and Stop, and a ripple where it clicks.",
                    isOn: $settings.drivingPanel
                )
            }
            section("Recent activity") {
                recentRow
            }
            section("Paired agents", note: pairing.paired.isEmpty ? nil : "A revoked agent asks again the next time it acts.") {
                pairedList
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: back) {
                IconButtonFace(systemName: "chevron.left")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back")
            .help("Back")
            Text("Settings").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 8)
        }
        .frame(height: 28)
    }

    private func section<Content: View>(_ title: String, note: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: title)
            VStack(alignment: .leading, spacing: 0) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
            if let note {
                Text(note).font(.system(size: 12)).foregroundStyle(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var rowDivider: some View {
        Rectangle().fill(Theme.divider).frame(height: 1).padding(.leading, 12)
    }

    private var recentRow: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(recentCount).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Text("Clears the list in this panel; the journal keeps its own record.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Clear") { activity.clearRecent() }
                .buttonStyle(.tower(.outline))
                .disabled(activity.recent.isEmpty)
                .opacity(activity.recent.isEmpty ? 0.5 : 1)
                .accessibilityLabel("Clear recent activity")
        }
        .padding(12)
    }

    private var recentCount: String {
        switch activity.recent.count {
        case 0: "Nothing in the list"
        case 1: "1 entry in the list"
        case let count: "\(count) entries in the list"
        }
    }

    @ViewBuilder private var pairedList: some View {
        if pairing.paired.isEmpty {
            Text("No agents paired. An agent asks the first time it acts.")
                .font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                .padding(12)
        } else if pairing.paired.count > Self.visiblePairings {
            ScrollView { pairedRows }
                .frame(height: CGFloat(Self.visiblePairings) * Self.pairingRowHeight)
        } else {
            pairedRows
        }
    }

    private var pairedRows: some View {
        VStack(spacing: 0) {
            ForEach(Array(pairing.paired.enumerated()), id: \.element.key) { index, agent in
                if index > 0 { rowDivider }
                PairedAgentRow(agent: agent) { pairing.revoke(key: agent.key) }
                    .frame(height: Self.pairingRowHeight)
            }
        }
    }
}

/// A setting's name and what it does, with its switch.
private struct SettingRow: View {
    var title: String
    var detail: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Text(detail).font(.system(size: 12)).foregroundStyle(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle(isOn: $isOn) { Text(title) }
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
        .padding(12)
    }
}

/// One paired agent: its name, when the user allowed it and who signed it, and Revoke.
private struct PairedAgentRow: View {
    var agent: PairingStore.Pairing
    var revoke: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Monogram(name: agent.displayName, size: 28, fill: Theme.control)
            VStack(alignment: .leading, spacing: 1) {
                Text(agent.displayName).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Text(detail).font(.system(size: 12)).foregroundStyle(Theme.textMuted).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("Revoke", action: revoke)
                .buttonStyle(.tower(.outline))
                .accessibilityLabel("Revoke \(agent.displayName)")
        }
        .padding(.horizontal, 12)
    }

    /// "Allowed 12 Oct · team 2DC432GLL2", or "· not signed"; the year shows when it isn't this one.
    private var detail: String {
        let thisYear = Calendar.current.isDate(agent.approvedAt, equalTo: Date(), toGranularity: .year)
        let date = thisYear
            ? agent.approvedAt.formatted(.dateTime.day().month(.abbreviated))
            : agent.approvedAt.formatted(.dateTime.day().month(.abbreviated).year())
        let allowed = "Allowed \(date)"
        let parts = agent.key.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return allowed }
        return parts[1] == "unsigned" ? "\(allowed) · not signed" : "\(allowed) · team \(parts[1])"
    }
}
