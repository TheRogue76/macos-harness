---
type: Analysis
title: M8 acceptance run
description: The iOS fixture flow (30 steps: taps, typing, toggle, slider, long press, swipe, navigation, alert, a far list item, Home) passes on a simulator through Device Hub, as do Settings and Safari by hand, the MCP tools, boot and shutdown, screenshots, recording and the simctl extras; findings cover Device Hub's bridge, keyboard focus, boot timing and crash dialogs.
tags: [m8, acceptance, ios, simulator, device-hub, findings]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-07T20:05:00Z }
verified: { by: claude-code/claude-opus-5-5, at: 2026-10-07T20:00:00Z }
stale_after: 2027-04-07T00:00:00Z
sources:
  - id: run
    resource: "flow runs, CLI and MCP checks with the dev build on macOS 27.2, Xcode 27.1 (27A9269), an iPhone 18 Pro simulator on iOS 27.0, 2026-10-07"
    title: M8 acceptance output
    author: claude-code/claude-opus-5-5
---

# Results

All on a simulator named "macos-harness tests", created for the run and
deleted after it.[^run]

| Check | How | Result |
|---|---|---|
| Fixture flow | `flows/ios/fixture.yaml`: builds and launches the fixture app, then 30 steps: taps, typing, a switch, a slider, a long press, a swipe, a pushed screen and back, an alert, a button 35 rows down, Home | Pass, 61 s |
| Built-in apps | Settings: open from the home screen, page down and up, `scroll-to` Developer, search; Safari: address field, `open-url`; home screen icons and page control | Pass |
| MCP | JSON-RPC to `macos-harness-dev mcp`: 18 tools; `simulator list`; `find`; `act press` with its change; `build` then `build_status` | Pass |
| Lifecycle | `sim shutdown`, then `sim boot` with Device Hub closed, and with it open and nothing else running | Pass, about 52 s to the home screen's elements |
| Build | `macos-harness build --sim … --run` on the fixture | Pass, 8 s cold, 2–4 s after |
| Screenshots | `simctl` pixels (1206 × 2622), labels and crops in device points | Pass |
| Recording | `record start/stop` on `sim:`, then `record frames` | Pass |
| simctl extras | status bar, appearance, location, privacy grant and reset, open-url, pasteboard set | Pass |
| Mac flows after the change | `flows/fixture`, `flows/apps` | Pass, 4 of 4, once the crash dialog of finding 6 was dismissed (until then the pointer flow was refused) |

CI: the fixture flow passes on GitHub's `xcode-27` image (macOS 27.0.1,
Xcode 27.0) in 5.5 min after a 5.5 min boot, once two runner-only problems
were fixed: Device Hub listed without a process ID, and a slow first text
entry (S7 findings 10–12).

Not checked: Codex and pi (still not installed on this Mac).

# Findings

1. **Device Hub's bridge has rules of its own.** Elements report positions
   in the newest view showing a simulator, so the harness picks the window
   whose screen holds them and opens a fresh one when none does. It only
   serves simulators that were running when Device Hub started, so `sim
   boot` boots with Device Hub closed. Quitting Device Hub shuts down its
   simulators, so the harness never does that while one runs. See
   [S7](/research/s7-simulator-window.md).
2. **Quitting Device Hub during S7 shut down the owner's own booted
   simulator** (iPhone 18 Pro Max, with an app open). That's how the rule
   above was found; the owner was told.
3. **Typing through AX values is the reliable path.** Key events only
   reach the simulator after a real click on its screen, so `type` sets the
   value through AX and `key` uses the on-screen keyboard when it can.
4. **The tree lags.** Every simulator action waits for the screen to
   catch up, which makes a tap take about 1.5 s end to end against 0.5 s on
   the Mac; `scroll-to` takes 1–9 s depending on how far.
5. **`simctl` quirks:** `push` fails with "Source is not authorized" for an
   app that never asked for notifications, and `pbpaste` returned nothing
   right after `pbcopy`, called directly too.
6. **Crash reports from simulator apps open in the middle of the Mac's
   screen** and block real input under them, for simulators and Mac apps
   alike, until someone dismisses them. Shutting a simulator down with
   Settings open made one.

[^run]: M8 acceptance output
