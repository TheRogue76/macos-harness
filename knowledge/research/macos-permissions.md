---
type: Platform Constraint
title: macOS permissions for UI automation
description: Which privacy permissions screen capture, AX and synthetic input need, who they get attributed to, and the state on the dev machine.
tags: [macos, permissions, tcc, security]
status: draft
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-06T15:17:40Z }
verified: { by: claude-code/claude-opus-5-5, at: 2026-10-06T15:10:00Z }
stale_after: 2026-11-06T00:00:00Z
sources:
  - id: probe
    resource: Swift preflight probe (CGPreflightScreenCaptureAccess, AXIsProcessTrusted, CGPreflightPostEventAccess, CGPreflightListenEventAccess) run from a Claude Code shell, 2026-10-06
    title: Permission preflight probe
    author: claude-code/claude-opus-5-5
  - id: sck
    resource: https://developer.apple.com/documentation/screencapturekit
    title: ScreenCaptureKit documentation
    author: team:apple
---

# Permissions involved

| Permission | Needed for | Preflight call (doesn't prompt) |
|---|---|---|
| Screen Recording | Window pixels (ScreenCaptureKit, `screencapture`), other apps' window titles | `CGPreflightScreenCaptureAccess()` |
| Accessibility | Reading the AX tree, AX actions, posting synthetic input | `AXIsProcessTrusted()`, `CGPreflightPostEventAccess()` |
| Input Monitoring | Listening to global input with an event tap (e.g. a stop hotkey) | `CGPreflightListenEventAccess()` |
| Automation (Apple Events) | AppleScript control of a specific app; asked per target app | none |

A Carbon `RegisterEventHotKey` hotkey does not need Input Monitoring, so a stop
hotkey can avoid that permission.

# Who gets the permission

macOS charges a permission to the *responsible process*. A CLI that an agent
host spawns (Claude.app, Terminal, iTerm, the Codex app) runs under that
host's grants, so granting it means granting the whole host. A separately
launched, signed helper is its own responsible process and can hold the
grants by itself. This is the main argument for a helper app over a bare CLI.

Grants are tied to the code signature. Ad-hoc signed rebuilds lose them on
every build, so the helper needs a stable signing identity (available: see
[dev machine](/environment/dev-machine.md)).

# What can't be automated

- Granting is a user action in System Settings. `tccutil` can only reset.
- MDM profiles can pre-approve Accessibility but not Screen Recording.
- Recent macOS versions may ask the user to re-confirm Screen Recording
  periodically. Unverified; check during the first spike.
- macOS 14+ prompts when one app reads another sandboxed app's container
  (App Data protection), which affects per-app state reset.

# State on the dev machine

From a Claude Code shell on 2026-10-06, all four preflights returned `false`:
no Screen Recording, Accessibility, event posting or event listening.[^probe]

[^probe]: Permission preflight probe
