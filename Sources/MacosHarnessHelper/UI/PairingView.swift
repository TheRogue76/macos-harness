import HarnessCore
import SwiftUI

/// "New agent wants access": who it is, who signed it, what it can do, where it came from.
struct PairingView: View {
    var request: PairingCoordinator.Request
    var othersWaiting: Int
    var decide: (PairingCoordinator.Decision) -> Void

    private var caller: CallerIdentity { request.caller }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("NEW AGENT WANTS ACCESS")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Theme.accentText)

            HStack(spacing: 12) {
                Monogram(name: caller.displayName)
                VStack(alignment: .leading, spacing: 3) {
                    Text(caller.displayName).font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.textPrimary)
                    signature
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Once allowed, it can").font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                capability("eye", "See the windows it works in, one at a time")
                capability("list.bullet.rectangle", "Read buttons, text and menus")
                capability("cursorarrow.click", "Press, type and choose menu items")
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.card))

            VStack(alignment: .leading, spacing: 6) {
                Text("Started from").font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                startedFrom
            }

            HStack(spacing: 8) {
                Button { decide(.deny) } label: { Text("Deny").padding(.horizontal, 6) }
                    .buttonStyle(.tower(.outline, height: 34))
                    .fixedSize()
                Button { decide(.session) } label: { Text("This session only").lineLimit(1) }
                    .buttonStyle(.tower(.outline, height: 34))
                    .fixedSize()
                    .help("Allowed until \(caller.agentProcess?.name ?? "this agent") quits")
                Button { decide(.allow) } label: { Text("Allow").frame(maxWidth: .infinity) }
                    .buttonStyle(.tower(.primary, height: 34))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 2)

            Text(othersWaiting > 0
                 ? "\(othersWaiting) more waiting after this one."
                 : "Revoke any time from the gear menu. Pairing is a consent step; macOS permissions are the real lock.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var signature: some View {
        let agent = caller.agentProcess
        if let team = agent?.teamIdentifier {
            label("checkmark.shield", Theme.success, "Signed by \(agent?.signer ?? "a developer") · team \(team)")
        } else if agent?.signer == "Apple" {
            label("checkmark.shield", Theme.success, "Signed by Apple")
        } else {
            label("exclamationmark.shield", Theme.accent, "Not signed by a developer; recognized by its path")
        }
    }

    private func label(_ symbol: String, _ color: Color, _ text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text).foregroundStyle(Theme.textSecondary).lineLimit(1)
        }
        .font(.system(size: 12))
    }

    private func capability(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).frame(width: 18).foregroundStyle(Theme.textSecondary)
            Text(text).foregroundStyle(Theme.textPrimary)
        }
        .font(.system(size: 13))
    }

    /// Outermost process first, ending with the command that asked.
    private var startedFrom: some View {
        let ancestors = caller.chain.dropFirst().reversed().suffix(4).map(\.name)
        return FlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(Array(ancestors.enumerated()), id: \.offset) { _, name in
                HStack(spacing: 6) {
                    Chip { Text(name) }
                    Text("›").foregroundStyle(Theme.textMuted).font(.system(size: 12))
                }
            }
            Chip(mono: true) { Text(caller.command).lineLimit(1) }
        }
    }
}
