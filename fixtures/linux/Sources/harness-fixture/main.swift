import CGtk
import Foundation

/// A Swift closure GTK can call back, kept alive for as long as the window lives.
final class Callback {
    let run: () -> Void

    init(_ run: @escaping () -> Void) {
        self.run = run
    }
}

/// Runs `run` whenever `object` emits `signal`, for signals whose handlers take the object and
/// user data.
func on(_ object: UnsafeMutableRawPointer, _ signal: String, _ run: @escaping () -> Void) {
    let handler: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { _, data in
        guard let data else { return }
        Unmanaged<Callback>.fromOpaque(data).takeUnretainedValue().run()
    }
    let data = Unmanaged.passRetained(Callback(run)).toOpaque()
    g_signal_connect_data(object, signal, unsafeBitCast(handler, to: GCallback.self), data, nil, GConnectFlags(rawValue: 0))
}

/// Runs `run` whenever a `GSimpleAction` is activated.
func onActivate(_ action: OpaquePointer, _ run: @escaping () -> Void) {
    let handler: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { _, _, data in
        guard let data else { return }
        Unmanaged<Callback>.fromOpaque(data).takeUnretainedValue().run()
    }
    let data = Unmanaged.passRetained(Callback(run)).toOpaque()
    g_signal_connect_data(UnsafeMutableRawPointer(action), "activate", unsafeBitCast(handler, to: GCallback.self), data, nil, GConnectFlags(rawValue: 0))
}

/// A Swift closure GTK can call back with a position.
final class PointCallback {
    let run: (Double, Double) -> Void

    init(_ run: @escaping (Double, Double) -> Void) {
        self.run = run
    }
}

/// Runs `run` with the position when a click gesture is pressed.
func onPressed(_ gesture: UnsafeMutableRawPointer, _ run: @escaping (Double, Double) -> Void) {
    let handler: @convention(c) (UnsafeMutableRawPointer?, Int32, Double, Double, UnsafeMutableRawPointer?) -> Void = { _, _, x, y, data in
        guard let data else { return }
        Unmanaged<PointCallback>.fromOpaque(data).takeUnretainedValue().run(x, y)
    }
    let data = Unmanaged.passRetained(PointCallback(run)).toOpaque()
    g_signal_connect_data(gesture, "pressed", unsafeBitCast(handler, to: GCallback.self), data, nil, GConnectFlags(rawValue: 0))
}

/// Runs `run` when the pointer enters a motion controller's widget.
func onEnter(_ controller: UnsafeMutableRawPointer, _ run: @escaping () -> Void) {
    let handler: @convention(c) (UnsafeMutableRawPointer?, Double, Double, UnsafeMutableRawPointer?) -> Void = { _, _, _, data in
        guard let data else { return }
        Unmanaged<Callback>.fromOpaque(data).takeUnretainedValue().run()
    }
    let data = Unmanaged.passRetained(Callback(run)).toOpaque()
    g_signal_connect_data(controller, "enter", unsafeBitCast(handler, to: GCallback.self), data, nil, GConnectFlags(rawValue: 0))
}

/// Offers `text` as plain text when a drag starts from a drag source.
func offerOnDrag(_ source: UnsafeMutableRawPointer, _ text: String) {
    let handler: @convention(c) (UnsafeMutableRawPointer?, Double, Double, UnsafeMutableRawPointer?) -> UnsafeMutablePointer<GdkContentProvider>? = { _, _, _, data in
        guard let data else { return nil }
        let bytes = g_bytes_new(data, gsize(strlen(data.assumingMemoryBound(to: CChar.self))))
        return gdk_content_provider_new_for_bytes("text/plain;charset=utf-8", bytes)
    }
    g_signal_connect_data(source, "prepare", unsafeBitCast(handler, to: GCallback.self), UnsafeMutableRawPointer(strdup(text)), nil, GConnectFlags(rawValue: 0))
}

/// A Swift closure GTK can call back with dropped text.
final class TextCallback {
    let run: (String) -> Void

    init(_ run: @escaping (String) -> Void) {
        self.run = run
    }
}

