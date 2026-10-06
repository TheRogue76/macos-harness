import AppKit
import Combine
import SwiftUI

/// The borderless panel that drops down from the menu bar icon.
final class MenuBarPanel: NSPanel {
    init(contentView: NSView) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isMovable = false
        hidesOnDeactivate = false
        self.contentView = contentView
    }

    override var canBecomeKey: Bool { true }

    /// Esc closes it.
    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }
}

/// Owns the menu bar icon, its attention dot, and the Control Tower panel.
@MainActor
final class StatusItemController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let hosting: NSHostingView<ControlTowerView>
    private let panel: MenuBarPanel
    private let badge = NSView()
    private let activity: ActivityCenter
    private let pairing: PairingCoordinator
    private let permissions: PermissionsModel
    private var outsideClicks: Any?
    private var refreshTimer: Timer?
    private var observers: Set<AnyCancellable> = []

    init(view: ControlTowerView, activity: ActivityCenter, pairing: PairingCoordinator, permissions: PermissionsModel) {
        self.activity = activity
        self.pairing = pairing
        self.permissions = permissions
        hosting = NSHostingView(rootView: view)
        panel = MenuBarPanel(contentView: hosting)
        super.init()

        if let button = item.button {
            button.image = Glyphs.statusItem()
            button.image?.accessibilityDescription = "macOS Harness"
            button.target = self
            button.action = #selector(toggle)
            badge.wantsLayer = true
            badge.layer?.backgroundColor = Theme.accentNS.cgColor
            badge.layer?.cornerRadius = 3.5
            badge.frame = NSRect(x: button.bounds.width - 9, y: button.bounds.height - 10, width: 7, height: 7)
            badge.autoresizingMask = [.minXMargin, .minYMargin]
            badge.isHidden = true
            button.addSubview(badge)
        }

        let changes = [
            activity.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            pairing.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            permissions.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(changes)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.modelChanged() }
            .store(in: &observers)
        pairing.onNewRequest = { [weak self] in self?.show() }
        modelChanged()
    }

    @objc private func toggle() {
        panel.isVisible ? hide() : show()
    }

    /// `activate: false` shows the panel without taking focus from the user's app (the stop hotkey).
    func show(activate: Bool = true) {
        permissions.refresh()
        layout()
        if activate {
            NSApp.activate()
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFrontRegardless()
        }
        if outsideClicks == nil {
            outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { self?.hide() }
            }
        }
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshLiveContent() }
        }
        refreshLiveContent()
    }

    func hide() {
        panel.orderOut(nil)
        if let outsideClicks { NSEvent.removeMonitor(outsideClicks) }
        outsideClicks = nil
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func refreshLiveContent() {
        permissions.refresh()
        activity.refresh()
        Task { await activity.refreshThumbnails() }
    }

    private func modelChanged() {
        let needsAttention = !activity.sessions.isEmpty || activity.allStopped || !activity.stoppedAgents.isEmpty || !pairing.pending.isEmpty
            || !permissions.allGranted
        badge.isHidden = !needsAttention
        if panel.isVisible { layout() }
    }

    /// Sizes the panel to its content and hangs it under the icon, kept on screen.
    private func layout() {
        guard let buttonFrame = item.button?.window?.frame else { return }
        let size = hosting.fittingSize
        let screen = item.button?.window?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        var x = buttonFrame.maxX - size.width + 10
        x = min(max(x, screen.minX + 8), screen.maxX - size.width - 8)
        let y = buttonFrame.minY - size.height - 6
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        panel.invalidateShadow()
    }
}

enum Glyphs {
    /// The menu bar icon: a window with a cursor over its corner, as a template image.
    static func statusItem() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.set()
            let window = NSBezierPath(roundedRect: NSRect(x: 1.75, y: 2.75, width: 12.5, height: 9.5), xRadius: 1.8, yRadius: 1.8)
            window.lineWidth = 1.5
            window.stroke()
            let bar = NSBezierPath()
            bar.move(to: NSPoint(x: 1.75, y: 5.6))
            bar.line(to: NSPoint(x: 14.25, y: 5.6))
            bar.lineWidth = 1.5
            bar.stroke()

            let cursor = NSBezierPath()
            cursor.move(to: NSPoint(x: 10, y: 9.6))
            cursor.line(to: NSPoint(x: 16.8, y: 12.2))
            cursor.line(to: NSPoint(x: 13.9, y: 13.3))
            cursor.line(to: NSPoint(x: 12.8, y: 16.3))
            cursor.close()
            NSGraphicsContext.current?.compositingOperation = .clear
            cursor.lineWidth = 2.4
            cursor.stroke()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            cursor.fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}
