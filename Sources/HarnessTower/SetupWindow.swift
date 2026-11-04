import CGtk
import Foundation
import HarnessProtocol

/// The setup window, as on the Mac: how many permissions are ready, a card per permission with
/// the desktop's own dialog behind its button, and Done once nothing is missing.
final class SetupWindow {
    let client: TowerClient
    let window: Widget
    let progress: Widget
    let heading: Widget
    let summary: Widget
    let cards: Widget
    let footer: Widget
    private var state: TowerState?
    private var closed = false
    private var asking: String?

    init(app: UnsafeMutablePointer<AdwApplication>, client: TowerClient) {
        self.client = client
        window = unsafe Widget(adw_application_window_new(Gtk.cast(app))!)
        progress = Gtk.label("", classes: ["setup-progress"], xalign: 0.5)
        heading = Gtk.label("", classes: ["setup-heading"], wrap: true)
        summary = Gtk.label("", classes: ["tower-dim"], wrap: true)
        cards = Gtk.box(vertical: true, spacing: 12)
        footer = Gtk.box(vertical: false, spacing: 8)
    }

    /// Builds the window; it shows once the first state is in, so the desktop centres it at its
    /// full size rather than growing it past the screen's edge.
    func show() {
        unsafe gtk_window_set_title(window.cast(), client.variant == .dev ? "Set up macOS Harness Dev" : "Set up macOS Harness")
        unsafe gtk_window_set_default_size(window.cast(), 640, -1)
        unsafe gtk_window_set_resizable(window.cast(), 0)
        let root = Gtk.box(vertical: true, spacing: 20)
        unsafe gtk_widget_set_margin_top(root.pointer, 28)
        unsafe gtk_widget_set_margin_bottom(root.pointer, 28)
        unsafe gtk_widget_set_margin_start(root.pointer, 32)
        unsafe gtk_widget_set_margin_end(root.pointer, 32)
        let top = Gtk.box(vertical: false, spacing: 18)
        let words = Gtk.box(vertical: true, spacing: 4)
        unsafe gtk_widget_set_hexpand(words.pointer, 1)
        Gtk.append(words, heading, summary)
        Gtk.append(top, progress, words)
        Gtk.append(root, top, Gtk.scrolled(cards, maxHeight: 400), footer)
        let header = unsafe Widget(adw_header_bar_new()!)
        let layout = Gtk.box(vertical: true)
        Gtk.append(layout, header, root)
        unsafe adw_application_window_set_content(window.cast(), layout.pointer)
        unsafe Gtk.connect(window.raw, "close-request") { [weak self] in self?.closed = true }
        refresh()
    }

    func present() {
        unsafe gtk_window_present(window.cast())
    }

    /// Reads the state every second while the window is open, so it notices grants on its own.
    func refresh() {
        guard !closed else { return }
        client.state { [weak self] state in
            guard let self, !self.closed else { return }
            if let state, state != self.state {
                let first = self.state == nil
                self.state = state
                self.render(state)
                if first { self.present() }
            }
            if state?.showSetup == true {
                self.present()
                self.client.act(.setupShown)
            }
            let again = unsafe Unmanaged.passRetained(Gtk.Handler { [weak self] in self?.refresh() }).toOpaque()
            let callback: @convention(c) (UnsafeMutableRawPointer?) -> gboolean = { data in
                guard let data = unsafe data else { return 0 }
                unsafe Unmanaged<Gtk.Handler>.fromOpaque(data).takeRetainedValue().run()
                return 0
            }
            unsafe g_timeout_add(1000, callback, again)
        }
    }

