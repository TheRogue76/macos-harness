import AppKit
import HarnessCore
import SwiftUI

/// "Two switches and you're set": the first-run permission setup.
struct OnboardingView: View {
    @ObservedObject var permissions: PermissionsModel
    var appName: String
    var restart: () -> Void
    var done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 18) {
                ProgressRing(done: permissions.grantedCount, total: 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(permissions.allGranted ? "You’re set" : "Two switches and you’re set")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(permissions.allGranted
                         ? "Agents can now see and operate apps. Close this window; the menu bar icon has everything else."
                         : "Flip them for “\(appName)” in System Settings. This window notices on its own.")
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(alignment: .top, spacing: 14) {
                PermissionCard(
                    title: "Screen Recording",
                    detail: "Lets agents capture the one window they work in. Other apps never show up.",
                    granted: permissions.screenRecording
                ) {
                    permissions.screenRecordingRequested = true
                    Permissions.requestScreenRecording()
                    Permissions.openSettings(.screenRecording)
                }
                PermissionCard(
                    title: "Accessibility",
                    detail: "Lets agents read buttons and labels, and press them without moving your cursor.",
                    granted: permissions.accessibility
                ) {
                    Permissions.requestAccessibility()
                    Permissions.openSettings(.accessibility)
                }
            }

            if permissions.allGranted {
                HStack {
                    Spacer()
                    Button("Done", action: done).buttonStyle(.tower(.primary, height: 32)).keyboardShortcut(.defaultAction)
                }
            } else if !permissions.screenRecording {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.clockwise").foregroundStyle(Theme.textSecondary)
                    Text("macOS applies Screen Recording after a restart. Switched it on already? Restart the helper.")
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Restart now", action: restart).buttonStyle(.tower(.outline))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.inset))
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 32)
        .padding(.top, 8)
        .padding(.bottom, 28)
        .frame(width: 640)
        .background(Theme.surface)
    }
}

private struct PermissionCard: View {
    var title: String
    var detail: String
    var granted: Bool
    var open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.textPrimary)
                Spacer()
                SwitchPicture(on: granted)
            }
            Text(detail).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if granted {
                Label("On", systemImage: "checkmark").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.successText)
            } else {
                Button(action: open) { Text("Open System Settings").frame(maxWidth: .infinity) }
                    .buttonStyle(.tower(.accent, height: 32))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(granted ? Theme.success.opacity(0.45) : Theme.accent, lineWidth: 1)
        )
    }
}

/// Hosts the setup view in a window with a transparent title bar, polling permissions while open.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var poll: Timer?
    private let permissions: PermissionsModel
    private let appName: String
    private let restart: () -> Void

    init(permissions: PermissionsModel, appName: String, restart: @escaping () -> Void) {
        self.permissions = permissions
        self.appName = appName
        self.restart = restart
    }

    func show() {
        if window == nil {
            let view = OnboardingView(permissions: permissions, appName: appName, restart: restart) { [weak self] in
                self?.window?.close()
            }
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered, defer: false
            )
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            window.title = "Set Up \(appName)"
            window.backgroundColor = NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: 0x262626) : .white
            }
            let hosting = NSHostingView(rootView: view.padding(.top, 28))
            window.contentView = hosting
            window.setContentSize(hosting.fittingSize)
            window.center()
            window.delegate = self
            self.window = window
        }
        permissions.refresh()
        startPolling()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        poll?.invalidate()
        poll = nil
    }

    private func startPolling() {
        poll?.invalidate()
        poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.permissions.refresh() }
        }
    }
}
