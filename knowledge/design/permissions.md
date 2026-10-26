---
type: Design
title: Permissions and setup
description: The `permissions` command (status, grant, reset) on macOS and Linux, what each desktop asks for and where it keeps the answer, the missing-permission notification on Linux, and publishing the GNOME extension on extensions.gnome.org.
tags: [design, permissions, linux, gnome, macos, setup, portals]
status: draft
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-26T12:40:00Z }
sources:
  - id: shell-extensions-dbus
    resource: https://gitlab.gnome.org/GNOME/gnome-shell/-/blob/main/data/dbus-interfaces/org.gnome.Shell.Extensions.xml
    title: GNOME Shell's org.gnome.Shell.Extensions D-Bus interface
  - id: permission-store
    resource: https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.impl.portal.PermissionStore.html
    title: xdg-desktop-portal PermissionStore
  - id: ego-review
    resource: https://gjs.guide/extensions/review-guidelines/review-guidelines.html
    title: extensions.gnome.org review guidelines
---

# The goal

Granting and taking back what the harness needs should take one command and
the system's own dialogs, with the harness saying before each dialog what it
will ask. The same command works on both platforms:

```bash
macos-harness permissions               # status: one line per item, with its id
macos-harness permissions grant [item]  # each missing item in turn
macos-harness permissions reset [item]  # asks first; --yes for scripts
```

The RPC is `permissions` (`PermissionsMethod`), with `action` (status,
grant, reset) and an optional `item`. It needs no pairing, like `doctor`:
granting only shows dialogs the user answers. Resetting is refused when a
known coding agent is behind the caller, since an agent could otherwise take
away every agent's access with `--yes`; the user runs it in their own
terminal. Prompts name the variant, so the dev build says "macOS Harness
Dev", as System Settings lists it. Items have an `id`, a `name`, a `state` (`granted`,
`missing`, `notNeeded`, `unsupported`), a `detail` and a `prompt`, the
sentence the CLI prints before the dialog. `doctor` shows the items on Linux
and is unhealthy while one is missing.

The CLI grants one item per call, so it can print each prompt first. When
an item is still missing after its call and more follow (macOS, where the
user flips a switch in System Settings), it waits for it, up to three
minutes, before opening the next.

# macOS

| id | Grant | Reset |
| --- | --- | --- |
| `accessibility` | The system prompt, then System Settings at Accessibility | `tccutil reset Accessibility <bundle ID>` |
| `screen-recording` | The system prompt, then System Settings at Screen Recording; applies after a helper restart | `tccutil reset ScreenCapture <bundle ID>` |

The menu bar app's setup window stays the main path; the command is for
terminals, scripts and starting over.

# Linux

| id | Sway and wlroots | GNOME | KDE | Where the answer is kept |
| --- | --- | --- | --- | --- |
| `accessibility` | The accessibility bus, no grant | The same | The same | Nowhere: missing only without at-spi2-core |
| `windows` | Sway IPC, no grant | The harness's Shell extension | KWin scripts, no grant | GNOME: the extension being installed and enabled |
| `screenshots` | wlr-screencopy, no grant | The Screenshot portal | The Screenshot portal | Permission store table `screenshot`, id `screenshot`, app `""`[^permission-store] |
| `input` | Virtual pointer and keyboard, no grant | The RemoteDesktop portal | The RemoteDesktop portal | Our restore token file (one per desktop), and table `remote-desktop` with the token as id |

KDE's portal also skips its remote control dialog for an app with `yes`
in table `kde-authorized`, id `remote-desktop`; the headless desktop sets
that for app `""`, since nobody can answer a dialog there, but the harness
never sets it on a real desktop. Other desktops show `unsupported`, and so does every item
without a Wayland session (CI's containers).

On GNOME, `grant`:

- **windows**: turns user extensions on if they're off
  (`UserExtensionsEnabled`), then `InstallRemoteExtension(uuid)`, GNOME's
  own dialog that downloads from extensions.gnome.org and loads the
  extension without logging out[^shell-extensions-dbus]. An extension
  installed but turned off is turned on with `EnableExtension`. Files on
  disk that Shell hasn't loaded (a package installed them after log-in) are
  added to `org.gnome.shell enabled-extensions`, and the user is told to log
  out and back in.
- **screenshots**: takes one non-interactive screenshot and throws it away.
- **input**: closes any session, starts one (GNOME asks, the user turns on
  Allow Remote Interaction) and closes it, keeping the new token.

`reset` closes the input session, deletes the token's `remote-desktop`
entry and the token file, deletes app `""` from the `screenshot` entry, and
uninstalls a user-installed extension (`UninstallExtension`) or turns off
one installed for all users. The screenshot answer belongs to every
unsandboxed app, not the harness alone, so resetting it makes them all ask
again, and granting it lets them all take screenshots; the security model
says so.

On GNOME 50 the Extensions interface lives at `/org/gnome/Shell/Extensions`
on `org.gnome.Shell.Extensions`, not `/org/gnome/Shell`.
`GetExtensionInfo` returns an empty dictionary for an extension Shell
doesn't know; `type` is 1 for system and 2 for per-user, and `state` 3 and 4
are error and out of date.

## The notification

When an agent's request fails for a missing GNOME item (no extension, a
screenshot or remote desktop dialog answered no), the helper posts a
notification with a **Set up** button, at most every ten minutes per item.
Set up runs `grant` for every missing item and then says how it went. The
error the agent gets names the `permissions grant` command too.

# Publishing the extension

extensions.gnome.org wants the D-Bus name under the extension's own
namespace, so the extension owns `org.gnome.Shell.Extensions.MacosHarness`
at `/org/gnome/Shell/Extensions/MacosHarness`[^ego-review]. Reviews take
days, and the listing's UUID has to match `macos-harness@therogue76.github.io`.
`scripts/pack-gnome-extension.sh` builds the zip, with the MIT licence,
which is GPL-compatible as the site requires.

Listing text:

> **macOS Harness windows.** Lets the macOS Harness CLI, which coding
> agents use to see and operate desktop apps, find windows and bring them
> forward. It exports one D-Bus object on your session bus that lists
> normal windows (title, app ID, process ID, position, size, focus) and
> monitors, and activates a window by its ID. It reads nothing else, sends
> no input, has no settings and makes no network connections.
> https://github.com/TheRogue76/macos-harness

Until it's published, and for offline machines, packages ship the extension
too (installed for all users), which works after one log-out; `grant` says
so.
