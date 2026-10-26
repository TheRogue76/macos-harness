import CGtk
import Foundation
import HarnessProtocol

/// The Control Tower panel, as on the Mac: a header with the state, pairing requests, a card
/// per session, the readiness line, recent activity and Stop all; the gear opens the settings
/// page inside the panel.
final class Panel {
    let client: TowerClient
    let window: Widget
    let pill: Widget
    let content: Widget
    let footer: Widget
    private var state: TowerState?
    private var showingSettings = false
    private var shown = false
    private let opened = ContinuousClock.now

    init(window: Widget, client: TowerClient) {
        self.window = window
        self.client = client
        pill = Gtk.label("Idle", classes: ["tower-pill"])
        content = Gtk.box(vertical: true, spacing: 10)
        footer = Gtk.box(vertical: true, spacing: 0)
    }

    /// Builds the panel and starts following the helper's state.
    func build() -> Widget {
        let root = Gtk.box(vertical: true, spacing: 12, classes: ["tower-root"])
        Gtk.margins(root, 16)
        let header = Gtk.box(vertical: false, spacing: 8)
        let mark = unsafe Widget(gtk_image_new_from_icon_name("macos-harness-symbolic")!)
        unsafe gtk_image_set_pixel_size(mark.opaque, 20)
        let title = Gtk.label(client.variant == .dev ? "macOS Harness Dev" : "macOS Harness", classes: ["tower-title"])
        let gear = Gtk.iconButton("emblem-system-symbolic", tooltip: "Settings", classes: ["flat", "circular"]) { [weak self] in
            guard let self else { return }
            self.showingSettings.toggle()
            self.render()
        }
        Gtk.append(header, mark, title, pill, Gtk.spacer(), gear)
        Gtk.append(root, header, Gtk.scrolled(content), footer)
        refresh()
        return root
    }

    /// Reads the state again every second while the panel is open; the first reads come faster,
    /// until the helper has put the panel in place and it shows itself.
    func refresh() {
        client.state { [weak self] state in
            guard let self else { return }
            if !self.shown, state?.placed == true || ContinuousClock.now > self.opened + .seconds(2) {
                self.shown = true
                unsafe gtk_widget_set_opacity(self.window.pointer, 1)
            }
            if let state, state != self.state {
                self.state = state
                self.render()
            }
            let milliseconds: UInt32 = self.shown ? 1000 : 50
            let again = unsafe Unmanaged.passRetained(Gtk.Handler { [weak self] in self?.refresh() }).toOpaque()
            let callback: @convention(c) (UnsafeMutableRawPointer?) -> gboolean = { data in
                guard let data = unsafe data else { return 0 }
                unsafe Unmanaged<Gtk.Handler>.fromOpaque(data).takeRetainedValue().run()
                return 0
            }
            unsafe g_timeout_add(milliseconds, callback, again)
        }
    }

    func act(_ action: TowerActionMethod.Action, key: String? = nil) {
        client.act(action, key: key) { [weak self] in self?.refresh() }
    }

    func render() {
        guard let state else { return }
        Gtk.empty(content)
        Gtk.empty(footer)
        let driving = state.sessions.filter { !$0.stopped }.count
        let status = state.allStopped ? "Stopped" : driving == 0 ? "Idle" : "● \(driving) driving"
        unsafe gtk_label_set_text(pill.opaque, status)
        for name in ["driving", "stopped"] { unsafe gtk_widget_remove_css_class(pill.pointer, name) }
        if state.allStopped { Gtk.style(pill, ["stopped"]) } else if driving > 0 { Gtk.style(pill, ["driving"]) }
        if showingSettings {
            renderSettings(state)
            return
        }
        for request in state.requests { Gtk.append(content, pairingCard(request)) }
        for session in state.sessions { Gtk.append(content, sessionCard(session)) }
        for stopped in state.stopped {
            let row = Gtk.box(vertical: false, spacing: 8, classes: ["card", "tower-row"])
            Gtk.append(row, Gtk.label("\(stopped.name) · stopped", classes: ["tower-dim"], ellipsize: true), Gtk.spacer(),
                       Gtk.button("Resume", classes: ["tower-small"]) { [weak self] in self?.act(.resume, key: stopped.key) })
            Gtk.append(content, row)
        }
        Gtk.append(content, readiness(state))
        if !state.recent.isEmpty {
            Gtk.append(content, Gtk.separator(), Gtk.label("Recent activity", classes: ["tower-section"]))
            for entry in state.recent {
                Gtk.append(content, Gtk.label("\(entry.agent) · \(entry.summary) · \(Self.ago(entry.secondsAgo))", classes: ["tower-dim"], ellipsize: true))
            }
        }
        let shortcut = state.stopShortcut.map { "    \($0)" } ?? ""
        let button = state.allStopped || !state.stopped.isEmpty
            ? Gtk.button("Resume all agents", classes: ["tower-wide"]) { [weak self] in self?.act(.resumeAll) }
            : Gtk.button("Stop all agents\(shortcut)", classes: ["tower-stop", "tower-wide"]) { [weak self] in self?.act(.stopAll) }
        Gtk.append(footer, button)
    }

