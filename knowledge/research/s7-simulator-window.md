---
type: Analysis
title: "S7: reaching the iOS Simulator through its window"
description: In Xcode 27, Device Hub replaces Simulator.app and bridges the simulator's iOS accessibility tree into its window; through AX alone the harness reads it, presses, sets text, scrolls by page and presses Home, even with the window minimized; free swipes and taps need real input, keys need the simulator view focused by a real click, and the bridge only serves simulators running when Device Hub started.
tags: [spike, m8, ios, simulator, device-hub, accessibility]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-07T16:40:00Z }
verified: { by: claude-code/claude-opus-5-5, at: 2026-10-07T19:55:00Z }
stale_after: 2027-04-07T00:00:00Z
sources:
  - id: probe
    resource: "macos-harness 0.3.0 and the dev helper (spikes axtree, axperform) against Device Hub (Xcode 27.1, build 27A9269) with iPhone 18 Pro simulators on iOS 27.0, macOS 27.2, 2026-10-07"
    title: Device Hub probe
    author: claude-code/claude-opus-5-5
  - id: ci
    resource: "GitHub Actions runs 37955210040, 37956634925, 37958877924, 37960439486 and 37989087958 of TheRogue76/macos-harness on the xcode-27 image (macOS 27.0.1, Xcode 27.0), 2026-10-09"
    title: iOS CI runs
    author: claude-code/claude-opus-5-5
---

# Question

Can the harness see and operate an iOS Simulator app through the simulator's
macOS window, with public macOS APIs only, as the owner chose for M8?

Yes. Everything an agent needs works through AX except free-form gestures,
which need the real mouse in the window.[^probe]

# Device Hub

- **There is no Simulator.app in Xcode 27.** Device Hub
  (`Xcode.app/Contents/Applications/DeviceHub.app`, bundle ID
  `com.apple.dt.Devices`) shows simulators and physical devices. A
  simulator booted with `simctl` has no window until Device Hub shows it.
- **The main window** has a sidebar of devices: rows whose children carry
  the id `TableRow.Device.<UDID>`. Selecting a row (AX select) shows that
  device; the window title becomes "<device name> – iOS <version>".
- **"Open in New Window"** (a toolbar button) moves the shown device into a
  window of its own (id `deviceWindow-AppWindow-1`, sized to the device)
  and closes the main window. Each simulator can have its own window. The
  title names the device but not its UDID.
- The `devices://` URL scheme exists, but `devices://<UDID>` did nothing
  visible.
- **Its own controls**, all pressable through AX: Home
  (`app.grid.3x3`), Screenshot, Record and Rotate Left buttons under the
  screen. The Controls menu has Home, Lock, Siri, App Switcher and Action
  Button; the Device menu has Appearance, Location, Keyboard, Face ID,
  Touch ID, Accessibility and Reset Content and Settings. Menu commands
  need Device Hub in front.

# The bridged tree

- The device screen is an `AXGroup` with subrole **`iOSContentGroup`**,
  whose frame is the screen in global coordinates. The iOS app's
  elements are its children, mostly flat, with labels, values, iOS
  accessibility identifiers and frames in global coordinates.
