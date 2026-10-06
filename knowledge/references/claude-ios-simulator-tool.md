---
type: Reference
title: Claude's iOS Simulator tool
description: The capabilities Claude Code desktop has for iOS Simulator apps; the baseline to match on macOS.
tags: [ios, simulator, baseline, claude-code]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-06T15:17:40Z }
stale_after: 2027-01-06T00:00:00Z
sources:
  - id: schema
    resource: Tool schemas of mcp__Claude_Code_iOS_Simulator__control and mcp__Claude_Code_iOS_Simulator__build as exposed in a Claude Code desktop session, 2026-10-06
    title: iOS Simulator tool schemas
    author: team:anthropic
---

# Availability

Built into the Claude Code tab of the Claude desktop app. Codex, pi and other
agents don't get it, which is one reason a harness that also covers the iOS
Simulator would help them.

# `control` actions[^schema]

| Action | What it does |
|---|---|
| `attach` / `detach` | Live view of the simulator in a panel of the desktop app |
| `launch` | Install and launch a built `.app` (bundle ID read from Info.plist) |
| `screenshot` | PNG of the current screen |
| `tap` | Tap at a point; longer than 0.5s is a long-press |
| `swipe` | Swipe between two points; starting within 4pt of an edge triggers the system edge gesture |
| `touch_path` | One-finger path with per-point timing |
| `touch2_path` | Two-finger path (pinch, rotate) |
| `text` | Type a string |
| `button` | Home, Lock, Side, Siri, Apple Pay |
| `open_url` | Deep links, URL schemes, universal links |

Coordinates are device points; the device is chosen by name or UDID.

# `build` actions[^schema]

- `build`: headless `xcodebuild` of a project or workspace for a simulator;
  returns a build ID.
- `build_status`: progress, compile errors and the built `.app` path.

# Gaps

No UI element tree, no screen recording, no orientation, shake or biometrics,
no physical devices. Everything else `simctl` offers (permissions, push,
location, appearance, status bar) is reachable from a shell.

[^schema]: iOS Simulator tool schemas