/// Accepts dropped text on `widget`, handing it to `run`.
func acceptDrops(on widget: OpaquePointer, _ run: @escaping (String) -> Void) {
    let target = gtk_drop_target_new(GType(16 << 2), GDK_ACTION_COPY)!
    let handler: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<GValue>?, Double, Double, UnsafeMutableRawPointer?) -> Int32 = { _, value, _, _, data in
        guard let data, let value, let text = g_value_get_string(value) else { return 0 }
        Unmanaged<TextCallback>.fromOpaque(data).takeUnretainedValue().run(String(cString: text))
        return 1
    }
    let data = Unmanaged.passRetained(TextCallback(run)).toOpaque()
    g_signal_connect_data(UnsafeMutableRawPointer(target), "drop", unsafeBitCast(handler, to: GCallback.self), data, nil, GConnectFlags(rawValue: 0))
    gtk_widget_add_controller(UnsafeMutablePointer<GtkWidget>(widget), target)
}

/// The fixture's window, with the same identifiers and text as the macOS fixture's.
final class Fixture {
    let builder: OpaquePointer
    var count = 0

    init() {
        builder = gtk_builder_new_from_string(Fixture.interface, -1)
    }

    func object(_ id: String) -> UnsafeMutableRawPointer {
        guard let object = gtk_builder_get_object(builder, id) else { fatalError("the interface has no \(id)") }
        return UnsafeMutableRawPointer(object)
    }

    func widget(_ id: String) -> OpaquePointer {
        OpaquePointer(object(id))
    }

    func typed<T>(_ id: String, as type: T.Type) -> UnsafeMutablePointer<T> {
        object(id).assumingMemoryBound(to: type)
    }

