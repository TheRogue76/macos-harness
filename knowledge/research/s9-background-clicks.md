---
type: Analysis
title: "S9: clicks and scrolls delivered to background windows through SkyLight"
description: Mouse events posted to a process with private SkyLight calls, stamped with the window and a point inside it, click SwiftUI, Catalyst, Chrome and VS Code controls and scroll their content in background windows without moving the cursor or changing the user's front app, key focus or Space; AppKit text views and Catalyst alert sheets ignore them, Electron windows hidden behind others need a Chromium flag, background scrolls went twice the distance asked until they were posted through SkyLight alone, without the private calls only the real mouse is used, and a group ID stamped in event field 58 crashed Chrome's renderer until it was dropped.
tags: [spike, input, skylight, background, private-api, electron, catalyst]
status: draft
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-14T21:55:00Z }
verified: { by: claude-code/claude-opus-5-5, at: 2026-10-16T22:30:00Z }
stale_after: 2027-04-14T00:00:00Z
sources:
  - id: spike
    resource: "`macos-harness-dev spike bgclick` (Sources/HarnessCore/BackgroundClick.swift) on macOS 27.2, 2026-10-14, with Claude and then the fixture frontmost"
    title: S9 spike output
    author: claude-code/claude-opus-5-5
  - id: coverage
    resource: "flows/catalyst/fixture.yaml and flows/chromium/vscode-background.yaml, the journal of their runs, and `spike bgclick` (with `window=<id>` and `post=`) on macOS 27.2 (26B5091g), Xcode 27.1, VS Code 1.141.2, 2026-10-14, with the owner's apps in front"
    title: "#17 coverage runs"
    author: claude-code/claude-opus-5-5
  - id: tests
    resource: Tests/HarnessCoreTests/BackgroundInputTests.swift (MissingSkyLightTests)
    title: Missing-symbol tests
    author: claude-code/claude-opus-5-5
  - id: issue17
    resource: https://github.com/TheRogue76/macos-harness/issues/17
    title: "Cover the background route in more apps, and its fallback (#17)"
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
  - id: issue37
    resource: https://github.com/TheRogue76/macos-harness/issues/37
    title: "Background clicks crash Chrome's renderer (#37)"
  - id: crashes
    resource: "Chrome 155.0.8059.40's Crashpad dumps in ~/Library/Application Support/Google/Chrome/Crashpad/completed, the release journal in ~/Library/Logs/macos-harness/journal, and `spike bgclick` variants on a throwaway Chrome, macOS 27.2, 2026-10-16"
    title: Chrome renderer crash investigation
    author: claude-code/claude-opus-5-5
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
   40 (target pid), 51, 91 and 92 (window ID), 58 (one group ID per gesture,
   dropped on 16 October 2026 because it crashed Chrome; see below), and a
   point set with `CGEventSetWindowLocation`.
3. For scrolling, a primed `mouseMoved` then line wheel events with the same
   window fields, each posted through SkyLight and the public
   `CGEvent.postToPid` in the spike (the route now posts through SkyLight
   alone; see below).

It records, before and after, the front process and the key-focus process
(from WindowServer, not AppKit), the front app's focused window, the
cursor, the active Space and the window directly above the target.

# Results

| Target | Result |
| --- | --- |
| Fixture (SwiftUI) button, toggle, tap-only canvas | Clicked, with the point stamped **inside the window** (top-left origin). The canvas got the exact point. With the screen point stamped, nothing happened. |
| Fixture button, double click | Two presses (click state 1, then 2). |
| Fixture `Form`, scroll | Scrolled, but only when each wheel event was posted through both SkyLight and the public call; SkyLight alone did nothing. Not so when re-measured for #17 with the pixel wheel events the route sends: each path alone scrolls, and both together scroll twice as far (see below). |
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
Java/Tk and OpenGL or Metal viewports (Cua reports these need real input),
modifier clicks, windows on other Spaces or displays, a Catalyst context
menu (the fixture has none), and Slack (it would open the owner's
workspace). Electron and Catalyst were covered later; see below.

# Next

