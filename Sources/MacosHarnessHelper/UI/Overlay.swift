import AppKit
import HarnessProtocol
import SwiftUI

/// On-screen feedback while agents work: a glow around the window they touch, a caption, a ripple
/// where they act, and a floating panel with Pause and Stop.
@MainActor
final class OverlayController {
    private var highlight: NSPanel?
    private var highlightTask: Task<Void, Never>?
    private var hud: NSPanel?

    /// Glow around a window (global CG frame, top-left origin) with a caption, then fade.
    func highlight(windowFrame: Rect, title: String, detail: String, duration: TimeInterval = 1.6) {
        let padding: CGFloat = 26
        let cocoa = Self.cocoaRect(windowFrame.cg).insetBy(dx: -padding, dy: -padding)
        let panel = highlight ?? Self.makePanel(clickThrough: true)
        panel.contentView = NSHostingView(rootView: GlowView(padding: padding, title: title, detail: detail))
        panel.setFrame(cocoa, display: true)
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        Self.fade(panel, to: 1, duration: 0.15)
        highlight = panel

        highlightTask?.cancel()
        highlightTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled, let panel = self?.highlight else { return }
            Self.fade(panel, to: 0, duration: 0.35)
            try? await Task.sleep(for: .seconds(0.4))
            if !Task.isCancelled { panel.orderOut(nil) }
        }
    }

    /// A ripple where an agent clicks or presses (global CG point).
    func ripple(at point: CGPoint) {
        let size: CGFloat = 90
        let center = Self.cocoaPoint(point)
        let panel = Self.makePanel(clickThrough: true)
        panel.contentView = NSHostingView(rootView: RippleView())
        panel.setFrame(NSRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size), display: true)
        panel.orderFrontRegardless()
        Task {
            try? await Task.sleep(for: .seconds(0.9))
            panel.orderOut(nil)
        }
    }

    /// The floating "<agent> is driving" panel, bottom right of the main screen.
    func showHUD(agent: String, detail: String, started: Date, pause: @escaping () -> Void, stop: @escaping () -> Void) {
        let panel = hud ?? Self.makePanel(clickThrough: false)
        let view = DrivingHUD(agent: agent, detail: detail, started: started, pause: pause, stop: stop)
        let hosting = NSHostingView(rootView: view)
        panel.contentView = hosting
        let size = hosting.fittingSize
        let screen = NSScreen.main?.visibleFrame ?? .zero
        panel.setFrame(NSRect(x: screen.maxX - size.width - 24, y: screen.minY + 24, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
        panel.invalidateShadow()
        hud = panel
    }

    func hideHUD() {
        hud?.orderOut(nil)
    }

    private static func makePanel(clickThrough: Bool) -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = !clickThrough
        panel.level = clickThrough ? .floating : .statusBar
        panel.ignoresMouseEvents = clickThrough
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.hidesOnDeactivate = false
        return panel
    }

    private static func fade(_ window: NSWindow, to alpha: CGFloat, duration: TimeInterval) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            window.animator().alphaValue = alpha
        }
    }

    /// CG global coordinates (top-left of the primary display) to Cocoa (bottom-left).
    static func cocoaRect(_ rect: CGRect) -> NSRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    static func cocoaPoint(_ point: CGPoint) -> NSPoint {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSPoint(x: point.x, y: primaryHeight - point.y)
    }
}

private extension Rect {
    var cg: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

private struct GlowView: View {
    var padding: CGFloat
    var title: String
    var detail: String

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.accent, lineWidth: 2)
                .shadow(color: Theme.accent.opacity(0.55), radius: 14)
                .padding(padding)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.7))
                Text(detail).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(white: 0.1).opacity(0.94)))
            .padding(padding + 14)
        }
    }
}

private struct RippleView: View {
    @State private var expanded = false

    var body: some View {
        ZStack {
            Circle().stroke(Theme.accent, lineWidth: 2)
                .scaleEffect(expanded ? 1 : 0.3)
                .opacity(expanded ? 0 : 0.9)
            Circle().fill(Theme.accent.opacity(0.3))
                .overlay(Circle().stroke(Theme.accent, lineWidth: 2))
                .frame(width: 30, height: 30)
                .opacity(expanded ? 0 : 1)
        }
        .padding(8)
        .onAppear {
            withAnimation(.easeOut(duration: 0.8)) { expanded = true }
        }
    }
}

private struct DrivingHUD: View {
    var agent: String
    var detail: String
    var started: Date
    var pause: () -> Void
    var stop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Dot(color: Theme.accent, size: 8)
                Text("\(agent) is driving").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.textPrimary)
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(elapsedText(since: started, now: context.date)).monospacedDigit().foregroundStyle(Theme.textMuted)
                }
            }
            Text(detail).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).lineLimit(1)
            HStack(spacing: 8) {
                Button(action: pause) { Text("Pause").frame(maxWidth: .infinity) }.buttonStyle(.tower(.outline, height: 30))
                Button(action: stop) { Text("Stop  ⌃⌥⌘.").frame(maxWidth: .infinity) }.buttonStyle(.tower(.accent, height: 30))
            }
        }
        .font(.system(size: 13))
        .padding(12)
        .frame(width: 240)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
    }
}
