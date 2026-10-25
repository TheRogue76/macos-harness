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

    static func box(_ children: [String], vertical: Bool = true, spacing: Int = 8, margin: Int = 0, id: String? = nil) -> String {
        let orientation = vertical ? "vertical" : "horizontal"
        let margins = margin > 0 ? ["start", "end", "top", "bottom"].map { "<property name=\"margin-\($0)\">\(margin)</property>" }.joined() : ""
        return "<object class=\"GtkBox\"\(id.map { " id=\"\($0)\"" } ?? "")><property name=\"orientation\">\(orientation)</property><property name=\"spacing\">\(spacing)</property>\(margins)\(children.map(child).joined())</object>"
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
        let content = box(basics + pickers + [label("Rows", heading: true), rowList], margin: 16)
        let sheet = box([
            label("A sheet", id: "sheet-title", heading: true),
            "<object class=\"GtkEntry\" id=\"sheet-field\"><property name=\"placeholder-text\">Note</property>\(named("Note"))</object>",
            button("Done", id: "sheet-done-button"),
        ], spacing: 12, margin: 24)
        return """
            <interface>
            <object class="GtkApplicationWindow" id="fixture-window"><property name="title">Harness Fixture</property>\
            <property name="default-width">440</property><property name="default-height">620</property>\
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
