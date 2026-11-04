import CGtk
import Foundation
import HarnessProtocol

/// The window marker on desktops whose compositor can't draw one (KDE and Sway), as on the Mac: a
/// window of its own that's clear but for a 2 pt orange ring just outside the agent's window, a
/// fainter, wider one round it for a glow, and a tab on its top edge, or a ripple where the agent
/// clicked or pressed, or both. Clicks pass through it. The helper lays it out, puts it round the
/// agent's window, then shows it; it fades after about 1.6 s (0.9 s for a ripple alone) and hides
/// until the next one. Until it's shown it's all but clear, never fully: GTK doesn't map a window
/// with nothing to draw, so a speck at opacity 0.01 stays in its corner.
final class Marker {
    static let css = """
        window.marker { background: none; box-shadow: none; }
        .marker-content { opacity: 0.01; transition: opacity 300ms ease-out; }
        .marker-content.shown { opacity: 1; transition: opacity 120ms ease-in; }
        .marker-glow { border: 4px solid rgba(255, 69, 15, 0.25); border-radius: 18px; }
        .marker-ring { border: 2px solid #FF450F; border-radius: 14px; }
        .marker-tab { background-color: #FF450F; color: white; font-size: 11px; font-weight: 600; padding: 2px 8px; border-radius: 6px 6px 0 0; }
        .marker-speck { background-color: #FF450F; opacity: 0.01; min-width: 1px; min-height: 1px; }
        .marker-ripple { border: 2px solid #FF450F; border-radius: 9999px; animation: marker-ripple 800ms ease-out forwards; }
        .marker-dot { background-color: rgba(255, 69, 15, 0.3); border: 2px solid #FF450F; border-radius: 9999px; animation: marker-dot 800ms ease-out forwards; }
        @keyframes marker-ripple { from { transform: scale(0.3); opacity: 0.9; } to { transform: scale(1); opacity: 0; } }
        @keyframes marker-dot { from { opacity: 1; } to { opacity: 0; } }
        """

    /// The ripple's outer ring and its dot, across, in points.
    static let rippleSize: Int32 = 74
    static let dotSize: Int32 = 30

    let client: TowerClient
    let window: Widget
    private let content: Widget
    private let glow: Widget
    private let ring: Widget
    private let tabSlot: Widget
    private let tab: Widget
    private let stage: Widget
    private var current = 0
    private var shown = 0
    private var failures = 0

    init(app: UnsafeMutablePointer<GtkApplication>, client: TowerClient) {
        self.client = client
        window = unsafe Widget(gtk_application_window_new(app)!)
        unsafe gtk_window_set_title(window.cast(), "Window marker")
        unsafe gtk_window_set_decorated(window.cast(), 0)
        unsafe gtk_window_set_default_size(window.cast(), 64, 64)
        unsafe gtk_widget_remove_css_class(window.pointer, "background")
        Gtk.style(window, ["marker"])
        let overlay = unsafe Widget(gtk_overlay_new()!)
        content = overlay
        Gtk.style(content, ["marker-content"])
        glow = Gtk.box(vertical: false, classes: ["marker-glow"])
        unsafe gtk_widget_set_hexpand(glow.pointer, 1)
        unsafe gtk_widget_set_vexpand(glow.pointer, 1)
        ring = Gtk.box(vertical: false, classes: ["marker-ring"])
        Gtk.margins(ring, 4)
        unsafe gtk_overlay_set_child(overlay.opaque, glow.pointer)
        unsafe gtk_overlay_add_overlay(overlay.opaque, ring.pointer)
        tab = Gtk.label("", classes: ["marker-tab"], ellipsize: true)
        unsafe gtk_widget_set_halign(tab.pointer, GTK_ALIGN_START)
        unsafe gtk_widget_set_valign(tab.pointer, GTK_ALIGN_END)
        tabSlot = Gtk.box(vertical: true)
        unsafe gtk_widget_set_valign(tabSlot.pointer, GTK_ALIGN_START)
        unsafe gtk_widget_set_margin_start(tabSlot.pointer, Int32(TowerMarkMethod.glow) + 14)
        unsafe gtk_widget_set_margin_end(tabSlot.pointer, Int32(TowerMarkMethod.glow) + 14)
        Gtk.append(tabSlot, tab)
        unsafe gtk_overlay_add_overlay(overlay.opaque, tabSlot.pointer)
        stage = unsafe Widget(gtk_fixed_new()!)
        let speck = Gtk.box(vertical: false, classes: ["marker-speck"])
        unsafe gtk_fixed_put(stage.cast(), speck.pointer, 0, 0)
        unsafe gtk_overlay_add_overlay(overlay.opaque, stage.pointer)
        unsafe gtk_window_set_child(window.cast(), content.pointer)
        unsafe Gtk.connect(window.raw, "map") { [self] in passClicksThrough() }
    }

