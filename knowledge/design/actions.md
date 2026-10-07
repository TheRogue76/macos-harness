---
type: Design
title: Actions, safety rules and the MCP server
description: How agents act on apps (AX first, background keys second, real mouse and keyboard last with guard rails), how targets are chosen, what an action reports back, the focus, typing and real-input guards, stops, and the MCP tools.
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
| `window <activate\|move\|resize\|minimize\|restore\|fullscreen\|exit-fullscreen\|close>` | `window` | Window management |
| `launch App [--open file] [--arg] [--env K=V] [--activate]` | `launch` | Start an app (background by default) and wait for its first window |
| `quit App [--force]` | `quit` | Ask it to quit; reports if it's stuck on "save changes?" |
| `wait --text … [--gone]` | `wait` | Poll until an element appears or disappears |
| `click [--right] [--count 2]`, `hover [--dwell]`, `drag --to…`, `scroll --down/--up/--left/--right` | `pointer` (`action` = click, double-click, right-click, hover, drag, scroll) | The real mouse, on an element's visible center or a window-relative `--x --y` |
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

# How actions run

1. **AX:** `AXPress` (or Confirm, Pick, Open, ShowMenu), set `AXValue`,
   `AXFocused`, `AXSelected`, Increment/Decrement, `AXScrollToVisible`. `type`
   inserts through `AXSelectedText` when the element allows it, which works
   in TextEdit. Nothing is sent as keystrokes.
2. **Background keys:** `type` falls back to Unicode key events posted to the
   app's process; `key` always uses them. US key positions; the cursor
   doesn't move.
3. **Real input:** mouse and keyboard events posted at the HID level, so
   they move the user's cursor and go to the frontmost app. Used by
   `pointer`, by `type --real` and `key --real`, and by `press` when an
   element has no AX action (it clicks the element's visible center). See
   the guard rails below.

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

# Focus and the user

- `menu-select` and `window activate` bring the app to the front (menu items
  act on the key window). They first wait for the user to stop typing (1.5 s
  quiet, up to 8 s) and refuse if they don't, because the user's keystrokes
  would land in the activated app. This happened during M2
  testing.[^acceptance]
- If the user types anyway while an agent has the app in front, the result
  carries a `userTyped` notice.
- `launch` doesn't activate unless asked.

# Real input guard rails

Every real-input action runs in a session that:

- **Holds the input lease.** One action at a time across all agents, even
  the same agent twice; a second waits up to 10 s, then fails with "<agent>
  is using the mouse and keyboard".
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
- **Ends cleanly:** releases a held button and held modifiers, and puts the
  cursor back (except after `hover`, so tooltips stay up; keyboard-only
  sessions never move it).
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
and 2024-11-05) with 14 tools: `doctor`, `apps`, `windows`, `snapshot`,
`find`, `screenshot` (returns an image, default 1280 px), `menu`, `act`,
`pointer`, `menu_select`, `window`, `launch`, `quit`, `wait`. Outputs are the
CLI's text. The server's instructions tell agents to prefer `act`, when to use
`pointer`, how text fields commit, and never to restart the helper after a
stop.
Tool failures are results with `isError`, so the agent sees the message.
Hosts start MCP servers outside their command sandbox, which is the clean
way around Codex's socket block. Setup per host is in
[agent hosts](/references/agent-hosts.md).

[^acceptance]: M2 acceptance run
[^m3]: M3 acceptance run
[^s4]: "S4: background input"