Built as the background rung of [actions](/design/actions.md): `pointer`
clicks and scrolls, and `press` without an AX action, try the background
first and fall back to real input when nothing changed (the TextEdit case).
See [#8](https://github.com/TheRogue76/macos-harness/issues/8).[^issue]
Building it found that making the window key redraws its title bar and
toolbar, so the pictures compared for pixel changes are taken after the
focus record, not before.

# Coverage in more apps (#17)

Before 1.0 the route was run through `pointer` (the production path, with
its judgement and fallback) on a Catalyst app and an Electron app, with the
owner's apps in front and covering both windows, and checked with the
spike where the result alone couldn't tell.[^issue17] Each step's route is
the `via` of its result in the journal (`background click`, `background
scroll`, `real input` after a `backgroundNoEffect` notice).[^coverage]

- **Catalyst:** the iOS fixture (`fixtures/ios`) built for Mac Catalyst,
  `flows/catalyst/fixture.yaml`.
- **Electron:** VS Code 1.141.2 as a separate instance with a throwaway
  profile in `~/macos-harness-sandbox`, `flows/chromium/vscode-background.yaml`.

| App | Gesture | Route | Notes |
| --- | --- | --- | --- |
| Catalyst | Click a button ("Tap me") | Background, 0.8–1.0 s | |
| Catalyst | Double-click a button | Background, 1.0 s | Two taps |
| Catalyst | Click a text field | Background, 0.9–1.1 s | The field takes focus |
| Catalyst | Click a switch | Background, 0.8–1.9 s | Only on the switch itself; the element's center is the middle of its row, where a click does nothing by either route |
| Catalyst | Click a navigation link, then Back | Background, 0.85–1.35 s | |
| Catalyst | Click "Show alert" | Background, 1.1–1.4 s | The alert opens as a sheet |
| Catalyst | Click the alert's OK | Falls back | Ignored in the background, stamped with the main window's ID or the sheet's own window ID; `press` through AX works |
| Catalyst | Click a list row whose effect is out of view | Falls back | The click lands (the spike shows the label changed), but nothing in view changed, so the real mouse clicks again |
| Catalyst | Scroll a `List` | Background, 0.6–2.5 s | Twice the distance asked (posted through both paths, before #31) |
| VS Code | Click activity bar tabs (Search, Explorer) | Background, 1.2–1.6 s | |
| VS Code | Click explorer rows (expand a folder, open a file) | Background, 0.75–1.5 s | |
| VS Code | Double-click an explorer row | Background, 1.1 s | Pins the editor |
| VS Code | Scroll the editor | Background, 0.8 s | `pixelsOnly`: the tree doesn't change; twice the distance asked (before #31) |
| VS Code | Right-click an explorer row | Background, but wrong | Selects the row and opens no context menu; the tree changed, so the result counts it done and nothing falls back |
| VS Code, window fully covered, without `--disable-backgrounding-occluded-windows` | Click an activity bar tab | Falls back, or a false success | No effect after 7 s; one attempt read as `pixelsOnly`, the next as no change |
| (same) | Click a file row | Background, late | The file opened (the window title changed at once) but the tree showed its tab only about 6 s later |
| (same) | Scroll the editor | Falls back | Judged no change; the real wheel then scrolled again |

Scroll distances, measured with `spike bgclick … scroll=-80 post=…`
(`scroll=-200` in VS Code) from the top each time (`post=` picks SkyLight,
the public call or both): in the
macOS fixture's `Form`, 80 px asked moved the content 160 pt with both, 80
pt with either alone, also on a fresh launch; in the Catalyst `List` 160,
80 and 80; in VS Code's editor, 200 px asked moved 28 lines with both and
14 with either alone.[^coverage]

## What it means

- **Catalyst content takes background clicks and scrolls** like SwiftUI,
  except an alert, which macOS shows as a sheet: its buttons ignore them
  whichever window ID is stamped, and AX presses them.
- **Electron content takes them too, unless Chromium has backgrounded the
  window.** When other windows cover an Electron window completely,
  Chromium backgrounds it (what the flag below turns off): input still
  reaches the page (a file opened), but some of the UI's work doesn't
  happen and the accessibility tree catches up seconds later, if at all,
  so the result sees no change, or only pixels, and the real mouse repeats
  the click. Launched with `--disable-backgrounding-occluded-windows`
  (beside `--force-renderer-accessibility`), a window just as covered took
  every click, double-click and scroll in the background. Agents launching
  their own Chromium or Electron instance should pass both.
- **A background scroll went twice as far as asked**, in every app
  measured, because each wheel event was posted through SkyLight and the
  public call and the app took both. Either path alone moves the asked
  distance, so since 15 October 2026 the route posts through SkyLight
  alone ([#31](https://github.com/TheRogue76/macos-harness/issues/31)):
  40 and 100 px asked moved the fixture's `Form` 40 and 100 pt, and the
  Catalyst flow passes with its scroll doubled to match. In a throwaway
  Chrome (temporary profile, launched with
  `--disable-backgrounding-occluded-windows`), 100 px asked moved a page
  100 pt through either path alone, 200 through both, and 100 through the
  route.
- **Judging by what changed has blind spots.** An effect out of view (a
  label scrolled away) reads as no change, and the real mouse clicks again,
  so the action happens twice. Changes the click didn't cause read as its
  effect: in the covered VS Code window a click that did nothing came back
  `pixelsOnly`, and a `press` came back confirmed by a small untitled
  window (84 × 77, a tooltip by its size) closing. A right-click that opens
  no menu but changes the selection counts as done too.
- **Missing private calls only lose the background route.** With the calls
  made to look unresolved (a task-local test hook in `SkyLight`), the route
  reports itself unavailable, the pointer and `press` decisions choose real
  input for clicks, double-clicks, right-clicks and scrolls, and every
  SkyLight call returns failure without posting anything.[^tests]

# Field 58 crashed Chrome's renderer (#37)

From 0.9.0, an agent clicking in Chrome sometimes turned the page into
"Aw, Snap!" with error code 5, a renderer `CHECK` failure.[^issue37]

- **The crashes followed background clicks.** The owner's Chrome had 35
  renderer crash dumps (`EXC_BREAKPOINT` on the renderer's main thread, two
  crash sites, Chrome 155.0.8059.40), the first on the day background clicks
  first reached it. A crash came within 4 s after 26 of 132 background
  clicks and 8 of 128 `press`es that fell back to one, and after none of 159
  real-mouse clicks or 24 background scrolls, which don't set field 58.
  Clicks that rebuild the page (links, menu items, buttons) crashed it most;
  checkboxes and radio buttons almost never.[^crashes]
- **Field 58 alone did it.** On a local page whose links replace the DOM, in
  a throwaway Chrome, `spike bgclick` crashed the renderer 8 times in 8 with
  the full recipe, and still 8 in 8 without the off-screen priming press,
  with subtype 0, or without the focus record. Without field 58, 0 in 8,
  and the clicks still landed. A click that changes nothing (a counter)
  didn't crash even with it. `NSEvent` doesn't show the field, so Chrome
  must read it from the underlying event.[^crashes]
- **Without it, everything still works.** Clicks, double-clicks and
  right-clicks (with their context menu) in Chrome, and the Catalyst,
  SwiftUI and VS Code flows, pass without the field.
  `flows/chromium/chrome-background-clicks.yaml` clicks such links twelve
  times and fails at the first click when the field is set.
- **A throwaway Chrome still writes its crash dumps** into the default
  profile's `Crashpad/completed`, not the `--user-data-dir`, so tests that
  crash it add dumps to the owner's folder.

[^spike]: S9 spike output
[^cua]: Cua Driver's macOS input (skylight.rs, mouse.rs), MIT
[^cua-macos]: Cua Driver macOS notes
[^yabai]: yabai, the source of the focus-without-raise event record (MIT)
[^issue]: "Spike: background clicks without the real mouse (#8)"
[^issue17]: "Cover the background route in more apps, and its fallback (#17)"
[^coverage]: #17 coverage runs
[^tests]: Missing-symbol tests
[^issue37]: Background clicks crash Chrome's renderer (#37)
[^crashes]: Chrome renderer crash investigation
