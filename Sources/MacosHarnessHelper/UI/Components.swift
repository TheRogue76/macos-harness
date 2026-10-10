import SwiftUI

/// Buttons from the Control Tower design.
struct TowerButtonStyle: ButtonStyle {
    enum Kind { case outline, accent, primary }
    var kind: Kind
    var height: CGFloat = 28

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: kind == .outline ? .regular : .semibold))
            .padding(.horizontal, 12)
            .frame(minHeight: height)
            .foregroundStyle(foreground)
            .background(
                RoundedRectangle(cornerRadius: height > 30 ? 9 : 7, style: .continuous)
                    .fill(background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: height > 30 ? 9 : 7, style: .continuous)
                    .strokeBorder(kind == .outline ? Theme.border : .clear, lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Rectangle())
    }

    private var foreground: Color {
        switch kind {
        case .outline: Theme.textPrimary
        case .accent: .white
        case .primary: Theme.primaryText
        }
    }

    private var background: Color {
        switch kind {
        case .outline: .clear
        case .accent: Theme.accentStrong
        case .primary: Theme.primaryFill
        }
    }
}

extension ButtonStyle where Self == TowerButtonStyle {
    static func tower(_ kind: TowerButtonStyle.Kind, height: CGFloat = 28) -> TowerButtonStyle {
        TowerButtonStyle(kind: kind, height: height)
    }
}

/// A small rounded label: permission state, counts, process chain links.
struct Chip<Content: View>: View {
    var mono = false
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 6) { content }
            .font(.system(size: 12, design: mono ? .monospaced : .default))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.chip))
    }
}

/// The app's mark: the menu bar glyph on a filled rounded square.
struct AppMark: View {
    var size: CGFloat = 22

    var body: some View {
        Image(nsImage: Glyphs.statusItem())
            .renderingMode(.template)
            .resizable()
            .frame(width: size * 0.68, height: size * 0.68)
            .foregroundStyle(Theme.primaryText)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous).fill(Theme.primaryFill))
            .accessibilityHidden(true)
    }
}

/// A square icon button's face, with the symbol centered on its fill.
struct IconButtonFace: View {
    var systemName: String
    var side: CGFloat = 28

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(Theme.textSecondary)
            .frame(width: side, height: side)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.control))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct Dot: View {
    var color: Color
    var size: CGFloat = 7

    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
    }
}

/// An agent's initial in a rounded square.
struct Monogram: View {
    var name: String
    var size: CGFloat = 46

    var body: some View {
        Text(initial)
            .font(.system(size: size * 0.43, weight: .bold))
            .foregroundStyle(Theme.textPrimary)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).fill(Theme.chip))
    }

    private var initial: String {
        if name.lowercased() == "pi" { return "π" }
        return name.first.map { String($0).uppercased() } ?? "?"
    }
}

/// Section label like "RECENT".
struct SectionLabel: View {
    var text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(Theme.textMuted)
    }
}

/// A picture of a macOS switch, showing state (System Settings has the real one).
struct SwitchPicture: View {
    var on: Bool

    var body: some View {
        Capsule()
            .fill(on ? Theme.success : Theme.border)
            .frame(width: 38, height: 22)
            .overlay(alignment: on ? .trailing : .leading) {
                Circle().fill(.white).frame(width: 18, height: 18).padding(2)
                    .shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
            }
            .accessibilityLabel(on ? "On" : "Off")
    }
}

struct ProgressRing: View {
    var done: Int
    var total: Int

    var body: some View {
        ZStack {
            Circle().stroke(Theme.chip, lineWidth: 6)
            Circle()
                .trim(from: 0, to: total == 0 ? 0 : CGFloat(done) / CGFloat(total))
                .stroke(done == total ? Theme.success : Theme.accent, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(done)/\(total)").font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.textPrimary)
        }
        .frame(width: 64, height: 64)
    }
}

/// Lays children out left to right, wrapping onto new lines when they run out of room.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews, width: width)
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(rows.count - 1, 0))
        let used = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? used, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].indices.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if needed > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            var row = rows.removeLast()
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows.append(row)
        }
        return rows
    }
}

/// Elapsed time like 02:14, or 1:02:14 past an hour.
func elapsedText(since start: Date, now: Date) -> String {
    let seconds = max(0, Int(now.timeIntervalSince(start)))
    let hours = seconds / 3600
    let minutes = (seconds % 3600) / 60
    let rest = seconds % 60
    return hours > 0
        ? String(format: "%d:%02d:%02d", hours, minutes, rest)
        : String(format: "%02d:%02d", minutes, rest)
}
