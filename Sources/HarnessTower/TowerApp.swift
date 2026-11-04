import CGtk
import Foundation

/// The Control Tower panel on Linux, started by the helper when its tray icon is clicked. A
/// second start brings the open panel forward; it closes when it loses focus, as the Mac's does.
/// Started for setup, it shows only the setup window, as the Mac's helper does when a permission
/// is missing.
enum TowerApp {
    /// The open windows, kept by GTK's thread.
    final class Open {
        var panel: Panel?
        var setup: SetupWindow?
        var showSetup: () -> Void = {}
    }

    static func main() {
        guard let client = TowerClient() else {
            FileHandle.standardError.write(Data("The Control Tower panel opens from the macOS Harness tray icon.\n".utf8))
            exit(2)
        }
        let id = "io.github.therogue76.MacosHarness\(client.variant == .dev ? "Dev" : "").Tower"
        let app = unsafe adw_application_new(id, GApplicationFlags(rawValue: 0))!
        let instance = UnsafeMutableRawPointer(app)
        let open = Open()
        var setupOnly = ProcessInfo.processInfo.environment["MACOS_HARNESS_TOWER_SETUP"] == "1"
        var styled = false
        open.showSetup = {
            if let setup = open.setup {
                setup.present()
                return
            }
            let made = unsafe SetupWindow(app: app, client: client)
            open.setup = made
            unsafe Gtk.connect(made.window.raw, "destroy") { open.setup = nil }
            made.show()
        }
        unsafe Gtk.connect(instance, "activate") {
            if !styled {
                styled = true
                if let display = unsafe gdk_display_get_default(), let theme = unsafe gtk_icon_theme_get_for_display(display) {
                    let runtime = ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"] ?? NSTemporaryDirectory()
                    unsafe gtk_icon_theme_add_search_path(theme, "\(runtime)/macos-harness/icons")
                }
                Gtk.addStyle(Panel.css + SetupWindow.css)
            }
            if setupOnly {
                setupOnly = false
                open.showSetup()
                return
            }
            if let panel = open.panel {
                unsafe gtk_window_present(panel.window.cast())
                return
            }
            let window = unsafe Widget(adw_application_window_new(Gtk.cast(app))!)
            unsafe gtk_window_set_title(window.cast(), client.variant == .dev ? "macOS Harness Dev" : "macOS Harness")
            unsafe gtk_window_set_default_size(window.cast(), 380, -1)
            unsafe gtk_window_set_resizable(window.cast(), 0)
            let made = Panel(window: window, client: client) { open.showSetup() }
            open.panel = made
            unsafe Gtk.connect(window.raw, "destroy") { open.panel = nil }
            unsafe adw_application_window_set_content(window.cast(), made.build().pointer)
            unsafe Gtk.onChange(of: "is-active", on: window.raw) {
                if unsafe gtk_window_is_active(window.cast()) == 0 { unsafe gtk_window_close(window.cast()) }
            }
            let escape = unsafe gtk_shortcut_controller_new()!
            let trigger = unsafe gtk_shortcut_trigger_parse_string("Escape")
            let close = unsafe gtk_named_action_new("window.close")
            let shortcut = unsafe gtk_shortcut_new(trigger, close)
            let controller: OpaquePointer = unsafe OpaquePointer(UnsafeMutableRawPointer(escape))
            unsafe gtk_shortcut_controller_add_shortcut(controller, shortcut)
            unsafe gtk_widget_add_controller(window.pointer, escape)
            unsafe gtk_widget_set_opacity(window.pointer, 0)
            unsafe gtk_window_present(window.cast())
        }
        _ = unsafe g_application_run(Gtk.cast(app), 0, nil)
    }
}
