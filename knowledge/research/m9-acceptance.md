---
type: Analysis
title: M9 acceptance run
description: The Android fixture flow (25 steps: taps, typing, a switch, a long press, a swipe, a second screen and Back, an alert, an item 35 rows down, Home) passes on an emulator through adb alone, as do Settings and the launcher by hand, the MCP tools, start and stop, rotation, screenshots, recording and the settings commands; findings cover slow reads, recycled list rows and rotation.
tags: [m9, acceptance, android, adb, emulator, findings]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-09T21:40:00Z }
verified: { by: claude-code/claude-opus-5-5, at: 2026-10-09T21:35:00Z }
stale_after: 2027-04-09T00:00:00Z
sources:
  - id: run
    resource: "flow runs, CLI and MCP checks with the dev build, adb 37.0.1 and emulator 37.2.5, on an emulator made from the Android 16 (API 36) Play image, macOS 27.2, 2026-10-09"
    title: M9 acceptance output
    author: claude-code/claude-opus-5-5
---

# Results

All on an emulator named `macos_harness_tests`, made for the run from a
system image already installed and deleted after it; the owner's
`Pixel_9_Pro_XL` emulator was never started.[^run]

| Check | How | Result |
|---|---|---|
| Fixture flow | `flows/android/fixture.yaml`: builds the fixture without Gradle (3 s), installs, launches, then 25 steps: taps, typing, a switch, a long press, a swipe, a second screen and Back, an alert, an item 35 rows down, Home | Pass, 2 min 17 s |
| Built-in apps | Launcher: icons, long-press menu, swipe up to the app list. Settings: open a page, Navigate up, search by typing and Enter, scroll, `scroll-to`, `find --ocr` | Pass |
| MCP | JSON-RPC to `macos-harness-dev mcp`: 19 tools; `android list`; `act press` with its change | Pass |
| Lifecycle | `android shutdown`, `android boot --headless` | Pass, 3 s and 18 s |
| Settings | dark mode, clean status bar, rotate (landscape reported as 2400 × 1080), open-url, permission grant and reset, location | Pass |
| Seeing | screenshots with labels and crops in pixels; recording with `screenrecord` | Pass |
| Unit tests | dump parsing, roles, keys, device listing, typing commands, permissions, flow steps, policy | 121 of 121 |

Not checked: a phone (none connected), and CI, which can't run the emulator
on GitHub's Apple-silicon runners (S8); CI runs the unit tests and parses
the Android flow.

# Findings

1. **Reads are the cost.** Each `uiautomator dump` takes 2–3 s, so a tap
   takes about 5 s with its change list and a scroll to a far element
   20–30 s. Agents should act on refs and read change lists instead of
   snapshotting after each step; the MCP instructions say so.
2. **Lists recycle their rows.** Keyed by place and resource ID alone, a
   ref kept pointing at the same row after a scroll while the row showed
   other text, and the change list called it a change; an agent acting on
   the old ref would have tapped the wrong row. Text is now part of the
   identity.
3. **Framework container IDs are noise** (`android:id/content`, a
   launcher's `drag_layer`); plain containers drop their IDs and collapse.
4. **`wm size` doesn't turn with the screen**; `dumpsys window displays`
   (`cur=2400x1080`) does. The Pixel launcher stays in portrait.
5. **Material buttons report capitalised text** ("TAP ME"), so flows match
   by resource ID.

[^run]: M9 acceptance output