    func pairingCard(_ request: TowerState.Request) -> Widget {
        let card = Gtk.box(vertical: true, spacing: 6, classes: ["card", "tower-card", "tower-pairing"])
        let place = request.folder.map { " · \($0)" } ?? ""
        Gtk.append(card, Gtk.label("Allow \(request.name)\(place)?", classes: ["tower-title"], wrap: true))
        Gtk.append(card, Gtk.label("It wants to see and operate your apps and devices.", classes: ["tower-dim"], wrap: true))
        Gtk.append(card, Gtk.label("Started from \(request.chain.joined(separator: " ← "))", classes: ["tower-dim", "tower-mono"], wrap: true))
        let buttons = Gtk.box(vertical: false, spacing: 6)
        Gtk.append(buttons,
                   Gtk.button("Deny") { [weak self] in self?.act(.deny, key: request.id) },
                   Gtk.spacer(),
                   Gtk.button("This session only") { [weak self] in self?.act(.allowSession, key: request.id) },
                   Gtk.button("Allow", classes: ["tower-stop"]) { [weak self] in self?.act(.allow, key: request.id) })
        Gtk.append(card, buttons)
        return card
    }

    func sessionCard(_ session: TowerState.Session) -> Widget {
        let acting = session.quietFor < 10 && !session.stopped
        let card = Gtk.box(vertical: true, spacing: 4, classes: ["card", "tower-card"] + (acting ? ["acting"] : []))
        let top = Gtk.box(vertical: false, spacing: 8)
        let place = session.app.map { " in \($0)" } ?? ""
        Gtk.append(top, Gtk.label("\(session.name)\(place)", classes: ["tower-title"], ellipsize: true), Gtk.spacer())
        Gtk.append(top, session.stopped
            ? Gtk.button("Resume", classes: ["tower-small"]) { [weak self] in self?.act(.resume, key: session.key) }
            : Gtk.button("Stop", classes: ["tower-small", "tower-stop"]) { [weak self] in self?.act(.stop, key: session.key) })
        Gtk.append(card, top)
        Gtk.append(card, Gtk.label(session.lastStep, ellipsize: true))
        let when = session.stopped ? "stopped" : acting ? "now" : Self.ago(session.quietFor)
        Gtk.append(card, Gtk.label("\(when) · step \(session.steps) · \(Self.clock(session.runningFor))", classes: ["tower-dim"]))
        return card
    }

    func readiness(_ state: TowerState) -> Widget {
        let row = Gtk.box(vertical: false, spacing: 8, classes: ["tower-readiness"])
        if state.missing.isEmpty {
            let paired = state.paired.count
            Gtk.append(row, Gtk.label("Ready · \(paired) paired agent\(paired == 1 ? "" : "s")", classes: ["tower-dim"]))
        } else {
            Gtk.append(row, Gtk.label("Missing: \(state.missing.map(\.name).joined(separator: ", "))", classes: ["tower-warning"], wrap: true))
            Gtk.append(row, Gtk.spacer(), Gtk.button("Set up…", classes: ["tower-small"]) { [weak self] in self?.act(.setUp) })
        }
        return row
    }

