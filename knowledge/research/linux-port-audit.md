---
type: Analysis
title: Linux port audit
description: How much of the 1.0 source is macOS-specific, how each macOS API family maps to Linux on GNOME, KDE and wlroots Wayland, and what was measured on a GNOME 50 desktop.
tags: [linux, wayland, audit, at-spi, portals, gnome, kde, wlroots, 2.0]
status: draft
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-25T15:45:00Z }
verified: { by: claude-code/claude-opus-5-5, at: 2026-10-25T15:45:00Z }
stale_after: 2027-04-25T00:00:00Z
sources:
  - id: source-read
    resource: Every file in Sources/, Package.swift, Tests/, scripts/, .github/workflows/, flows/ and docs/ at 2c1bf5b (Release 1.0.0)
    title: Source audit
    author: claude-code/claude-opus-5-5
  - id: probe
    resource: "busctl, gdbus and python3-gi (Atspi 2.0) probes on Ubuntu 26.04.1, GNOME Shell 50.1 on Wayland, GTK 4.22.4, at-spi2 2.60.4, Swift 6.4.1, 2026-10-25"
    title: GNOME 50 probe
    author: claude-code/claude-opus-5-5
  - id: se-0458
    resource: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0458-strict-memory-safety.md
    title: "SE-0458: Opt-in Strict Memory Safety Checking"
---

# Question

How much of macos-harness 1.0 is tied to macOS, and how would each part
work on Linux? The owner's targets for 2.0 are GNOME, KDE Plasma and
wlroots compositors (Sway, Hyprland), all on Wayland. X11 sessions are out
of scope.[^source-read]

# How much is macOS-specific

Source is 23,337 lines of Swift, plus 4,939 lines of tests.

| Module | Lines | Portable as-is or with small fixes | macOS-bound | Main blockers |
|---|---|---|---|---|
| HarnessProtocol | 2,388 | ~97% | `LineSocket`, `HarnessPaths` | `Darwin.` qualified calls, `SO_NOSIGPIPE`, `~/Library` paths |
| HarnessClient | 3,887 | ~90% | helper discovery and launch | `_NSGetExecutablePath`, `.app` bundles, `open -b`; `AppBuilder` is Xcode-only |
| CLI (`Sources/macos-harness`) | 2,483 | ~90% | `record frames` (AVFoundation) | platform-only subcommands (`sim`, `build`, `menu`) need gating |
| HarnessCore | 11,852 | ~40% | ~60% | AX, CGEvent, CGWindowList, ScreenCaptureKit, SkyLight, Vision, TIS, NSWorkspace, NSPasteboard, Security |
| MacosHarnessHelper | 2,536 | ~30% (models, handlers) | ~70% (AppKit/SwiftUI UI, Carbon hotkey) | rewrite the UI |
| HarnessFixture | 191 | 0% | 100% | needs a GTK4 twin |
| Total | 23,337 | ~55% | ~45% (~10,500 lines) | |

Nothing compiles on Linux today: `HarnessProtocol` stops at `import Darwin`
in `LineSocket.swift`, and `HarnessCore` is a single module that imports
AppKit, so every test target is blocked too.

Portable logic worth keeping as-is, once its platform imports move out:
`TreeShaper`, `ElementSearch`, the settle diffing in `Actions`, the
lease and turns in `RealInput`, `Router`, `Journal`, `Activity`,
`InstanceNames`, `WindowClaims`, `Policy` (minus app lookup), the adb layer,
flows, MCP server, rendering and every wire type.

The tree vocabulary is AX (`AXButton`, `AXPress`) all the way into the
protocol. `AndroidTree` already maps another platform onto it, so a Linux
backend does the same with AT-SPI roles and actions.

`AXUIElement`, `CGWindowID`, `CGImage`, `CGKeyCode`/`CGEventFlags`,
`NSScreen`, `NSRunningApplication` and `NSPasteboard` appear in signatures
across HarnessCore (`AXUIElement` alone in 17 files), so the split needs an
opaque element handle, a platform-neutral window id, a `Bitmap` type and an
abstract `Key`.

# API mapping

