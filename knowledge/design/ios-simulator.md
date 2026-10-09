---
type: Design
title: iOS Simulator targets
description: How `sim:<device>` targets work (Device Hub's window, the bridged iOS tree, device points), the input ladder on a simulator, booting so Device Hub sees the screen, the `sim` and `build` commands, screenshots and recording through simctl, flows, policy and the journal.
tags: [design, m8, ios, simulator, device-hub, flows]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-07T18:20:00Z }
sources:
  - id: roadmap
    resource: /plan/roadmap.md
    title: Roadmap, M8 decisions
  - id: s7
    resource: /research/s7-simulator-window.md
    title: "S7: reaching the iOS Simulator through its window"
  - id: acceptance
    resource: /research/m8-acceptance.md
    title: M8 acceptance run
---

# Targets

Any command that takes `-a`/`app` takes `sim:<device>`: a UDID, a name, or
`sim:booted` for the only booted simulator. `snapshot`, `find`, `screenshot`,
`press` and the other `act` actions, the pointer commands, `wait`, `windows`,
`menu`, `menu-select`, `window` and `record` all work on it. `launch` and
`quit` don't; `sim launch` and `sim terminate` do that.[^roadmap]

The helper reaches the simulator through its Device Hub window with public
macOS APIs only: Device Hub bridges the iOS accessibility tree into its own
AX tree.[^s7] Resolving a `sim:` target:

1. `simctl` finds the device and its screen size (from the device type's
   `capabilities.plist`). It must be booted.
2. Device Hub is launched in the background if it isn't running.
3. A window showing the device whose screen holds its elements is used:
   one remembered, a device window titled `<name> – <runtime>`, or a main
   window with the device selected in its sidebar. If none holds them, the
   helper opens its own main window (File › New Window, without bringing
   Device Hub forward), selects the device, and moves it into a window of
   its own with "Open in New Window". The user's own windows are left
   alone.
4. The content is the `iOSContentGroup` element; everything outside it
   (Device Hub's sidebar and buttons) is ignored.

# Coordinates

Trees, hit points, `--x/--y`, screenshots, crops and grids are in the
device's own points, top-left at 0,0 (402 × 874 on an iPhone 18 Pro),
whatever Device Hub's zoom. Each target carries a coordinate space (the
global frame of the screen group, and device points per screen point),
which Mac windows have too, with a scale of 1. The header says
`<name> (<type>, <runtime>) simulator <UDID> · screen 402x874 points`.

# Acting

AX first, real input second, as on the Mac:

| Agent asks for | On a simulator |
|---|---|
| `press`, `select`, `increment`, `decrement`, `set-value` | AX, in the background |
| `type` | Appends to the field's value through AX (a value equal to the placeholder counts as empty). `--real` taps the field and sends key codes |
| `key` | The on-screen keyboard's key through AX when it shows one (Return also matches Search, Go, Done, Send…); otherwise a real tap on the field, then the key |
| `scroll` | `AXScroll…ByPage` on the element or the screen's main list, about one page per 80% of the screen asked for; a swipe when nothing can scroll |
| `scroll-to` | Pages until the element's center is clear of the bars at the top and bottom |
| `click`, `long-press`, `swipe`, `drag` | Real input in the window: a tap, a long press, a swipe |
| `sim button home`, `rotate-left/right` | Device Hub's own buttons through AX |
| `sim button lock`, `siri`, `app-switcher`, `action` | Device Hub's Controls menu, which brings it forward |

iOS only lists what's on screen, so an action whose selector matches
nothing pages through the screen's main list (down, then up) looking for it
before giving up. Pointer actions on an element first scroll it clear of
the bars.

Key events only reach the simulator when its view is Device Hub's first
responder, which takes a real click; AX can't move that focus.[^s7] Key
codes come from a US keyboard map (the simulator ignores the text attached
to a key event); `type` refuses characters outside it and suggests
set-value.

The bridged tree lags the screen by 1–4 s, so selectors wait up to 5 s for
a match, reads wait for an empty screen to fill, and the settle after an
action waits up to 2 s for a change before calling it unchanged. Elements
whose text changes come back as new elements; the change list pairs them by
identifier and shows `~ old → new`.

# Lifecycle and apps

`sim list|boot|shutdown|install|uninstall|launch|terminate|open-url|button|privacy|push|location|appearance|status-bar|pasteboard`
(MCP: `simulator` with an `action`). Creating, erasing and deleting
simulators stays with the user.[^roadmap]

Device Hub only sees the screens of simulators that were already running
when it started, and quitting it shuts down every simulator it shows.[^s7]
So `sim boot` boots with `simctl` while Device Hub is closed, then opens it
and waits for the home screen's elements (about 50 s from cold). If Device
Hub is open and no simulator is running, it's quit first, which loses
nothing, and reopened; if other simulators are running, it's left alone
and the boot reports when Device Hub can't see the new one. The harness
never quits Device Hub while a simulator runs.

`build` runs `xcodebuild` for the simulator in the client, not the
helper: it finds the project or workspace and the only scheme, writes the
full log to `~/Library/Logs/macos-harness/builds`, reports errors, and
finds the `.app` and its bundle ID from the build settings. `--run`
installs and launches it. The MCP `build` tool returns at once with an ID;
`build_status` reports progress and the result, since builds outlast MCP
tool timeouts.

# Seeing and recording

Screenshots come from `simctl io screenshot`: the device's own pixels, no
window and no Screen Recording permission needed. `record` uses `simctl io
recordVideo` and stops it with an interrupt so the file is finished.

# Flows

`app: "sim:${device}"` targets a simulator. New steps:

```yaml
setup:
  - build: { project: ../../fixtures/ios/HarnessFixtureiOS.xcodeproj, scheme: HarnessFixtureiOS, launch: true }
steps:
  - long-press: { id: hold-target, hold: 1 }
  - swipe: { id: card, left: 200 }       # where the finger moves
  - sim: { action: button, button: home } # device defaults to the flow's sim: target
teardown:
  - sim: { action: terminate, bundle_id: io.github.therogue76.HarnessFixtureiOS }
```

`flows/ios/fixture.yaml` runs against the fixture app in
`fixtures/ios` (one of each control, all with identifiers), which builds in
seconds and needs no signing. CI runs it on GitHub's `xcode-27` image with a
simulator it creates and boots. `flow export` turns `simulator` calls into
`sim:` steps.

# Policy and journal

The policy names every simulator `Simulator`: `read_only: [Simulator]`
allows snapshot, find and screenshot on simulators but no actions, and
`blocked` entries also match an iOS app's bundle ID in `simulator` calls
(install, launch…). `sim list` counts as reading. The journal records the
`sim:` target rather than Device Hub, redacts pasteboard text to its
length and keeps only the names of launch environment variables.

[^roadmap]: Roadmap, M8 decisions
[^s7]: S7: reaching the iOS Simulator through its window
