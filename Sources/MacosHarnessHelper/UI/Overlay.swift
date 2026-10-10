import AppKit
import HarnessCore
import HarnessProtocol
import SwiftUI

/// On-screen feedback while agents work: a ring and tab around the window they touch, a ripple
/// where they act, and a floating panel with Pause and Stop.
@MainActor
final class OverlayController {
    private var marker: WindowMarker?
    private var hud: NSPanel?
    private var radii: [UInt32: CGFloat] = [:]
    private var measuring: Set<UInt32> = []

    /// Rings the window with a tab saying what happened, for `duration` seconds. The ring stays just
    /// above that window and follows it, so whatever is in front of the window covers it too, and
    /// it isn't shown while the window is off the screen.
    func mark(window id: UInt32, caption: String, duration: TimeInterval = 1.6) {
        let marker = self.marker ?? WindowMarker()
        self.marker = marker
        marker.show(window: id, caption: caption, radius: radii[id] ?? WindowCorners.fallback, duration: duration)
        measureCorners(of: id)
    }

    /// A ripple where an agent clicks or presses (global CG point), kept above the window it acted
    /// in and left out when something covers that point.
    func ripple(at point: CGPoint, in window: UInt32? = nil) {
        let size: CGFloat = 90
        let panel = Self.makePanel(clickThrough: true)
        if let window {
            guard let placement = OnScreenWindow.current(of: window, ignoring: getpid()),
                  !placement.occluders.contains(where: { $0.contains(point) }) else { return }
            panel.level = .normal
        }
        let center = Self.cocoaPoint(point)
        panel.contentView = NSHostingView(rootView: RippleView())
        panel.setFrame(NSRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size), display: true)
        if let window {
            panel.orderFrontRegardless()
            panel.order(.above, relativeTo: Int(window))
        } else {
            panel.orderFrontRegardless()
        }
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

    /// Measures a window's corner radius once, so its ring follows the corners.
    private func measureCorners(of id: UInt32) {
        guard radii[id] == nil, !measuring.contains(id) else { return }
        measuring.insert(id)
        Task { [weak self] in
            let radius = await WindowCorners.measure(windowID: id)
            guard let self else { return }
            self.measuring.remove(id)
            self.radii[id] = radius ?? WindowCorners.fallback
            self.marker?.update(radius: self.radii[id] ?? WindowCorners.fallback, for: id)
        }
    }

    static func makePanel(clickThrough: Bool) -> NSPanel {
        let panel = OverlayPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = !clickThrough
        panel.level = clickThrough ? .floating : .statusBar
        panel.ignoresMouseEvents = clickThrough
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.hidesOnDeactivate = false
        return panel
    }

