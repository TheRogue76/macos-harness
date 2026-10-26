#!/usr/bin/env python3
"""A status icon (StatusNotifierItem) with a DBusMenu, for the harness's tests of menu bar extras on
Linux. Its menu has Press, which counts presses in the menu and in the file given as the first
argument, and Quit Extra.

    fixtures/linux/status-item.py /tmp/presses
"""
import os
import sys

from gi.repository import Gio, GLib

ITEM_XML = """
<node><interface name="org.kde.StatusNotifierItem">
  <property name="Category" type="s" access="read"/><property name="Id" type="s" access="read"/>
  <property name="Title" type="s" access="read"/><property name="Status" type="s" access="read"/>
  <property name="IconName" type="s" access="read"/><property name="Menu" type="o" access="read"/>
  <property name="ItemIsMenu" type="b" access="read"/>
  <method name="Activate"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
  <method name="SecondaryActivate"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
  <method name="ContextMenu"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
  <method name="Scroll"><arg type="i" direction="in"/><arg type="s" direction="in"/></method>
</interface></node>
"""

MENU_XML = """
<node><interface name="com.canonical.dbusmenu">
  <property name="Version" type="u" access="read"/><property name="Status" type="s" access="read"/>
  <method name="GetLayout"><arg type="i" direction="in"/><arg type="i" direction="in"/><arg type="as" direction="in"/>
    <arg type="u" direction="out"/><arg type="(ia{sv}av)" direction="out"/></method>
  <method name="GetGroupProperties"><arg type="ai" direction="in"/><arg type="as" direction="in"/>
    <arg type="a(ia{sv})" direction="out"/></method>
  <method name="Event"><arg type="i" direction="in"/><arg type="s" direction="in"/><arg type="v" direction="in"/>
    <arg type="u" direction="in"/></method>
  <method name="AboutToShow"><arg type="i" direction="in"/><arg type="b" direction="out"/></method>
  <signal name="LayoutUpdated"><arg type="u"/><arg type="i"/></signal>
</interface></node>
"""


class StatusItem:
    """The icon, its menu and how many times Press was chosen."""

    def __init__(self, record):
        self.record = record
        self.presses = 0
        self.revision = 1
        self.loop = GLib.MainLoop()
        self.save()

    def save(self):
        """Writes the press count to the record file."""
        with open(self.record, "w") as handle:
            handle.write(f"{self.presses}\n")

    def entries(self):
        """The menu's items as (id, properties) pairs, in order."""
        return [
            (1, {"label": GLib.Variant("s", "_Press")}),
            (2, {"label": GLib.Variant("s", f"Presses: {self.presses}"), "enabled": GLib.Variant("b", False)}),
            (3, {"type": GLib.Variant("s", "separator")}),
            (4, {"label": GLib.Variant("s", "Quit Extra")}),
        ]

    def layout(self):
        """The whole menu as DBusMenu's (ia{sv}av) layout."""
        children = [GLib.Variant("(ia{sv}av)", (number, props, [])) for number, props in self.entries()]
        return (0, {"children-display": GLib.Variant("s", "submenu")}, children)

    def item_call(self, connection, sender, path, interface, method, parameters, invocation):
        """Answers the icon's methods; activating it counts as a press."""
        if method == "Activate":
            self.press()
        invocation.return_value(None)

    def item_property(self, connection, sender, path, interface, name):
        """The icon's properties."""
        values = {
            "Category": GLib.Variant("s", "ApplicationStatus"), "Id": GLib.Variant("s", "harness-fixture-extra"),
            "Title": GLib.Variant("s", "Harness Fixture Extra"), "Status": GLib.Variant("s", "Active"),
            "IconName": GLib.Variant("s", "starred"), "Menu": GLib.Variant("o", "/MenuBar"),
            "ItemIsMenu": GLib.Variant("b", False),
        }
        return values.get(name)

    def menu_call(self, connection, sender, path, interface, method, parameters, invocation):
        """Answers DBusMenu's methods."""
        if method == "GetLayout":
            invocation.return_value(GLib.Variant("(u(ia{sv}av))", (self.revision, self.layout())))
        elif method == "GetGroupProperties":
            wanted = parameters.unpack()[0]
            found = [(number, props) for number, props in self.entries() if number in wanted]
            invocation.return_value(GLib.Variant("(a(ia{sv}))", (found,)))
        elif method == "Event":
            number, event = parameters.unpack()[:2]
            if event == "clicked" and number == 1:
                self.press()
            elif event == "clicked" and number == 4:
                GLib.idle_add(self.loop.quit)
            invocation.return_value(None)
        elif method == "AboutToShow":
            invocation.return_value(GLib.Variant("(b)", (False,)))
        else:
            invocation.return_dbus_error("org.freedesktop.DBus.Error.UnknownMethod", method)

    def menu_property(self, connection, sender, path, interface, name):
        """DBusMenu's properties."""
        return {"Version": GLib.Variant("u", 3), "Status": GLib.Variant("s", "normal")}.get(name)

    def press(self):
        """Counts a press and tells listeners the menu changed."""
        self.presses += 1
        self.revision += 1
        self.save()
        self.bus.emit_signal(None, "/MenuBar", "com.canonical.dbusmenu", "LayoutUpdated", GLib.Variant("(ui)", (self.revision, 0)))

    def run(self):
        """Publishes the icon and its menu, registers with the watcher when there is one, and serves."""
        self.bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        item = Gio.DBusNodeInfo.new_for_xml(ITEM_XML).interfaces[0]
        menu = Gio.DBusNodeInfo.new_for_xml(MENU_XML).interfaces[0]
        register = getattr(self.bus, "register_object_with_closures2", None) or self.bus.register_object
        register("/StatusNotifierItem", item, self.item_call, self.item_property, None)
        register("/MenuBar", menu, self.menu_call, self.menu_property, None)
        name = f"org.kde.StatusNotifierItem-{os.getpid()}-1"
        Gio.bus_own_name_on_connection(self.bus, name, Gio.BusNameOwnerFlags.NONE, None, None)
        try:
            self.bus.call_sync(
                "org.kde.StatusNotifierWatcher", "/StatusNotifierWatcher", "org.kde.StatusNotifierWatcher",
                "RegisterStatusNotifierItem", GLib.Variant("(s)", (name,)), None, Gio.DBusCallFlags.NONE, 2000, None,
            )
        except GLib.Error:
            pass
        self.loop.run()


if __name__ == "__main__":
    StatusItem(sys.argv[1] if len(sys.argv) > 1 else "/dev/null").run()
