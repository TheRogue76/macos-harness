import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import GObject from 'gi://GObject';
import Meta from 'gi://Meta';
import Mtk from 'gi://Mtk';
import St from 'gi://St';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as PanelMenu from 'resource:///org/gnome/shell/ui/panelMenu.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

const BUS_NAME = 'org.gnome.Shell.Extensions.MacosHarness';
const OBJECT_PATH = '/org/gnome/Shell/Extensions/MacosHarness';
const INTERFACE = `<node>
  <interface name="org.gnome.Shell.Extensions.MacosHarness">
    <method name="List"><arg type="s" direction="out" name="windows"/></method>
    <method name="Layout"><arg type="s" direction="out" name="layout"/></method>
    <method name="Activate"><arg type="t" direction="in" name="id"/><arg type="b" direction="out" name="done"/></method>
    <method name="PlaceNear"><arg type="t" direction="in" name="id"/><arg type="i" direction="in" name="x"/><arg type="i" direction="in" name="y"/><arg type="b" direction="out" name="done"/></method>
    <method name="ShowIcon"><arg type="s" direction="in" name="title"/><arg type="b" direction="in" name="attention"/></method>
    <method name="HideIcon"/>
    <signal name="IconClicked"><arg type="i" name="x"/><arg type="i" name="y"/></signal>
    <property name="Version" type="u" access="read"/>
  </interface>
</node>`;

const SHOWN_TYPES = [Meta.WindowType.NORMAL, Meta.WindowType.DIALOG, Meta.WindowType.MODAL_DIALOG, Meta.WindowType.UTILITY];

/** The windows people use, as Mutter knows them. */
function windows() {
    return global.get_window_actors()
        .map(actor => actor.get_meta_window())
        .filter(window => window && !window.is_override_redirect() && SHOWN_TYPES.includes(window.get_window_type()));
}

/**
 * What macOS Harness reads over D-Bus: where windows are, bringing one forward, placing its own
 * panel, and its icon in the top bar, as on the Mac's menu bar.
 */
class WindowService {
    constructor(extension) {
        this._extension = extension;
    }

    get Version() {
        return 3;
    }

    List() {
        return JSON.stringify(windows().map(window => {
            const frame = window.get_frame_rect();
            return {
                id: window.get_id(),
                pid: window.get_pid(),
                title: window.get_title() ?? '',
                wmClass: window.get_wm_class() ?? '',
                appId: window.get_gtk_application_id() ?? window.get_sandboxed_app_id() ?? '',
                x: frame.x,
                y: frame.y,
                width: frame.width,
                height: frame.height,
                focused: window.has_focus(),
                minimized: window.minimized,
                monitor: window.get_monitor(),
            };
        }));
    }

    Layout() {
        const display = global.display;
        const monitors = [];
        for (let index = 0; index < display.get_n_monitors(); index++) {
            const geometry = display.get_monitor_geometry(index);
            monitors.push({x: geometry.x, y: geometry.y, width: geometry.width, height: geometry.height, scale: display.get_monitor_scale(index)});
        }
        return JSON.stringify({width: global.stage.width, height: global.stage.height, monitors});
    }

    Activate(id) {
        const window = windows().find(candidate => candidate.get_id() === id);
        if (!window)
            return false;
        Main.activateWindow(window);
        return true;
    }

    /** Puts one of macOS Harness's own windows just below a point, such as its tray icon, inside the work area. */
    PlaceNear(id, x, y) {
        const window = windows().find(candidate => candidate.get_id() === id);
        if (!window || !(window.get_gtk_application_id() ?? '').startsWith('io.github.therogue76.MacosHarness'))
            return false;
        const display = global.display;
        const monitor = display.get_monitor_index_for_rect(new Mtk.Rectangle({x, y, width: 1, height: 1}));
        const area = global.workspace_manager.get_active_workspace().get_work_area_for_monitor(monitor < 0 ? display.get_primary_monitor() : monitor);
        const frame = window.get_frame_rect();
        const left = Math.min(Math.max(x - Math.round(frame.width / 2), area.x + 8), area.x + area.width - frame.width - 8);
        const top = y > area.y + area.height / 2 ? area.y + area.height - frame.height - 6 : area.y + 6;
        window.move_frame(true, left, top);
        return true;
    }

