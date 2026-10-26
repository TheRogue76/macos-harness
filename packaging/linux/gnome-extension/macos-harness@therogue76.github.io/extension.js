import Gio from 'gi://Gio';
import Meta from 'gi://Meta';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

const BUS_NAME = 'org.gnome.Shell.Extensions.MacosHarness';
const OBJECT_PATH = '/org/gnome/Shell/Extensions/MacosHarness';
const INTERFACE = `<node>
  <interface name="org.gnome.Shell.Extensions.MacosHarness">
    <method name="List"><arg type="s" direction="out" name="windows"/></method>
    <method name="Layout"><arg type="s" direction="out" name="layout"/></method>
    <method name="Activate"><arg type="t" direction="in" name="id"/><arg type="b" direction="out" name="done"/></method>
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

/** What macOS Harness reads over D-Bus: where windows are, and bringing one forward. */
class WindowService {
    get Version() {
        return 1;
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
}

/** Exports the window service while the extension is enabled. */
export default class MacosHarnessExtension extends Extension {
    enable() {
        this._object = Gio.DBusExportedObject.wrapJSObject(INTERFACE, new WindowService());
        this._object.export(Gio.DBus.session, OBJECT_PATH);
        this._owner = Gio.bus_own_name_on_connection(Gio.DBus.session, BUS_NAME, Gio.BusNameOwnerFlags.NONE, null, null);
    }

    disable() {
        Gio.bus_unown_name(this._owner);
        this._object.unexport();
        this._object = null;
        this._owner = 0;
    }
}
