---
type: Design
title: Actions, safety rules and the MCP server
description: How agents act on apps (AX first, background keys second, real mouse and keyboard last with guard rails), how targets are chosen, what an action reports back, the focus, typing and real-input guards, key combinations on any keyboard layout, stops, drags into other windows, menu bar extras, and the MCP tools.
tags: [design, m2, m3, actions, real-input, safety, mcp]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-06T19:15:00Z }
sources:
  - id: acceptance
    resource: /research/m2-acceptance.md
    title: M2 acceptance run
  - id: m3
    resource: /research/m3-acceptance.md
    title: M3 acceptance run
  - id: s4
    resource: /research/s4-background-input.md
    title: "S4: background input"
---

# Commands

| CLI | MCP tool | Does |
|---|---|---|
| `press`, `set-value`, `focus`, `select`, `scroll-to`, `increment`, `decrement`, `type`, `key` | `act` (`action` = one of those) | Act on one element, or on the focused element for `type` and `key` |
| `menu-select -a App File "Save…"` | `menu_select` | Choose a menu item by path |
| `menu-select --extras -a App [Extra] Item` | `menu_select` with `extras` | Choose from a menu bar extra's menu, or press the extra |
| `window <activate\|move\|resize\|minimize\|restore\|fullscreen\|exit-fullscreen\|close>` | `window` | Window management |
| `launch App [--open file] [--arg] [--env K=V] [--activate]` | `launch` | Start an app (background by default) and wait for its first window |
| `quit App [--force]` | `quit` | Ask it to quit; reports if it's stuck on "save changes?" |
| `wait --text … [--gone]` | `wait` | Poll until an element appears or disappears |
| `click [--right] [--count 2]`, `hover [--dwell]`, `drag --to… [--to-app] [--to-window]`, `scroll --down/--up/--left/--right` | `pointer` (`action` = click, double-click, right-click, hover, drag, scroll; `to_app`, `to_window` for a drag into another window) | The mouse, on an element's visible center or a window-relative `--x --y`: clicks and scrolls try the background first, the rest use the real mouse |
| `steps '[{press: {id: A}}, …]' -a App [--observe changes\|snapshot\|none]` | `steps` | Up to 64 steps in one call, written like a flow's steps, stopping at the first failure; reports each step and one observation |
| `type --real`, `key --real` | `act` with `real: true` | Real keystrokes to the frontmost app |

# Choosing the element

A ref from `snapshot` or `find` (`k12`), or a selector: `--text` (label,
value or identifier contains), `--role` (snapshot names like `switch`, `tab`,
`popup` work), `--id` and `--exact`. With several matches, visible ones win,
then actionable ones, then exact text matches. Still ambiguous means an
error listing the candidates with refs, never a guess.