    /** Shows the icon in the top bar while the helper that asked keeps running. */
    ShowIconAsync([title, attention], invocation) {
        this._extension.showIcon(invocation.get_sender(), title, attention);
        invocation.return_value(null);
    }

    HideIconAsync(_parameters, invocation) {
        this._extension.hideIcon();
        invocation.return_value(null);
    }
}

/** The icon in the top bar: the Control Tower glyph, with an orange dot when it needs attention. */
const HarnessIcon = GObject.registerClass(
class HarnessIcon extends PanelMenu.Button {
    _init(path, onClick) {
        super._init(0.5, 'macOS Harness', true);
        this._onClick = onClick;
        const stack = new St.Widget({layout_manager: new Clutter.BinLayout()});
        this._glyph = new St.Icon({gicon: Gio.icon_new_for_string(`${path}/icons/macos-harness-symbolic.svg`), style_class: 'system-status-icon'});
        this._dot = new St.Widget({style: 'background-color: #FF450F; border-radius: 4px; width: 7px; height: 7px;',
            x_align: Clutter.ActorAlign.END, y_align: Clutter.ActorAlign.START, visible: false});
        stack.add_child(this._glyph);
        stack.add_child(this._dot);
        this.add_child(stack);
    }

    update(title, attention) {
        this.accessible_name = title;
        this._dot.visible = attention;
    }

    vfunc_event(event) {
        if (event.type() === Clutter.EventType.BUTTON_PRESS || event.type() === Clutter.EventType.TOUCH_BEGIN) {
            const [x, y] = this.get_transformed_position();
            const [width, height] = this.get_transformed_size();
            this._onClick(Math.round(x + width / 2), Math.round(y + height));
            return Clutter.EVENT_STOP;
        }
        return Clutter.EVENT_PROPAGATE;
    }
});

/** Exports the window service while the extension is enabled. */
export default class MacosHarnessExtension extends Extension {
    enable() {
        this._object = Gio.DBusExportedObject.wrapJSObject(INTERFACE, new WindowService(this));
        this._object.export(Gio.DBus.session, OBJECT_PATH);
        this._owner = Gio.bus_own_name_on_connection(Gio.DBus.session, BUS_NAME, Gio.BusNameOwnerFlags.NONE, null, null);
    }

    /** Adds the icon, or updates it, and removes it when `sender` (the helper) leaves the bus. */
    showIcon(sender, title, attention) {
        if (!this._icon) {
            this._icon = new HarnessIcon(this.path, (x, y) =>
                this._object?.emit_signal('IconClicked', new GLib.Variant('(ii)', [x, y])));
            Main.panel.addToStatusArea(this.uuid, this._icon);
        }
        this._icon.update(title, attention);
        if (this._iconOwner !== sender) {
            if (this._iconWatch)
                Gio.bus_unwatch_name(this._iconWatch);
            this._iconOwner = sender;
            this._iconWatch = Gio.bus_watch_name_on_connection(Gio.DBus.session, sender, Gio.BusNameWatcherFlags.NONE,
                null, () => this.hideIcon());
        }
    }

    hideIcon() {
        if (this._iconWatch)
            Gio.bus_unwatch_name(this._iconWatch);
        this._iconWatch = 0;
        this._iconOwner = null;
        this._icon?.destroy();
        this._icon = null;
    }

    disable() {
        this.hideIcon();
        Gio.bus_unown_name(this._owner);
        this._object.unexport();
        this._object = null;
        this._owner = 0;
    }
}
