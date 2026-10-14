---
type: Analysis
title: "S9: clicks and scrolls delivered to background windows through SkyLight"
description: Mouse events posted to a process with private SkyLight calls, stamped with the window and a point inside it, click SwiftUI and Chrome controls and scroll their content in background windows without moving the cursor or changing the user's front app, key focus or Space; AppKit text views ignore them, and an opened context menu borrows key focus until it closes.
tags: [spike, input, skylight, background, private-api]
status: draft
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-14T13:05:00Z }
verified: { by: claude-code/claude-opus-5-5, at: 2026-10-14T13:05:00Z }
stale_after: 2027-04-14T00:00:00Z
sources:
  - id: spike
    resource: "`macos-harness-dev spike bgclick` (Sources/HarnessCore/BackgroundClick.swift) on macOS 27.2, 2026-10-14, with Claude and then the fixture frontmost"
    title: S9 spike output
    author: claude-code/claude-opus-5-5
  - id: cua
    resource: https://github.com/trycua/cua/tree/main/libs/cua-driver/rust/crates/platform-macos/src/input
    title: Cua Driver's macOS input (skylight.rs, mouse.rs), MIT
  - id: cua-macos
    resource: https://github.com/trycua/cua/blob/main/libs/cua-driver/rust/Skills/cua-driver/MACOS.md
    title: Cua Driver macOS notes
  - id: yabai
    resource: https://github.com/koekeishiya/yabai
    title: yabai, the source of the focus-without-raise event record (MIT)
  - id: issue
    resource: https://github.com/TheRogue76/macos-harness/issues/8
    title: "Spike: background clicks without the real mouse (#8)"
---

# Question

[S4](/research/s4-background-input.md) found that mouse events posted with
the public `CGEvent.postToPid` are ignored, so clicks without an AX action
use the real mouse. Cua Driver clicks background windows through private
SkyLight calls.[^cua-macos] Does that work here, for which apps, and what
does the user notice?

# Method

The `bgclick` spike resolves the private symbols with `dlsym` and:

1. Optionally makes the target window key without raising it or activating
   its app: a 248-byte event record (byte 0x04 = 0xF8, 0x08 = 0x0D, the
   window ID little-endian at 0x3C, 0x8A = 0x01) posted to the window
   owner's process with `SLPSPostEventRecordTo`. The record comes from
   yabai;[^yabai] Cua deliberately skips the matching "defocus" record to the
   front app, because that stops the user's window taking keys.[^cua]
2. Posts a `mouseMoved` at the point (it primes the window's tracking), for
   a left click an off-screen press at (-1, -1) (Chromium's user-activation
   gate), then the press pairs, each through `SLEventPostToPid`.[^cua] Every
   event carries fields 0 (phase), 1 (click state), 3 (button), 7 (subtype 3),
   40 (target pid), 51, 91 and 92 (window ID), 58 (one group ID per gesture),
   and a point set with `CGEventSetWindowLocation`.
3. For scrolling, a primed `mouseMoved` then line wheel events with the same
   window fields, each posted through SkyLight and the public
   `CGEvent.postToPid`.

It records, before and after, the front process and the key-focus process
(from WindowServer, not AppKit), the front app's focused window, the
cursor, the active Space and the window directly above the target.

# Results

| Target | Result |
| --- | --- |
| Fixture (SwiftUI) button, toggle, tap-only canvas | Clicked, with the point stamped **inside the window** (top-left origin). The canvas got the exact point. With the screen point stamped, nothing happened. |
| Fixture button, double click | Two presses (click state 1, then 2). |
| Fixture `Form`, scroll | Scrolled, but only when each wheel event was posted through both SkyLight and the public call; SkyLight alone did nothing. |
| Fixture context menu, right click | The menu opened. While it was open, key focus moved to the fixture; after its item was chosen through AX, key focus was back with the user's app. |
| TextEdit text view, single and double click | Ignored, with either point, with or without the focus record. |
| Chrome (separate instance, throwaway profile, local page), button | Clicked with the point inside the window, from the background, with or without the focus record. With the screen point it did nothing, even with Chrome in front. |

In every case the front app, the front app's focused window, the cursor,
the Space and the window stacking stayed as they were; key focus moved only
while a context menu was open. Clicks also reached a window partly covered
by the user's.[^spike]

# What it means

- **Background clicks work for SwiftUI and Chromium content** on macOS 27.2,
  so most "no AX action" clicks (canvases, custom controls, web content) can
  avoid the real mouse.
- **The stamped point must be window-local here.** Cua's left-click path
  stamps the screen point;[^cua] on this macOS that did nothing in SwiftUI
  or Chrome.
- **AppKit views that don't accept a first click ignore it.** In an inactive
  app, AppKit treats a click on such a view (`NSTextView` among them) as
  just activating the window, and these events never activate the app. Text
  selection stays on AX (`AXSelectedTextRange` is settable in TextEdit).
- **The focus record wasn't needed** in these tests, though each window may
  already have been key in its app; keep it, as Cua does, for windows that
  aren't.
- **Menus borrow the keyboard.** A background right-click that opens a menu
  takes key focus until the menu closes, so it needs the same one-menu-at-a-
  time turn as menu commands ([several agents](/design/several-agents.md)),
  and the item should be chosen through AX straight away.
- **The user can't see it happen,** least of all in a covered window, so the
  window outline and the driving panel matter more, not less.
- **Private symbols can change** with any macOS update. Resolve them at run
  time and fall back to the real mouse when one is missing.

# Not tried

Drags (Cua reports no background drag on macOS),[^cua-macos] hover,
Electron apps (VS Code and Slack would open the owner's workspaces),
Catalyst, Java/Tk and OpenGL or Metal viewports (Cua reports these need real
input), modifier clicks, and windows on other Spaces or displays.

# Next

Built as the background rung of [actions](/design/actions.md): `pointer`
clicks and scrolls, and `press` without an AX action, try the background
first and fall back to real input when nothing changed (the TextEdit case).
See [#8](https://github.com/TheRogue76/macos-harness/issues/8).[^issue]
Building it found that making the window key redraws its title bar and
toolbar, so the pictures compared for pixel changes are taken after the
focus record, not before.

[^spike]: S9 spike output
[^cua]: Cua Driver's macOS input (skylight.rs, mouse.rs), MIT
[^cua-macos]: Cua Driver macOS notes
[^yabai]: yabai, the source of the focus-without-raise event record (MIT)
[^issue]: "Spike: background clicks without the real mouse (#8)"