- iOS actions map to AX actions: `AXPress` (activate), `AXCancel`
  (escape), `AXIncrement`/`AXDecrement` (adjustable, e.g. the home screen
  page control) and **`AXScrollUpByPage`/`AXScrollDownByPage`/
  `AXScrollLeftByPage`/`AXScrollRightByPage`** on scroll views and the
  elements inside them. Custom actions appear by name ("Edit mode", "Close
  Settings").
- The status bar shows up as elements ("18:41", "100 % battery power").
- The software keyboard's keys are buttons ("q", "w", …).
- **Size:** about 50–110 elements per screen, read in 50–300 ms.
- **The tree lags.** After a screen change the group can be empty or stale
  for 1–4 s; after an app's first launch Safari's tree took about 20 s to
  appear. A read during the gap finds nothing, so selectors must wait for
  the group to fill.

# What works through AX alone

Measured with Device Hub in the background and the cursor untouched:

| Task | How | Result |
|---|---|---|
| Tap a button or icon | `AXPress` | Works (Settings, General, Back, app icons) |
| Enter text | `AXValue` on the text field | Works (Settings search, Safari address) |
| Scroll a list | `AXScrollDownByPage` on the scroll view | Works, one page per call; the action disappears at the end |
| Home | Device Hub's Home button | Works |
| Rotate | Rotate Left button | Works; the window keeps its size, so the landscape screen extends past it |
| Read and act while minimized | any of the above | Works |

# What needs more

| Task | Finding |
|---|---|
| Free swipes, drags, long presses | A real mouse drag over the screen is a touch swipe (it scrolled Settings). The scroll wheel does nothing. |
| Taps on content with no action | A real click is a tap (it opened Safari). |
| App Switcher, Lock, Siri | Controls menu, which brings Device Hub to the front |
| Key events | Background key events reach the simulator, but it uses the key code and ignores the text: "example" arrived as "aaaaaaa". Keys need real virtual key codes. |

# Coordinates

The screen group's frame is the device screen at the window's zoom. The
device's size comes from its device type's `capabilities.plist`
(`ScreenDimensionsCapability` main screen: 1206 × 2622 px at scale 3 for
an iPhone 18 Pro, so 402 × 874 points). Device points are
`(global − group origin) × device width ÷ group width`; at the default zoom
the group was 334 × 726, a factor of 0.83.

# Screenshots

`simctl io <udid> screenshot` writes the device's own pixels (1206 × 2622)
in about 0.8 s, with no window needed.

# Found while building M8

1. **The elements report positions in the newest view showing the
   simulator.** With two windows showing one simulator, the older one's
   screen group is empty of its elements (they sit in the newer one). When
   that newest window closes, the elements report positions as if the
   screen were at the display's origin, and stay that way; a new window
   takes them over. Moving or resizing a window is fine.[^probe]
2. **Device Hub only sees simulators that were running when it started.**
   Booted while it was open, through `simctl` or its own Start button, a
   simulator's screen stayed empty of elements (four times out of five) no
   matter which windows were opened or reselected. Booted with Device Hub
   closed, then opening it, worked every time. The simulator's own
   `AccessibilityEnabled` settings were on throughout.[^probe]
3. **Quitting Device Hub shuts down every simulator it shows.**[^probe]
4. **Key events need the simulator view as Device Hub's first responder.**
   Keyboard focus sits on the window (or the sidebar) until a real click
   lands on the screen; setting `AXFocused` on the screen group reports
   success and changes nothing, and "Capture Keyboard" didn't help. After
   a click, key events posted to Device Hub reach the simulator by key
   code.[^probe]
5. **iOS text fields** report `AXPlaceholderValue`, and their `AXValue` is
   the placeholder while empty; `AXValue` is settable and setting it types
   the text (search fields search). `AXSelectedText` isn't settable.[^probe]
6. **`simctl bootstatus` returns before the home screen is drawn**; after
   a cold boot the elements appeared about 50 s after the boot command.
7. **Crash reports from simulator apps open as macOS dialogs**
   (UserNotificationCenter, "Preferences quit unexpectedly") in the middle
   of the screen; shutting a simulator down with Settings open made one.
   They stay until dismissed and block real input under them.[^probe]
8. **Device Hub's windows reject `AXRaise` and setting `AXMain`**
   (error -25205); `window activate` can't raise them.
9. **Elements are replaced, not updated**, when their text changes: a
   counter label comes back as a new element with the same identifier.
10. **On Xcode 27.0 LaunchServices lists Device Hub without a process
    ID.** On GitHub's `xcode-27` image (Device Hub 1.0), `com.apple.dt.Devices`
    showed up with pid -1, also as the frontmost app, while its window was on
    screen. The bundle's main executable is `DevicesTrampoline`, which starts
    `Contents/MacOS/DeviceHub`; the harness finds that process by its path.
    On Xcode 27.1 the listing carries the real pid.[^ci]
11. **A new simulator's first text entry stalls the bridge** for 5–10 s
    while iOS starts its keyboard; an AX value set during it timed out with
    error -25204 at a 2 s timeout, so simulator calls get 8 s and a value
    set is checked and retried.[^probe]
12. **GitHub's runner is slow at first runs:** booting a new simulator took
    3.5–6 min and the fixture's first build 1–5 min; the fixture flow took
    5.5 min there against 1 min on the dev Mac.[^ci]
13. **Device Hub's Home button sometimes doesn't take** on the runner: the
    press succeeded and the app stayed in front. The harness now checks
    that the screen changed and otherwise uses Controls › Home.[^ci]

# Not covered here

Simulator.app on older Xcode (and GitHub's runners, which have Xcode 16):
whether it bridges the same tree is untested.

[^probe]: Device Hub probe
[^ci]: iOS CI runs
