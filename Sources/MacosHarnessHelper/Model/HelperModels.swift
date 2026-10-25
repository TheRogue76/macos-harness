import AppKit
import Darwin
import HarnessCore
import HarnessHelperCore
import HarnessMac
import HarnessProtocol
import Observation

/// Live permission state, polled while some UI shows it.
@MainActor
@Observable
final class PermissionsModel {
    private(set) var accessibility = Permissions.accessibility
    private(set) var screenRecording = Permissions.screenRecording
    /// Set once the user asked for Screen Recording, so the UI can offer a restart.
    var screenRecordingRequested = false

    var allGranted: Bool { accessibility && screenRecording }
    var grantedCount: Int { (accessibility ? 1 : 0) + (screenRecording ? 1 : 0) }

    /// Debug: pretend some permissions are missing, to review the setup window.
    @ObservationIgnored var preview: (accessibility: Bool, screenRecording: Bool)?

    func refresh() {
        let ax = preview?.accessibility ?? Permissions.accessibility
        let sr = preview?.screenRecording ?? Permissions.screenRecording
        if ax != accessibility { accessibility = ax }
        if sr != screenRecording { screenRecording = sr }
    }
}

/// Which page the menu bar panel shows: the dashboard, or the settings.
@MainActor
@Observable
final class PanelNavigation {
    var showingSettings = false
}

/// Small pictures of the windows agents last worked in, for the session cards.
@MainActor
@Observable
final class WindowThumbnails {
    private(set) var images: [UInt32: NSImage] = [:]

    /// Refreshes the pictures of the sessions' last windows.
    func refresh(for sessions: [AgentSession]) async {
        for session in sessions {
            guard let id = session.lastWindowID, let image = await Thumbnailer.capture(windowID: id) else { continue }
            images[id] = image
        }
    }
}