    static func fade(_ window: NSWindow, to alpha: CGFloat, duration: TimeInterval) {
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

/// A panel that stays exactly where it's put, even over the menu bar, so the ring lines up with
/// windows at the top of the screen.
final class OverlayPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// What the marker draws: the window's place inside the marker panel, the parts covered by other
/// windows, the corner radius and the tab's text.
@MainActor
final class MarkerModel: ObservableObject {
    @Published var window: CGRect = .zero
    @Published var covered: [CGRect] = []
    @Published var radius: CGFloat = WindowCorners.fallback
    @Published var caption = ""
    @Published var tabInside = false
}

/// The ring and tab around one window at a time, kept directly above that window while it's on
/// the screen and following it as it moves.
@MainActor
final class WindowMarker {
    /// Room around the window for the glow and the tab.
    static let margin: CGFloat = 36
    static let tabHeight: CGFloat = 26
    /// Room the tab leaves for a window's close, minimize and zoom buttons when it sits inside.
    static let titleButtonsWidth: CGFloat = 84
    private let panel = OverlayController.makePanel(clickThrough: true)
    private let model = MarkerModel()
    private var windowID: UInt32 = 0
    private var until = Date.distantPast
    private var tracking: Task<Void, Never>?
    private var placed: OnScreenWindow?
    private var fadedIn = false

    init() {
        panel.level = .normal
        panel.contentView = NSHostingView(rootView: MarkerView(model: model))
    }

    func show(window id: UInt32, caption: String, radius: CGFloat, duration: TimeInterval) {
        if id != windowID {
            panel.alphaValue = 0
            panel.orderOut(nil)
            placed = nil
        }
        windowID = id
        model.caption = caption
        model.radius = radius
        until = Date().addingTimeInterval(duration)
        if tracking == nil {
            tracking = Task { [weak self] in await self?.track() }
        }
    }

    func update(radius: CGFloat, for id: UInt32) {
        if id == windowID { model.radius = radius }
    }

    private func track() async {
        while Date() < until, !Task.isCancelled {
            follow()
            try? await Task.sleep(for: .milliseconds(100))
        }
        OverlayController.fade(panel, to: 0, duration: 0.35)
        fadedIn = false
        try? await Task.sleep(for: .seconds(0.4))
        if Date() < until {
            tracking = Task { [weak self] in await self?.track() }
            return
        }
        panel.orderOut(nil)
        placed = nil
        tracking = nil
    }

    /// Puts the marker on the window's current frame, just above it, with the covered parts cut
    /// out; hides it while the window is off the screen.
    private func follow() {
        guard let placement = OnScreenWindow.current(of: windowID, ignoring: getpid()) else {
            panel.alphaValue = 0
            panel.orderOut(nil)
            placed = nil
            fadedIn = false
            return
        }
        let margin = Self.margin
        let outer = placement.frame.insetBy(dx: -margin, dy: -margin)
        if placement != placed {
            model.tabInside = placement.frame.minY - Self.usableTop(for: placement.frame) < Self.tabHeight
            model.window = placement.frame.offsetBy(dx: -outer.minX, dy: -outer.minY)
            model.covered = placement.occluders.map { $0.offsetBy(dx: -outer.minX, dy: -outer.minY) }
            panel.setFrame(OverlayController.cocoaRect(outer), display: true)
        }
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            panel.order(.above, relativeTo: Int(windowID))
        } else if placement.nearestAbove.map({ Int($0) }) != panel.windowNumber {
            panel.order(.above, relativeTo: Int(windowID))
        }
        if !fadedIn {
            OverlayController.fade(panel, to: 1, duration: 0.15)
            fadedIn = true
        }
        placed = placement
    }

    /// The top of the area below the menu bar on the display showing the frame, in global
    /// coordinates with the origin at the top left of the main display.
    static func usableTop(for frame: CGRect) -> CGFloat {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        guard let screen = NSScreen.screens.first(where: { OverlayController.cocoaRect(frame).intersects($0.frame) }) else { return 0 }
        return primaryHeight - screen.visibleFrame.maxY
    }
}

private extension Rect {
    var cg: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

/// The ring just outside the window's edge, its glow, and the tab on its top edge; the parts of
/// the window other windows cover are cut out.
private struct MarkerView: View {
    @ObservedObject var model: MarkerModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            ring
            tab
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .mask {
            ZStack(alignment: .topLeading) {
                Rectangle()
                ForEach(Array(model.covered.enumerated()), id: \.offset) { _, rect in
                    Rectangle()
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                        .blendMode(.destinationOut)
                }
            }
            .compositingGroup()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var ring: some View {
        let edge = model.window.insetBy(dx: -1, dy: -1)
        return RoundedRectangle(cornerRadius: model.radius + 1, style: .continuous)
            .stroke(Theme.accent, lineWidth: 2)
            .shadow(color: Theme.accent.opacity(0.35), radius: 12)
            .frame(width: edge.width, height: edge.height)
            .offset(x: edge.minX, y: edge.minY)
    }

    private var tab: some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: model.tabInside ? 0 : 9, bottomLeadingRadius: model.tabInside ? 9 : 0,
            bottomTrailingRadius: model.tabInside ? 9 : 0, topTrailingRadius: model.tabInside ? 0 : 9, style: .continuous
        )
        let inset = model.tabInside ? WindowMarker.titleButtonsWidth : max(10, model.radius * 0.6)
        return HStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(Color.white).frame(width: 6, height: 6)
                Text(model.caption).lineLimit(1).truncationMode(.tail)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 10)
            .frame(height: WindowMarker.tabHeight)
            .background(shape.fill(Theme.accentStrong))
            Spacer(minLength: 0)
        }
        .frame(width: max(model.window.width - inset * 2, 60), alignment: .leading)
        .offset(
            x: model.window.minX + inset,
            y: model.tabInside ? model.window.minY + 1 : model.window.minY - 1 - WindowMarker.tabHeight
        )
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
        .frame(width: 250)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
    }
}