    func show(in application: OpaquePointer) {
        let window = typed("fixture-window", as: GtkWindow.self)
        let sheet = typed("sheet-window", as: GtkWindow.self)
        let sheetWidget = typed("sheet-window", as: GtkWidget.self)
        gtk_window_set_application(window, UnsafeMutablePointer<GtkApplication>(application))
        gtk_window_set_transient_for(sheet, window)
        on(object("increment-button"), "clicked") { [unowned self] in
            count += 1
            gtk_label_set_text(widget("count-value"), "\(count)")
        }
        on(object("name-field"), "changed") { [unowned self] in
            let name = String(cString: gtk_editable_get_text(widget("name-field")))
            gtk_label_set_text(widget("greeting"), name.isEmpty ? "Hello, nobody" : "Hello, \(name)")
        }
        on(object("show-sheet-button"), "clicked") { gtk_window_present(sheet) }
        let menuResult = widget("menu-result")
        for (name, title) in [("new", "New"), ("open-report", "Report.txt"), ("copy", "Copy")] {
            let action = g_simple_action_new(name, nil)!
            onActivate(action) { gtk_label_set_text(menuResult, "Chose: \(title)") }
            g_action_map_add_action(OpaquePointer(window), action)
        }
        let reset = g_simple_action_new("reset-count", nil)!
        onActivate(reset) { [unowned self] in
            count = 0
            gtk_label_set_text(widget("count-value"), "0")
        }
        g_action_map_add_action(OpaquePointer(window), reset)
        onPressed(object("canvas-click")) { [unowned self] x, y in
            gtk_label_set_text(widget("click-result"), "Clicked at \(Int(x)),\(Int(y))")
        }
        offerOnDrag(object("drag"), "token")
        acceptDrops(on: widget("drop-target")) { [unowned self] text in
            gtk_label_set_text(widget("drop-target"), "Dropped: \(text)")
        }
        onEnter(object("hover-motion")) { [unowned self] in gtk_label_set_text(widget("hover-target"), "Hovering: yes") }
        on(object("hover-motion"), "leave") { [unowned self] in gtk_label_set_text(widget("hover-target"), "Hovering: no") }
        let contextMenu = gtk_popover_menu_new_from_model(object("context-menu").assumingMemoryBound(to: GMenuModel.self))!
        gtk_widget_set_parent(contextMenu, UnsafeMutablePointer<GtkWidget>(widget("context-target")))
        onPressed(object("context-click")) { _, _ in gtk_popover_popup(UnsafeMutableRawPointer(contextMenu).assumingMemoryBound(to: GtkPopover.self)) }
        for (name, choice) in [("mark-done", "done"), ("mark-later", "later")] {
            let action = g_simple_action_new(name, nil)!
            onActivate(action) { [unowned self] in gtk_label_set_text(widget("context-result"), "Chosen: \(choice)") }
            g_action_map_add_action(OpaquePointer(window), action)
        }
        on(object("sheet-done-button"), "clicked") { gtk_widget_set_visible(sheetWidget, 0) }
        gtk_window_present(window)
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func child(_ object: String) -> String {
        "<child>\(object)</child>"
    }

    static func label(_ text: String, id: String? = nil, heading: Bool = false) -> String {
        let style = heading ? "<style><class name=\"heading\"/></style>" : ""
        return "<object class=\"GtkLabel\"\(id.map { " id=\"\($0)\"" } ?? "")><property name=\"label\">\(escape(text))</property><property name=\"xalign\">0</property>\(style)</object>"
    }

    static func button(_ text: String, id: String, sensitive: Bool = true) -> String {
        "<object class=\"GtkButton\" id=\"\(id)\"><property name=\"label\">\(escape(text))</property><property name=\"sensitive\">\(sensitive)</property></object>"
    }

    static func named(_ name: String) -> String {
        "<accessibility><property name=\"label\">\(escape(name))</property></accessibility>"
    }

    static func box(_ children: [String], vertical: Bool = true, spacing: Int = 8, margin: Int = 0, id: String? = nil, homogeneous: Bool = false) -> String {
        let orientation = vertical ? "vertical" : "horizontal"
        let margins = margin > 0 ? ["start", "end", "top", "bottom"].map { "<property name=\"margin-\($0)\">\(margin)</property>" }.joined() : ""
        return "<object class=\"GtkBox\"\(id.map { " id=\"\($0)\"" } ?? "")><property name=\"orientation\">\(orientation)</property><property name=\"spacing\">\(spacing)</property><property name=\"homogeneous\">\(homogeneous)</property>\(margins)\(children.map(child).joined())</object>"
    }

    static var interface: String {
        let basics = [
            label("Basics", heading: true),
            box([label("Count"), label("0", id: "count-value")], vertical: false),
            button("Increment", id: "increment-button"),
            button("Locked", id: "locked-button", sensitive: false),
            "<object class=\"GtkEntry\" id=\"name-field\"><property name=\"placeholder-text\">Name</property>\(named("Name"))</object>",
            label("Hello, nobody", id: "greeting"),
            box([label("Enabled"), "<object class=\"GtkSwitch\" id=\"enabled-toggle\">\(named("Enabled"))</object>"], vertical: false),
        ]
        let pickers = [
            label("Pickers", heading: true),
            """
            <object class="GtkDropDown" id="flavor-picker">\(named("Flavor"))<property name="model"><object class="GtkStringList"><items>\
            <item>Vanilla</item><item>Chocolate</item><item>Strawberry</item></items></object></property></object>
            """,
            """
            <object class="GtkScale" id="volume-slider"><property name="draw-value">false</property>\(named("Volume"))\
            <property name="adjustment"><object class="GtkAdjustment"><property name="lower">0</property><property name="upper">1</property>\
            <property name="value">0.5</property><property name="step-increment">0.1</property></object></property></object>
            """,
            button("Show Sheet", id: "show-sheet-button"),
        ]
        let rows = (1...30).map { label("Row \($0)", id: "row-\($0)") }
        let rowList = """
            <object class="GtkScrolledWindow" id="rows-scroll"><property name="min-content-height">90</property>\
            <property name="hscrollbar-policy">never</property>\(child(box(rows, spacing: 6)))</object>
            """
        let menus = [
            label("Menus", heading: true),
            "<object class=\"GtkPopoverMenuBar\" id=\"menu-bar\"><property name=\"menu-model\">menubar</property></object>",
            "<object class=\"GtkMenuButton\" id=\"more-button\"><property name=\"label\">More</property><property name=\"menu-model\">more-menu</property></object>",
            label("Chose: nothing", id: "menu-result"),
        ]
        let pointer = [
            label("Pointer", heading: true),
            """
            <object class="GtkBox" id="click-canvas"><property name="height-request">70</property>\(named("Click canvas"))\
            <style><class name="card"/></style>\(child(label("Click canvas")))<child><object class="GtkGestureClick" id="canvas-click"/></child></object>
            """,
            label("No clicks yet", id: "click-result"),
            box([
                "<object class=\"GtkLabel\" id=\"drag-source\"><property name=\"label\">Drag me</property><child><object class=\"GtkDragSource\" id=\"drag\"/></child></object>",
                "<object class=\"GtkLabel\" id=\"drop-target\"><property name=\"label\">Nothing dropped</property><property name=\"width-request\">160</property><property name=\"height-request\">40</property></object>",
            ], vertical: false, spacing: 40),
            "<object class=\"GtkLabel\" id=\"hover-target\"><property name=\"label\">Hovering: no</property><property name=\"xalign\">0</property><child><object class=\"GtkEventControllerMotion\" id=\"hover-motion\"/></child></object>",
            """
            <object class="GtkBox" id="context-target">\(named("Right-click me"))\(child(label("Right-click me")))\
            <child><object class="GtkGestureClick" id="context-click"><property name="button">3</property></object></child></object>
            """,
            label("Not chosen", id: "context-result"),
        ]
        let content = box([
            box(basics + pickers + menus), box(pointer + [label("Rows", heading: true), rowList]),
        ], vertical: false, spacing: 24, margin: 16, homogeneous: true)
        let sheet = box([
            label("A sheet", id: "sheet-title", heading: true),
            "<object class=\"GtkEntry\" id=\"sheet-field\"><property name=\"placeholder-text\">Note</property>\(named("Note"))</object>",
            button("Done", id: "sheet-done-button"),
        ], spacing: 12, margin: 24)
        func item(_ title: String, _ action: String?) -> String {
            "<item><attribute name=\"label\">\(title)</attribute>\(action.map { "<attribute name=\"action\">win.\($0)</attribute>" } ?? "")</item>"
        }
        let menuModels = """
            <menu id="menubar">\
            <submenu><attribute name="label">File</attribute><section>\(item("New", "new"))\
            <submenu><attribute name="label">Open Recent</attribute>\(item("Report.txt", "open-report"))</submenu></section></submenu>\
            <submenu><attribute name="label">Edit</attribute><section>\(item("Copy", "copy"))\(item("Paste", nil))</section></submenu>\
            </menu>
            <menu id="more-menu"><section>\(item("Reset Count", "reset-count"))</section></menu>
            <menu id="context-menu"><section>\(item("Mark as done", "mark-done"))\(item("Mark as later", "mark-later"))</section></menu>
            """
        return """
            <interface>
            \(menuModels)
            <object class="GtkApplicationWindow" id="fixture-window"><property name="title">Harness Fixture</property>\
            <property name="default-width">880</property><property name="default-height">620</property>\
            \(child("<object class=\"GtkScrolledWindow\"><property name=\"hscrollbar-policy\">never</property>\(child(content))</object>"))</object>
            <object class="GtkWindow" id="sheet-window"><property name="title">Sheet</property><property name="modal">true</property>\
            <property name="hide-on-close">true</property><property name="default-width">280</property>\(child(sheet))</object>
            </interface>
            """
    }
}

g_set_prgname("harness-fixture")
g_set_application_name("Harness Fixture")
let application = gtk_application_new("io.github.therogue76.HarnessFixture", GApplicationFlags(rawValue: 1 << 5))!
var fixture: Fixture?
on(UnsafeMutableRawPointer(application), "activate") {
    let made = Fixture()
    fixture = made
    made.show(in: OpaquePointer(application))
}
let status = g_application_run(UnsafeMutableRawPointer(application).assumingMemoryBound(to: GApplication.self), 0, nil)
exit(status)