| macOS (1.0) | GNOME | KDE Plasma | wlroots (Sway, Hyprland) |
|---|---|---|---|
| AX tree read (`AXUIElementCopyMultipleAttributeValues`) | AT-SPI2 over D-Bus, `Cache.GetItems` for bulk reads | same | same |
| `AXPress`, `AXValue`, focus, select, increment | AT-SPI `Action.DoAction`, `EditableText`, `Value`, `Component.GrabFocus`, `Selection` | same | same |
| `AXScrollToVisible` | `Component.ScrollTo` | same | same |
| Element frames in screen points | AT-SPI extents are window-relative on Wayland; add the window origin from the window backend | same | same |
| `CGWindowListCopyWindowInfo`, window ids, stacking | Shell extension (Mutter `MetaWindow`); `Introspect.GetWindows` is denied to us | `org_kde_plasma_window_management` Wayland protocol, KWin D-Bus `getWindowInfo` | Sway/Hyprland IPC sockets (JSON with geometry and pids), `ext-foreign-toplevel-list` |
| Raise, move, resize, minimize | Shell extension | plasma window management, KWin scripting over D-Bus | IPC commands, `wlr-foreign-toplevel-management` |
| ScreenCaptureKit window capture | ScreenCast portal (PipeWire); Mutter `ScreenCast` D-Bus as fallback; extension for window ids | ScreenCast portal; KWin `ScreenShot2` with a restricted-interface grant | `ext-image-copy-capture`/`wlr-screencopy`, no prompt |
| `CGEvent` posting | RemoteDesktop portal plus libei; Mutter `RemoteDesktop` D-Bus as fallback; uinput | RemoteDesktop portal plus libei; uinput | virtual-pointer/virtual-keyboard protocols, libei where the portal exists, uinput |
| SkyLight background clicks | none | none | none |
| `CGWarpMouseCursorPosition`, cursor location | extension (`global.get_pointer`) | KWin scripting | Sway/Hyprland IPC |
| `keyboardSetUnicodeString` | AT-SPI `EditableText`, paste, keysym remap via xkbcommon | same | same |
| TIS/UCKeyTranslate layouts | xkbcommon from the compositor's keymap | same | same |
| `NSPasteboard` | extension (`St.Clipboard`); Mutter lacks data-control | `ext-data-control-v1` | `ext-data-control-v1` |
| Vision OCR | Tesseract | same | same |
| SCRecordingOutput | ScreenCast node into GStreamer or ffmpeg | same | wf-recorder style screencopy, or ffmpeg |
| Menu bar (`AXMenuBar`) | AT-SPI menu bars (GTK3, Qt); GTK4 apps use header-bar popovers | AT-SPI; global menu over DBusMenu | AT-SPI |
| Menu bar extras | StatusNotifierItem plus DBusMenu (needs the AppIndicator extension on stock GNOME) | SNI plus DBusMenu | SNI plus DBusMenu (waybar) |
| `NSWorkspace` launch and quit | `.desktop` files via Gio, `xdg-activation` tokens; `SIGTERM` | same | same |
| `LOCAL_PEERPID`, `proc_pidpath`, `sysctl` | `SO_PEERCRED`/`SO_PEERPIDFD`, `/proc/<pid>/{exe,cmdline,cwd,stat,cgroup}` | same | same |
| Code-signing identity of callers | none; exe path and hash, package ownership, systemd scope | same | same |
| TCC permissions | a11y bus status, portal grants and restore tokens, `/dev/uinput` access | same | same |
| Carbon stop hotkey | GlobalShortcuts portal (version 1 on GNOME 50) | GlobalShortcuts portal | GlobalShortcuts where available, otherwise a compositor key binding that runs a new stop command |
| `CGEventSource` idle time | Mutter `IdleMonitor`, `ext-idle-notify-v1` | `ext-idle-notify-v1` | `ext-idle-notify-v1` |
| `CGSSessionScreenIsLocked` | logind `LockedHint` | same | same |
| Overlay panels | extension (Clutter actors) | `wlr-layer-shell` | `wlr-layer-shell` |
| `~/Library/...` paths | `$XDG_RUNTIME_DIR`, `$XDG_STATE_HOME`, `$XDG_CONFIG_HOME` | same | same |
| iOS Simulator (M8) | not possible | not possible | not possible |
| Android (M9) | adb works as-is; emulator needs `/dev/kvm` | same | same |

# Element actions work in the background

AT-SPI is a separate D-Bus channel into each app's accessibility code. An
`Action.DoAction` on a button runs the widget's own activate handler: no
input event is made, and the window can be covered, unfocused or on another
workspace. This is the Linux counterpart of `AXPress` and needs nothing
beyond the a11y bus, which GTK4 apps join by themselves. What has no Linux
counterpart is coordinate input (click, drag, wheel at a point) into a
window that isn't in front, which SkyLight gives on macOS.

# Measured on GNOME 50 (Wayland)

- Portals present: RemoteDesktop 2, ScreenCast 5, Screenshot 2,
  GlobalShortcuts 1, InputCapture 1, Background 2.[^probe]
- `org.a11y.Status.IsEnabled` was `false`, yet the AT-SPI registry still
  listed GTK4, Chrome, VS Code and Electron apps.
- GTK 4.22 fills `accessible-id`: 51 of the first 101 Nautilus nodes had
  one, so `id:` selectors can carry over.
- AT-SPI `GetExtents(SCREEN)` returned `(0, 0)` origins for every frame, so
  screen coordinates must come from the compositor.
- `org.gnome.Shell.Introspect.GetWindows` and `GetRunningApplications`
  answered `AccessDenied`.
- `org.gnome.Mutter.ScreenCast.CreateSession` and
  `org.gnome.Mutter.RemoteDesktop.CreateSession` succeeded with no prompt,
  and `DisplayConfig.GetCurrentState` returned the monitor layout. These are
  private APIs that gnome-remote-desktop uses.
- `/dev/uinput` is `root:root 0660` with an ACL; the user isn't in an
  `input` group.

# Unsafe code today (for SE-0458)

`-strict-memory-safety`[^se-0458] would flag, across the package, about 25
`withUnsafe*` calls, 24 unsafe pointer types, 6 `Unmanaged`, 19
`@unchecked Sendable`, 7 `nonisolated(unsafe)`, 8 `unsafeBitCast` and 11
`dlsym` sites. Most are in `BackgroundClick`, `AX` (remote tokens),
`KeyLayout`, `ProcessInspector`, `WindowService` (`@_silgen_name`), the
spikes and the fixture's SkyLight calls; the rest are socket calls and
lock-guarded classes that can become `Mutex`. SwiftPM's
`.strictMemorySafety()` setting with `.treatAllWarnings(as: .error)` works
on Swift 6.4.1 for Linux (tools version 6.2).
