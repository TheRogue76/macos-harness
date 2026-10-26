import CGtk
import Foundation

/// A GTK widget. GTK keeps it alive while it's in a window, so holding one is safe.
@safe struct Widget {
    let pointer: UnsafeMutablePointer<GtkWidget>

    init(_ pointer: UnsafeMutablePointer<GtkWidget>) {
        unsafe self.pointer = pointer
    }

    /// The widget as the C type a GTK function wants.
    func cast<T>() -> UnsafeMutablePointer<T> {
        unsafe UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: T.self)
    }

    var opaque: OpaquePointer { unsafe OpaquePointer(pointer) }
    var raw: UnsafeMutableRawPointer { unsafe UnsafeMutableRawPointer(pointer) }
}

/// A thin layer over GTK 4's C API: building widgets, connecting signals to Swift closures, and
/// running work on GTK's thread.
enum Gtk {
    /// A Swift closure kept alive for as long as GTK holds it.
    final class Handler {
        let run: () -> Void

        init(_ run: @escaping () -> Void) {
            self.run = run
        }
    }

    /// Calls `handler` when `instance` emits `signal`, for signals that pass only the instance
    /// (`clicked`, `activate`).
    static func connect(_ instance: UnsafeMutableRawPointer, _ signal: String, _ handler: @escaping () -> Void) {
        let box = unsafe Unmanaged.passRetained(Handler(handler)).toOpaque()
        let callback: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { _, data in
            guard let data = unsafe data else { return }
            unsafe Unmanaged<Handler>.fromOpaque(data).takeUnretainedValue().run()
        }
        let release: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<GClosure>?) -> Void = { data, _ in
            guard let data = unsafe data else { return }
            unsafe Unmanaged<Handler>.fromOpaque(data).release()
        }
        unsafe g_signal_connect_data(
            instance, signal, unsafe unsafeBitCast(callback, to: GCallback.self), box, release, GConnectFlags(rawValue: 0)
        )
    }

    /// Calls `handler` when one of `instance`'s properties changes (`notify::<property>`),
    /// whose handlers get the property's spec before their data.
    static func onChange(of property: String, on instance: UnsafeMutableRawPointer, _ handler: @escaping () -> Void) {
        let box = unsafe Unmanaged.passRetained(Handler(handler)).toOpaque()
        let callback: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { _, _, data in
            guard let data = unsafe data else { return }
            unsafe Unmanaged<Handler>.fromOpaque(data).takeUnretainedValue().run()
        }
        let release: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<GClosure>?) -> Void = { data, _ in
            guard let data = unsafe data else { return }
            unsafe Unmanaged<Handler>.fromOpaque(data).release()
        }
        unsafe g_signal_connect_data(
            instance, "notify::\(property)", unsafe unsafeBitCast(callback, to: GCallback.self), box, release, GConnectFlags(rawValue: 0)
        )
    }

    /// Runs `work` on GTK's thread, from any thread.
    static func onMain(_ work: @escaping () -> Void) {
        let box = unsafe Unmanaged.passRetained(Handler(work)).toOpaque()
        let callback: @convention(c) (UnsafeMutableRawPointer?) -> gboolean = { data in
            guard let data = unsafe data else { return 0 }
            unsafe Unmanaged<Handler>.fromOpaque(data).takeRetainedValue().run()
            return 0
        }
        unsafe g_idle_add(callback, box)
    }

    /// Any GObject pointer as another GObject type it is.
    static func cast<T, U>(_ object: UnsafeMutablePointer<U>) -> UnsafeMutablePointer<T> {
        unsafe UnsafeMutableRawPointer(object).assumingMemoryBound(to: T.self)
    }

    static func box(vertical: Bool, spacing: Int32 = 0, classes: [String] = []) -> Widget {
        let made = unsafe Widget(gtk_box_new(vertical ? GTK_ORIENTATION_VERTICAL : GTK_ORIENTATION_HORIZONTAL, spacing)!)
        style(made, classes)
        return made
    }

    static func append(_ parent: Widget, _ children: Widget...) {
        for child in children { unsafe gtk_box_append(parent.cast(), child.pointer) }
    }

    /// Removes every child of a box.
    static func empty(_ parent: Widget) {
        while let child = unsafe gtk_widget_get_first_child(parent.pointer) {
            unsafe gtk_box_remove(parent.cast(), child)
        }
    }

    static func label(_ text: String, classes: [String] = [], wrap: Bool = false, ellipsize: Bool = false, xalign: Float = 0) -> Widget {
        let made = unsafe Widget(gtk_label_new(text)!)
        let label = unsafe made.opaque
        unsafe gtk_label_set_xalign(label, xalign)
        if wrap {
            unsafe gtk_label_set_wrap(label, 1)
            unsafe gtk_label_set_natural_wrap_mode(label, GTK_NATURAL_WRAP_WORD)
        }
        if ellipsize { unsafe gtk_label_set_ellipsize(label, PANGO_ELLIPSIZE_END) }
        style(made, classes)
        return made
    }

    static func button(_ text: String, classes: [String] = [], _ action: @escaping () -> Void) -> Widget {
        let made = unsafe Widget(gtk_button_new_with_label(text)!)
        style(made, classes)
        unsafe connect(made.raw, "clicked", action)
        return made
    }

    static func iconButton(_ icon: String, tooltip: String, classes: [String] = [], _ action: @escaping () -> Void) -> Widget {
        let made = unsafe Widget(gtk_button_new_from_icon_name(icon)!)
        unsafe gtk_widget_set_tooltip_text(made.pointer, tooltip)
        style(made, classes)
        unsafe connect(made.raw, "clicked", action)
        return made
    }

    static func image(file: String, size: Int32) -> Widget {
        let made = unsafe Widget(gtk_image_new_from_file(file)!)
        unsafe gtk_image_set_pixel_size(made.opaque, size)
        return made
    }

    static func spacer() -> Widget {
        let made = box(vertical: false)
        unsafe gtk_widget_set_hexpand(made.pointer, 1)
        return made
    }

    static func separator() -> Widget {
        unsafe Widget(gtk_separator_new(GTK_ORIENTATION_HORIZONTAL)!)
    }

    static func style(_ widget: Widget, _ classes: [String]) {
        for name in classes { unsafe gtk_widget_add_css_class(widget.pointer, name) }
    }

    static func margins(_ widget: Widget, _ all: Int32) {
        unsafe gtk_widget_set_margin_top(widget.pointer, all)
        unsafe gtk_widget_set_margin_bottom(widget.pointer, all)
        unsafe gtk_widget_set_margin_start(widget.pointer, all)
        unsafe gtk_widget_set_margin_end(widget.pointer, all)
    }

    /// A vertically scrolling area as tall as `child` up to `maxHeight`.
    static func scrolled(_ child: Widget, maxHeight: Int32 = 560) -> Widget {
        let made = unsafe Widget(gtk_scrolled_window_new()!)
        let scrolled = unsafe made.opaque
        unsafe gtk_scrolled_window_set_policy(scrolled, GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        unsafe gtk_scrolled_window_set_propagate_natural_height(scrolled, 1)
        unsafe gtk_scrolled_window_set_max_content_height(scrolled, maxHeight)
        unsafe gtk_scrolled_window_set_child(scrolled, child.pointer)
        return made
    }

    /// Adds CSS for the whole app.
    static func addStyle(_ css: String) {
        guard let provider = unsafe gtk_css_provider_new(), let display = unsafe gdk_display_get_default() else { return }
        unsafe gtk_css_provider_load_from_string(provider, css)
        unsafe gtk_style_context_add_provider_for_display(display, OpaquePointer(provider), UInt32(GTK_STYLE_PROVIDER_PRIORITY_APPLICATION))
    }
}