    /// Lets every click through to the windows below, by giving the window an empty input region.
    private func passClicksThrough() {
        guard let surface = unsafe gtk_native_get_surface(window.opaque), let empty = unsafe cairo_region_create() else { return }
        unsafe gdk_surface_set_input_region(surface, empty)
        unsafe cairo_region_destroy(empty)
    }

    /// Lays out a marker that the helper is about to put in place, still clear.
    private func lay(_ mark: TowerMarkMethod.Mark) {
        current = mark.id
        for part in [glow, ring, tabSlot] { unsafe gtk_widget_set_visible(part.pointer, mark.caption == nil ? 0 : 1) }
        unsafe gtk_label_set_text(tab.opaque, mark.caption ?? "")
        let tabHeight = Int32(TowerMarkMethod.tabHeight), glowWidth = Int32(TowerMarkMethod.glow)
        unsafe gtk_widget_set_margin_top(glow.pointer, mark.tabInside ? 0 : tabHeight)
        unsafe gtk_widget_set_margin_top(ring.pointer, (mark.tabInside ? 0 : tabHeight) + 4)
        unsafe gtk_widget_set_size_request(tabSlot.pointer, -1, mark.tabInside ? -1 : tabHeight + 4)
        unsafe gtk_widget_set_margin_top(tabSlot.pointer, mark.tabInside ? glowWidth + 4 : 0)
        unsafe gtk_widget_set_valign(tab.pointer, mark.tabInside ? GTK_ALIGN_START : GTK_ALIGN_END)
        if unsafe gtk_widget_get_visible(window.pointer) == 0 {
            unsafe gtk_widget_set_visible(window.pointer, 1)
        }
        passClicksThrough()
    }

    /// Shows the placed marker, fades it after about 1.6 s (0.9 s for a ripple alone) and hides
    /// the window, unless a newer marker came meanwhile.
    private func show(_ mark: TowerMarkMethod.Mark) {
        guard mark.id == current else { return }
        shown = mark.id
        Gtk.style(content, ["shown"])
        if let point = mark.ripple { ripple(at: point) }
        Gtk.after(mark.caption == nil ? 900 : 1300) { [self] in
            guard shown == mark.id else { return }
            unsafe gtk_widget_remove_css_class(content.pointer, "shown")
            Gtk.after(350) { [self] in
                guard shown == mark.id, current == mark.id else { return }
                unsafe gtk_widget_set_visible(window.pointer, 0)
            }
        }
    }

    /// A ripple at a point in the window, as on the Mac: a ring that grows and fades round a dot
    /// that fades, gone after 0.9 s.
    private func ripple(at point: Point) {
        let ring = Gtk.box(vertical: false, classes: ["marker-ripple"])
        let dot = Gtk.box(vertical: false, classes: ["marker-dot"])
        for (part, size) in [(ring, Self.rippleSize), (dot, Self.dotSize)] {
            unsafe gtk_widget_set_size_request(part.pointer, size, size)
            unsafe gtk_fixed_put(stage.cast(), part.pointer, point.x - Double(size) / 2, point.y - Double(size) / 2)
        }
        Gtk.after(900) { [self] in
            for part in [ring, dot] { unsafe gtk_fixed_remove(stage.cast(), part.pointer) }
        }
    }

    /// Asks the helper for markers until it stops answering.
    func listen() {
        client.mark { [self] result in
            switch result {
            case .success(let mark):
                failures = 0
                if let mark { mark.placed ? show(mark) : lay(mark) }
                listen()
            case .failure:
                failures += 1
                guard failures < 5 else { exit(0) }
                Gtk.after(1000) { [self] in listen() }
            }
        }
    }

    static func main(client: TowerClient) {
        let id = "io.github.therogue76.MacosHarness\(client.variant == .dev ? "Dev" : "").Marker"
        let app = unsafe gtk_application_new(id, GApplicationFlags(rawValue: 1 << 5))!
        var marker: Marker?
        unsafe Gtk.connect(UnsafeMutableRawPointer(app), "activate") {
            guard marker == nil else { return }
            Gtk.addStyle(css)
            let made = unsafe Marker(app: app, client: client)
            marker = made
            unsafe g_application_hold(Gtk.cast(app))
            made.listen()
        }
        _ = unsafe g_application_run(Gtk.cast(app), 0, nil)
    }
}