Refs are a letter plus a number. The letter changes on every helper launch
and numbers never repeat within one, so a stale ref fails ("from before the
helper restarted") instead of hitting another element.

A ref without `--window` targets the window that holds its element (its
`AXWindow`), not the app's focused window, for `act`, the pointer commands,
`wait`, `snapshot --root` and `screenshot --element`. The window decides
the claim, the before-and-after diff and the outline drawn on screen, so
typing into a document behind another one used to mark and diff the one in
front ([#7](https://github.com/TheRogue76/macos-harness/issues/7)). Elements
whose `AXWindow` isn't one of the app's windows (context menu items, sheets)
keep the focused window.

# How actions run

1. **AX:** `AXPress` (or Confirm, Pick, Open; ShowMenu only for menu and
   pop-up buttons, since on anything else it opens a context menu, as on a
   Chrome web button that didn't list `AXPress`,
   [#30](https://github.com/TheRogue76/macos-harness/issues/30)), set `AXValue`,
   `AXFocused`, `AXSelected`, Increment/Decrement, `AXScrollToVisible`. `type`
   inserts through `AXSelectedText` when the element allows it, which works
   in TextEdit. Nothing is sent as keystrokes.
2. **Background keys:** `type` falls back to Unicode key events posted to the
   app's process; `key` always uses them. Key combinations follow the
   current keyboard layout (see Key combinations below); the cursor doesn't
   move.
3. **Background clicks and scrolls:** `pointer` clicks, double-clicks,
   right-clicks and scrolls, and `press` on an element with no AX action,
   first go to the window in the background through private SkyLight calls:
   the window is made key without being raised, then the events are posted
   to the app's process with the point inside the window
   ([S9](/research/s9-background-clicks.md)). The user's cursor, front app
   and key focus stay as they are, and nothing waits for the user. The step
   counts as done when the tree changed, a window opened or closed, a
   context menu opened or, failing those, the window's pixels changed
   (`pixelsOnly` notice). The route is skipped for held keys, `--real`,
   `--no-diff`, drags, hovers, targets not on screen (they need scrolling
   into view), other Spaces, simulators and Android. A right-click waits
   until the user stops typing and takes a menu turn, because the menu it
   opens takes key focus until it closes.
4. **Real input:** mouse and keyboard events posted at the HID level, so
   they move the user's cursor and go to the frontmost app. Used by
   `pointer` when the background changed nothing (a `backgroundNoEffect`
   notice) and for drags, hovers and held keys, by `type --real` and
   `key --real`, and by `press` when an element has no AX action and the
   background click changed nothing (it clicks the element's visible
   center). See the guard rails below.

A background click whose effect looks the same as before (clicking the same
spot of a canvas twice) counts as no change, so the real mouse clicks again.
AppKit views that don't take a first click in an inactive app, such as
TextEdit's text view, always end up on the real mouse.

Before acting:
- Disabled elements are refused ("… is disabled, so nothing happened"),
  because `AXPress` reports success even when disabled.[^s4]
- `type` without a target refuses if the app's focused element sits in a
  different window from the one targeted. Focus lags behind a new window.
- "Cannot complete" from AX (common when an action opens a modal) becomes a
  notice, not a failure.

# What an action returns

The performed step (`pressed button “7” (k10) via AX`), notices, then the
changes. The helper waits for the window to settle (two identical reads,
≥250 ms, ~2 s cap) and diffs content and state, not positions:
`~ k6 text "79" → "797"`, `+ k45 sheet "save"`, `- k12 button "OK"`,
`~ k53 checkbox "bold" off → on`. Windows that opened or closed are
notices. `--no-diff` skips all of this. Toggles (Format › Bold) flip, so
read the change rather than assume.

Every Mac `act`, `pointer` and `menu-select` result also says whether its
effect was seen ([#11](https://github.com/TheRogue76/macos-harness/issues/11)):
`confirmed` when the tree changed, a window opened or closed, or the pixels
changed; `unverifiable` for keys, menu commands, hovers and scrolls that
changed nothing in the tree (they can work without that: saving, copying,
tooltips, moving content into view) and for `--no-diff`; `noChange` for the
rest. When it isn't confirmed, `suggestion` names what to try next, fitted
to the action and how it was sent; the text output prints both in place of
the old "No visible change" line. Elements scrolled out of view aren't
compared, so a press that changed one reads as `noChange`.

# Focus and the user

- `menu-select` and `window activate` bring the app to the front (menu items
  act on the key window). They first wait for the user to stop typing (1.5 s
  quiet, up to 8 s) and refuse if they don't, because the user's keystrokes
  would land in the activated app. This happened during M2
  testing.[^acceptance]
- If the user types anyway while an agent has the app in front, the result
  carries a `userTyped` notice.
- `launch` doesn't activate unless asked.
- `window activate` raises with `AXRaise`; when the window doesn't support
  it, it makes the window main and focused instead and succeeds with a
  `raisedByFocus` notice once the app is frontmost with that window focused
  ([#6](https://github.com/TheRogue76/macos-harness/issues/6)).

# Real input guard rails

Every real-input action runs in a session that:

- **Holds the input lease for the whole step.** One session at a time
  across all agents, even the same session twice, from bringing the app
  forward until the result has settled (and a right-click's menu is read).
  Others wait in line, first come first served, up to 20 s, then fail with
  error 1007 (`inputBusy`) naming who has it and how many wait ahead; one
  that waited gets a `waitedForInput` notice and retakes its "before"
  picture so its changes are its own. `window activate` takes its turn the
  same way. See [several agents](/design/several-agents.md).
- **Waits for the user.** Nothing is sent until the user's mouse and
  keyboard (modifier keys included) have been quiet for 1 s, up to 8 s;
  then it refuses. macOS counts the harness's own events as activity, so
  input only counts as the user's if it's newer than our last event.[^m3]
- **Brings the app to the front** with the typing guard, raises the window,
  and refuses if the app still isn't frontmost (a system dialog in the way).
- **Checks the target** before a click or drag: the point must be on a
  screen and AX's hit test there must belong to the app. The window list
  can't be used for this: the Dock keeps a transparent full-screen window
  above everything.[^m3] Secure Input refuses keyboard sessions.
- **Stops between steps** if the user stopped the agent, moved the mouse
  more than 3 pt, or another app came to the front. A stop is checked first,
  since it explains the rest.
- **Gives the front back.** After the step, the app that was in front
  before is brought back (a `frontRestored` notice), unless a menu is open
  in the target app, the action was a hover or right-click, something else
  took the front meanwhile, or the user is typing.
- **Ends cleanly:** releases a held button and held modifiers, and puts the
  cursor back (except after `hover`, so tooltips stay up; keyboard-only
  sessions never move it). A drag stopped partway is cancelled rather than
  dropped where it stopped: Escape, then the button is released back at its
  start point.
- **Presses modifiers like a keyboard.** Modifier key-down, the key or
  click, modifier key-up. Flags set only on the key event can leave ⌘
  latched in the system's state, after which every typed character became
  ⌘A.[^m3] Typed text never carries modifiers, and a session first releases
  modifiers macOS reports as held while the user is idle (a lost key-up),
  with a `modifiers` notice.

On screen, the ripple and the "<agent> is driving" panel appear before the
first event. Coordinates are window-relative like everywhere else; Chess's
board reports AX frames mirrored vertically (it's drawn with OpenGL), so use
AX presses or screenshot coordinates there.[^m3]

# Drags into another window

A drag ends in the window it starts in unless `--to-app` and/or
`--to-window` (MCP `to_app`, `to_window`; flows `to: { app, window, … }`)
name another one, the way `-a` and `--window` name the source: `--to-window`
alone means another window of the same app, `--to-app` alone that app's
focused window. `--to`, `--to-text`/`--to-role`/`--to-id` and `--to-x
--to-y` are then in that window, and a ref resolves against the destination
app, since refs are per app.

- **Before the session**, the destination is resolved and refused if it
  crosses targets: a Mac window and a simulator's screen, two simulators,
  or anything and an Android device. A drag within one simulator or one
  Android device works as before. The policy checks the destination app
  too, so a drag can't end in a blocked or read-only app.
- **Bringing to the front:** the destination app is activated (with the
  typing guard) and its window raised first, then the source app and
  window, so the destination sits right behind the source.
- **Checks the drop point** before any button goes down: it must be on a
  screen, and the window under it must be the named destination window.
  AX's hit test is walked up to the app's window (past sheets and
  popovers) and compared by window ID; the window list is the fallback
  when the hit test can't tell. A drop point covered by the source window,
  another app, or another window of the destination app is refused, saying
  what's in the way. Wheel scrolls that bring a destination element into
  view get the same check.
- **What it reports:** `dragged … to … in TextEdit window 455 “Untitled”`
  (the app is left out for another window of the same app), the source
  window's changes, then the destination window's under "Changes in …"
  (`destination` in JSON, whose refs belong to the destination app). Each
  window settles in turn.

A drag that stays in its window works as before: only its start point is
checked.

# Context menus

A right-click returns the open menu's items as refs (`+ q213 menuItem
"Duplicate" id=cmdDuplicate`), whether the app hangs the menu off the window
(Finder) or the app (most others), without separators or the ⌥ alternates
hidden behind an item. `press` on one picks it. Commands run after the menu
fades out, so settling starts once the menu is gone, and a closing menu
shows as one change, not one per item.[^m3]

Selectors also look in the app's open menus when nothing in the window
matches, so `press --role menuitem --text "Mark as done"` picks a context
menu item without its ref.

# Menu bar extras

Status items on the right of the menu bar sit in each app's
`AXExtrasMenuBar`, not its `AXMenuBar`, so `menu` and `menu-select` read
them only with `--extras` (`extras` over MCP). The system's own belong to
background processes (MenuBarAgent on macOS 27, where each extra sits
inside a SwiftUI hosting group the harness looks into; Control Center on
earlier versions; SystemUIServer for some), which `-a` resolves like any
app. The harness also takes an app's menu bar as its extras when every item
in it is an `AXMenuExtra`, for processes that keep their extras there. The
helper's own extra is refused, like the rest of its UI: its controls are
the user's.

- **Names.** Most extras show only an icon, so an extra is called by its
  description, then its title, help or identifier, and answers to any of
  them. Matching ignores case and typographic punctuation (Wi‑Fi's
  non-breaking hyphen, curly apostrophes, `…`), first exactly, then by a
  unique part of a name; misses and ambiguities list the extras. An app with
  a single extra needn't name it: a path that doesn't start with its exact
  name is taken to be inside its menu.
- **Opening.** Status items are expected to list their menu in the tree
  only while it's open (scripts have long had to click one before reading
  its menu), so reading or choosing presses the extra (`AXShowMenu` when it
  offers one and a menu is wanted, else `AXPress`). An `AXPress` that opens
  a menu may not return until the menu closes, so the press gets a 0.5 s AX
  timeout and the harness then looks for the menu: an `AXMenu` under the
  extra, or under the app for one it pops up itself. Its items are read and
  pressed like the menu bar's. When an extra already lists its menu, `menu`
  reads it without pressing. Menus that fill themselves in after opening
  (the input menu shows "Loading…" first) are read once their items stop
  changing, for up to a second.
- **Nothing left open.** `menu` closes the menu after reading it, and both
  commands close it when choosing fails: `AXCancel` on the menu, then Escape
  to the app only while it still has a window of its own at the menu level
  on screen, so a stray Escape can't reach one of its windows.
- **Windows and clicks.** An extra may open a window instead (a panel such
  as the helper's own). `menu-select` with just the extra as its path
  leaves it open and returns its elements as refs to press; `menu`, or a
  longer path, closes it again (Escape to the app, then pressing the extra
  once more) and says so. An extra that shows neither acted on the press
  itself, which the result says.
- **Panels another app draws.** On macOS 27 the panels of MenuBarAgent's
  extras are Control Center's windows (Notification Center's for the
  clock), so the harness watches those apps' windows too, and the panel's
  refs belong to that app. These extras always get `AXPress`: after
  `AXShowMenu`, Control Center draws the panel but leaves it out of its
  accessibility windows, so it could be neither read nor closed.
- **The user.** Opening waits until the user stops typing (an open menu
  takes the keyboard) and doesn't bring the app to the front.
- **Policy.** Listing an app's extras reads; reading one's menu presses
  it, so for read-only apps it's refused like `menu-select`.

# Off-screen targets

Visibility accounts for the window and every scroll area around an
element. A pointer action whose target is scrolled out of view, or past
the edge of the display, first tries the element's (or an ancestor's)
`AXScrollToVisible`, then the scroll area's scroll bars, then the real
wheel over the innermost scroll area that hides it, and re-reads every
position inside the session. SwiftUI scroll areas only respond to the
wheel. `scroll-to` (AX only) says so when an app offers no way.

# Text fields

`set-value` on a text field focuses it first. Written without an editing
session, the field shows the text but some apps never hear of it (a
Reminders title kept its old name).[^m3] Many apps still save only when
editing ends, so the result carries an `editing` notice: send `key tab` or
`key return` if the change didn't show elsewhere. Inline rename fields
(Notes, Finder) select their text when editing starts, so typing replaces
it; don't send ⌘A first, which can end the edit.

# Key combinations

A combination names characters, not key positions: `cmd+z` means "the key
that types z", wherever the user's layout has it
([#15](https://github.com/TheRogue76/macos-harness/issues/15)). Apps work
out the characters of a key event from its key code and modifiers through
their own layout, so the key code has to be the one that layout puts the
character on; US positions sent ⌘Y for ⌘Z on German QWERTZ.

- **Printable keys** are looked up in a table built from the current
  layout's Unicode data (the layout an input method types with, when one is
  selected): the key that types the character on its own, else with Shift,
  and Shift is then added to the event. With ⌘ in the combination the
  layout's ⌘ layer is searched first, because some layouts type other
  characters with ⌘ held: Dvorak – QWERTY ⌘, Russian and Greek switch to
  QWERTY. So on French AZERTY `cmd+a` goes to the US Q key, and `cmd+1` to
  the &/1 key with Shift, because AZERTY types digits with Shift, even
  with ⌘.
- **Named keys** (return, tab, space, delete, esc, arrows, home, end, page
  keys, f1–f12) keep their fixed codes on every layout.
- **Fallback:** a character the layout can't type with or without Shift
  (`[` on German needs ⌥), or a layout without Unicode data, gets its US
  position. Characters beyond the US set (`cmd+ö` on German) are accepted
  when the layout has them.
- **The display** stays as written: `cmd+1` reads ⌘1 even when Shift is
  added.
- The table is built once per input source and keyboard type and rebuilt
  when either changes; reading the input source happens on the main thread.
- **Not affected:** typed text, which carries its characters in the event,
  so the key code doesn't matter. **Not changed:** simulators, whose keys
  and typed text still use US positions (see [iOS
  Simulators](/design/ios-simulator.md)).

# Stops

The menu bar panel's Pause and Stop, and ⌃⌥⌘. anywhere, stop one agent or
all of them; calls then fail with "the user stopped …" until the user
resumes from the panel. Stops are saved, so restarting the helper doesn't
clear them: agents with a shell could otherwise restart it to get around a
stop. (That's a guard against mistakes, not a security boundary: an agent
running as the user can edit the helper's settings.)

# Out-of-process file panels

Sandboxed apps' Open and Save panels run in "Open and Save Panel Service
(<app>)". AX reaches them through the app's own tree, but keys sent to the
app don't. `key` notices an open sheet and posts to the panel's process
instead, so ⇧⌘G (Go to Folder) and Return work.[^acceptance]

# On screen

Each action shows a ripple where it acted, the window outline with
"<agent> · step N", and the "<agent> is driving" panel for 8 s. Pause stops
that agent; Stop stops everyone (see [the UI design](/design/ui-control-tower.md)).
Real input shows them before it starts, not after.

# MCP server

`macos-harness mcp` speaks MCP over stdio (protocol 2025-06-18, also 2025-03-26
and 2024-11-05) with 20 tools: `doctor`, `apps`, `windows`, `snapshot`,
`find`, `screenshot` (returns an image, default 1280 px), `menu`, `act`,
`pointer`, `steps`, `menu_select`, `window`, `launch`, `quit`, `wait`,
`simulator`, `android`, `build`, `build_status` and `record`. Outputs are the
CLI's text.

`steps` runs a list of steps written as in a flow (JSON objects such as
`{"press": {"id": "Seven"}}`, refs allowed) through the flow runner, each
as its own request, so pairing, the policy, claims and turns apply to every
step. It stops at the first failure and reports each step, then one
observation: every change the actions reported, merged to each element's
net change (the default), a snapshot, or nothing. It saves no failure
artifacts and refuses `shell`, `build`, `launch`, `quit`, `screenshot`,
`sim` and `android` steps, which have their own tools; `shell` would
otherwise let any MCP client run commands
([#9](https://github.com/TheRogue76/macos-harness/issues/9)). The server's instructions tell agents to prefer `act`, when to use
`pointer`, how text fields commit, and never to restart the helper after a
stop.
Tool failures are results with `isError`, so the agent sees the message.
Hosts start MCP servers outside their command sandbox, which is the clean
way around Codex's socket block. Setup per host is in
[agent hosts](/references/agent-hosts.md).

[^acceptance]: M2 acceptance run
[^m3]: M3 acceptance run
[^s4]: "S4: background input"
