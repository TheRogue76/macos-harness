---
type: Analysis
title: macOS vs iOS gap analysis
description: What agents can do with iOS Simulator apps today, what they can't do with Mac apps, and why the Mac is harder.
tags: [gap-analysis, ios, macos, scope]
status: draft
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-06T15:17:40Z }
sources:
  - id: ios-tool
    resource: /references/claude-ios-simulator-tool.md
    title: Claude's iOS Simulator tool
  - id: probe
    resource: Permission and tooling probes run from a Claude Code shell on the dev machine, 2026-10-06
    title: Dev machine probes
    author: claude-code/claude-opus-5-5
---

# Summary

On iOS, Claude has a purpose-built tool: screenshots, touch input, typing,
hardware buttons, deep links, build and launch.[^ios-tool] On macOS no agent
host has an equivalent. From a Claude Code shell, every permission that seeing
or operating the UI needs is missing.[^probe] Work that needs no eyes or hands
already works: build, launch, quit, logs, preferences, URLs, tests, profiling.

Neither platform exposes a UI element tree today. On macOS the accessibility
API (AX) can supply one, which may also cover the iOS Simulator (unconfirmed).

# Capability table

| Capability | iOS today | macOS today | Needed on macOS |
|---|---|---|---|
| See the screen | `screenshot` | No (no Screen Recording) | Capture limited to the target app's windows, even when covered |
| Live view for the user | `attach` panel | Not needed, app is on the user's screen | Overlay showing where the agent acts, plus a stop hotkey |
| UI element tree | No | No | AX tree with roles, labels, identifiers, click points |
| Tap / click | `tap` | No | AX press (cursor untouched); real click, double, right-click with modifiers |
| Hover | n/a | No | Hover |
| Scroll | `swipe` | No | Scroll-wheel events, AX scroll |
| Drag | `touch_path` | No | Drag and drop, within and between apps |
| Pinch / rotate | `touch2_path` | No | No public API for trackpad gestures; use shortcuts or AX |
| Type | `text` | No | Typing plus key combos |
| Hardware buttons | `button` | n/a | Menu items by path; window focus, move, resize, full screen, close |
| Deep links | `open_url` | Yes (`open`) | Nothing |
| Build | build tool | Yes (`xcodebuild`) | Optional wrapper |
| Launch | `launch` | Yes (`open`, or run the binary) | Launch that waits for a window and returns process and window IDs |
| Logs / crashes | shell | Yes (shell) | Nothing |
| Reset state | `simctl erase` | Partly, by hand | Per-app reset (container, preferences, keychain items) |
| Grant permissions | `simctl privacy` | Partly: `tccutil` only resets | Nothing; granting stays with the user |
| Push notifications | `simctl push` | No | Debug hook in the app, or APNs sandbox |
| Location | `simctl location` | Partly (Xcode debugger + GPX) | Low priority |
| Dark mode / language | `simctl ui` | Partly, per app via launch args | Launch presets (`-AppleInterfaceStyle Dark`, `-AppleLanguages`) |
| Screen recording | `simctl io recordVideo` | No | Single-window recording |
| UI tests | `xcodebuild test` | Partly: needs Automation Mode enabled once | Nothing |
| Clipboard | separate simulator clipboard | Partly: `pbcopy` overwrites the user's | Save and restore around use |
| Wait for UI to settle | No | No | Wait for element or condition (both platforms) |

# Why the Mac is harder

1. **Shared desktop.** Simulator input has its own path and never touches the
   user's cursor. Synthetic Mac input moves the real cursor and goes to the
   frontmost app. Prefer AX actions; check the frontmost app before every
   keystroke.
2. **Permissions.** See [macOS permissions](/research/macos-permissions.md).
   The simulator needs none.
3. **Privacy.** The Mac screen shows the user's mail, chat and notifications.
   Capture must be scoped to the target app.
4. **No throwaway device.** No erase, no permission pre-grant, no fake push.
   Options: per-app reset, or a macOS VM (isolated but heavy: tens of GB,
   slower loop, at most 2 macOS VMs at once).
5. **More UI surface.** Menu bar, multiple windows, sheets, popovers, context
   menus, hover, keyboard focus, menu bar extras. Open/Save panels run in a
   separate process. Electron apps hide their AX tree until asked
   (`AXManualAccessibility`).
6. **Coordinates.** Global across displays, 2x screenshots, AppKit's Y axis
   counts from the bottom. Accept window-relative points and convert.

[^ios-tool]: Claude's iOS Simulator tool
[^probe]: Dev machine probes