    func renderSettings(_ state: TowerState) {
        let back = Gtk.box(vertical: false, spacing: 6)
        Gtk.append(back, Gtk.iconButton("go-previous-symbolic", tooltip: "Back", classes: ["flat", "circular"]) { [weak self] in
            self?.showingSettings = false
            self?.render()
        }, Gtk.label("Settings", classes: ["tower-title"]))
        Gtk.append(content, back)

        Gtk.append(content, Gtk.label("Recent activity", classes: ["tower-section"]))
        let recent = Gtk.box(vertical: false, spacing: 8, classes: ["card", "tower-card"])
        Gtk.append(recent, Gtk.label("The panel shows the last five actions.", classes: ["tower-dim"], wrap: true), Gtk.spacer(),
                   Gtk.button("Clear", classes: ["tower-small"]) { [weak self] in self?.act(.clearRecent) })
        Gtk.append(content, recent)

        Gtk.append(content, Gtk.label("Paired agents", classes: ["tower-section"]))
        let paired = Gtk.box(vertical: true, spacing: 8, classes: ["card", "tower-card"])
        if state.paired.isEmpty { Gtk.append(paired, Gtk.label("No agents are paired.", classes: ["tower-dim"])) }
        for agent in state.paired {
            let row = Gtk.box(vertical: false, spacing: 8)
            let formatter = DateFormatter()
            formatter.dateFormat = Calendar.current.isDate(agent.allowedAt, equalTo: Date(), toGranularity: .year) ? "d MMM" : "d MMM yyyy"
            let text = Gtk.box(vertical: true, spacing: 0)
            Gtk.append(text, Gtk.label(agent.name, ellipsize: true), Gtk.label("Allowed \(formatter.string(from: agent.allowedAt))", classes: ["tower-dim"]))
            Gtk.append(row, text, Gtk.spacer(), Gtk.button("Revoke", classes: ["tower-small"]) { [weak self] in self?.act(.revoke, key: agent.key) })
            Gtk.append(paired, row)
        }
        Gtk.append(content, paired)
        if !state.missing.isEmpty {
            Gtk.append(content, Gtk.button("Set up permissions…", classes: ["tower-wide"]) { [weak self] in self?.act(.setUp) })
        }
    }

    /// "now", "12 s ago", "3 min ago".
    static func ago(_ seconds: Double) -> String {
        if seconds < 5 { return "now" }
        if seconds < 60 { return "\(Int(seconds)) s ago" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
        return "\(Int(seconds / 3600)) h ago"
    }

    /// "mm:ss", or "h:mm:ss" past an hour.
    static func clock(_ seconds: Double) -> String {
        let total = Int(seconds)
        let (hours, minutes, rest) = (total / 3600, total % 3600 / 60, total % 60)
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%02d:%02d", minutes, rest)
    }

    static let css = """
        .tower-root { min-width: 340px; }
        .tower-title { font-weight: 700; }
        .tower-pill { border-radius: 999px; padding: 2px 10px; font-size: 0.85em; font-weight: 600; background: alpha(currentColor, 0.08); }
        .tower-pill.driving { background: #FF450F; color: white; }
        .tower-pill.stopped { background: alpha(#FF450F, 0.18); color: #D93100; }
        .tower-card { padding: 12px; border-radius: 12px; }
        .tower-card.acting { box-shadow: inset 0 0 0 2px #FF450F; }
        .tower-row { padding: 8px 12px; border-radius: 12px; }
        .tower-dim { opacity: 0.65; font-size: 0.9em; }
        .tower-mono { font-family: monospace; font-size: 0.8em; }
        .tower-warning { color: #D93100; font-weight: 600; }
        .tower-section { font-size: 0.8em; font-weight: 700; opacity: 0.55; margin-top: 4px; }
        button.tower-stop { background: #D93100; color: white; }
        button.tower-wide { padding: 10px; border-radius: 10px; font-weight: 600; }
        button.tower-small { padding: 2px 12px; min-height: 26px; border-radius: 999px; font-size: 0.9em; }
        """
}