    func render(_ state: TowerState) {
        let relevant = state.permissions.filter { $0.state != .unsupported }
        let ready = relevant.filter { $0.state != .missing }.count
        let missing = relevant.count - ready
        unsafe gtk_label_set_text(progress.opaque, "\(ready)/\(relevant.count)")
        Gtk.style(progress, missing == 0 ? ["done"] : [])
        if missing == 0 { unsafe gtk_widget_remove_css_class(progress.pointer, "pending") } else { Gtk.style(progress, ["pending"]) }
        unsafe gtk_label_set_text(heading.opaque, missing == 0 ? "You’re set" : missing == 1 ? "One more and you’re set" : "\(missing) more and you’re set")
        unsafe gtk_label_set_text(summary.opaque, missing == 0
            ? "Agents can now see and operate apps. Close this window; the icon in the top bar has everything else."
            : "Each button shows the desktop’s own dialog. This window notices on its own.")
        Gtk.empty(cards)
        var row: Widget?
        for (index, item) in relevant.enumerated() {
            if index % 2 == 0 {
                let next = Gtk.box(vertical: false, spacing: 14, classes: ["setup-row"])
                unsafe gtk_box_set_homogeneous(next.cast(), 1)
                Gtk.append(cards, next)
                row = next
            }
            if let row { Gtk.append(row, card(item)) }
        }
        Gtk.empty(footer)
        Gtk.append(footer, Gtk.spacer())
        Gtk.append(footer, missing == 0
            ? Gtk.button("Done", classes: ["tower-stop", "tower-wide"]) { [weak self] in self?.close() }
            : Gtk.button("Close", classes: ["tower-small"]) { [weak self] in self?.close() })
    }

    func card(_ item: PermissionsMethod.Item) -> Widget {
        let ready = item.state != .missing
        let card = Gtk.box(vertical: true, spacing: 10, classes: ["card", "setup-card", ready ? "ready" : "missing"])
        let top = Gtk.box(vertical: false, spacing: 8)
        Gtk.append(top, Gtk.label(item.name, classes: ["tower-title"]), Gtk.spacer())
        Gtk.append(card, top, Gtk.label(Self.purpose[item.id] ?? item.detail, classes: ["tower-dim"], wrap: true))
        let filler = Gtk.box(vertical: true)
        unsafe gtk_widget_set_vexpand(filler.pointer, 1)
        Gtk.append(card, filler)
        if ready {
            Gtk.append(card, Gtk.label(item.state == .notNeeded ? "✓ Nothing to allow here" : "✓ On", classes: ["setup-on"]))
        } else if item.id == "accessibility" {
            Gtk.append(card, Gtk.label(item.detail, classes: ["tower-warning"], wrap: true))
        } else if asking == item.id {
            Gtk.append(card, Gtk.label("Answer the dialog…", classes: ["tower-dim"]))
        } else {
            Gtk.append(card, Gtk.button(Self.button[item.id] ?? "Allow…", classes: ["tower-stop", "tower-wide"]) { [weak self] in
                self?.grant(item)
            })
        }
        return card
    }

    func grant(_ item: PermissionsMethod.Item) {
        asking = item.id
        if let state { render(state) }
        client.act(.grant, key: item.id) { [weak self] in
            guard let self else { return }
            self.asking = nil
            self.state = nil
            self.refresh()
        }
    }

    func close() {
        closed = true
        unsafe gtk_window_close(window.cast())
    }

    static let purpose = [
        "accessibility": "Lets agents read buttons and labels, and press them without moving your pointer.",
        "windows": "Lets agents find the window they work in and bring it forward. Nothing else.",
        "screenshots": "Lets agents capture the one window they work in.",
        "input": "Lets agents click and type for you, with the guard rails on.",
        "recording": "Lets agents record the one window they work in.",
        "stop-shortcut": "Ctrl+Alt+Super+. stops every agent, from any app.",
    ]

    static let button = [
        "windows": "Install the extension…",
        "screenshots": "Allow screenshots…",
        "input": "Allow control…",
        "recording": "Allow recording…",
        "stop-shortcut": "Add the shortcut…",
    ]

    static let css = """
        .setup-heading { font-size: 1.6em; font-weight: 700; }
        .setup-progress { min-width: 64px; min-height: 64px; border-radius: 999px; font-weight: 700; font-size: 1.1em;
            border: 4px solid alpha(currentColor, 0.15); }
        .setup-progress.pending { border-color: #FF450F; }
        .setup-progress.done { border-color: #2EA043; }
        .setup-card { padding: 14px; border-radius: 12px; min-height: 120px; }
        .setup-card.missing { box-shadow: inset 0 0 0 1px #FF450F; }
        .setup-card.ready { box-shadow: inset 0 0 0 1px alpha(#2EA043, 0.45); }
        .setup-on { color: #2EA043; font-weight: 600; }
        """
}
