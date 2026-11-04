import CGtk
import Foundation
import HarnessProtocol

/// The "<agent> is driving" panel, as on the Mac: bottom right, with how long the session has run,
/// what it's doing, who's waiting for the mouse and keyboard, Pause (stop this agent) and Stop
/// (stop every agent). The helper lays it out, puts it in the corner, then shows it; it hides 8 s
/// after the agent's last step.
final class DrivingPanel {
    static let css = """
        window.driving { background: none; box-shadow: none; }
        .driving-content { opacity: 0.01; }
        .driving-content.shown { opacity: 1; transition: opacity 120ms ease-in; }
        .driving-card { background-color: @window_bg_color; color: @window_fg_color; border: 1px solid alpha(@window_fg_color, 0.12); border-radius: 14px; padding: 12px; }
        .driving-dot { background-color: #FF450F; border-radius: 4px; min-width: 8px; min-height: 8px; }
        .driving-title { font-weight: 700; }
        .driving-dim { opacity: 0.65; font-size: 0.9em; }
        .driving-time { opacity: 0.65; font-feature-settings: "tnum"; }
        button.driving-stop { background: #D93100; color: white; }
        """

    let client: TowerClient
    let window: Widget
    private let card: Widget
    private let title: Widget
    private let time: Widget
    private let detail: Widget
    private let queue: Widget
    private let stop: Widget
    private var current: TowerMarkMethod.Driving?
    private var started = Date()
    private var shown = 0

    init(app: UnsafeMutablePointer<GtkApplication>, client: TowerClient) {
        self.client = client
        window = unsafe Widget(gtk_application_window_new(app)!)
        unsafe gtk_window_set_title(window.cast(), TowerMarkMethod.drivingTitle)
        unsafe gtk_window_set_decorated(window.cast(), 0)
        unsafe gtk_window_set_resizable(window.cast(), 0)
        unsafe gtk_widget_remove_css_class(window.pointer, "background")
        Gtk.style(window, ["driving"])
        card = Gtk.box(vertical: true, spacing: 10, classes: ["driving-card", "driving-content"])
        unsafe gtk_widget_set_size_request(card.pointer, 250, -1)
        title = Gtk.label("", classes: ["driving-title"], ellipsize: true)
        unsafe gtk_widget_set_hexpand(title.pointer, 1)
        time = Gtk.label("", classes: ["driving-time"])
        let heading = Gtk.box(vertical: false, spacing: 8)
        let dot = Gtk.box(vertical: false, classes: ["driving-dot"])
        unsafe gtk_widget_set_valign(dot.pointer, GTK_ALIGN_CENTER)
        Gtk.append(heading, dot, title, time)
        detail = Gtk.label("", classes: ["driving-dim"], ellipsize: true)
        queue = Gtk.label("", classes: ["driving-dim"], wrap: true)
        let buttons = Gtk.box(vertical: false, spacing: 8)
        unsafe gtk_box_set_homogeneous(buttons.cast(), 1)
        stop = Gtk.button("Stop", classes: ["driving-stop"]) {}
        Gtk.append(card, heading, detail, queue, buttons)
        unsafe gtk_window_set_child(window.cast(), card.pointer)
        let pause = Gtk.button("Pause") { [weak self] in
            guard let self, let key = current?.key else { return }
            client.act(.stop, key: key)
            hide()
        }
        unsafe Gtk.connect(stop.raw, "clicked") { [weak self] in
            self?.client.act(.stopAll)
            self?.hide()
        }
        Gtk.append(buttons, pause, stop)
    }

    /// Lays out the panel for a step, still clear, so the helper can put it in place.
    func lay(_ driving: TowerMarkMethod.Driving) {
        current = driving
        started = Date().addingTimeInterval(-driving.runningFor)
        let parts = driving.agent.components(separatedBy: " · ")
        unsafe gtk_label_set_text(title.opaque, "\(parts[0]) is driving")
        unsafe gtk_label_set_text(detail.opaque, (parts.dropFirst() + [driving.detail]).joined(separator: " · "))
        unsafe gtk_label_set_text(queue.opaque, driving.queue.isEmpty ? "" : "In line: \(driving.queue.joined(separator: ", "))")
        unsafe gtk_widget_set_visible(queue.pointer, driving.queue.isEmpty ? 0 : 1)
        unsafe gtk_button_set_label(stop.cast(), driving.stopShortcut.map { "Stop  \($0)" } ?? "Stop")
        tick()
        if unsafe gtk_widget_get_visible(window.pointer) == 0 {
            unsafe gtk_widget_remove_css_class(card.pointer, "shown")
            unsafe gtk_widget_set_visible(window.pointer, 1)
        }
    }

    /// Shows the placed panel, and hides it 8 s later unless another step came meanwhile.
    func show(_ driving: TowerMarkMethod.Driving) {
        guard driving.id == current?.id else { return }
        shown = driving.id
        Gtk.style(card, ["shown"])
        Gtk.after(8000) { [self] in
            if shown == driving.id { hide() }
        }
    }

    private func hide() {
        shown = 0
        unsafe gtk_widget_set_visible(window.pointer, 0)
    }

    /// Shows how long the session has run, `m:ss`, every second while the panel is up.
    private func tick() {
        let seconds = max(Int(Date().timeIntervalSince(started)), 0)
        unsafe gtk_label_set_text(time.opaque, "\(seconds / 60):\(seconds % 60 < 10 ? "0" : "")\(seconds % 60)")
        Gtk.after(1000) { [weak self] in
            guard let self, unsafe gtk_widget_get_visible(window.pointer) != 0 else { return }
            tick()
        }
    }
}
