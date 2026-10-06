---
type: Design
title: Actions, safety rules and the MCP server
description: How agents act on apps in M2 (AX first, background keys second, never the cursor), how targets are chosen, what an action reports back, the focus and typing guards, and the MCP tools.
tags: [design, m2, actions, safety, mcp]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-06T20:40:00Z }
sources:
  - id: acceptance
    resource: /research/m2-acceptance.md
    title: M2 acceptance run
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

# Choosing the element

A ref from `snapshot` or `find` (`k12`), or a selector: `--text` (label,
value or identifier contains), `--role` (snapshot names like `switch`, `tab`,
`popup` work), `--id` and `--exact`. With several matches, visible ones win,
then actionable ones, then exact text matches. Still ambiguous means an
error listing the candidates with refs, never a guess.

Refs are a letter plus a number. The letter changes on every helper launch
and numbers never repeat within one, so a stale ref fails ("from before the
helper restarted") instead of hitting another element.

# How actions run (M2 uses the first two rungs)

1. **AX:** `AXPress` (or Confirm, Pick, Open, ShowMenu), set `AXValue`,
   `AXFocused`, `AXSelected`, Increment/Decrement, `AXScrollToVisible`. `type`
   inserts through `AXSelectedText` when the element allows it, which works
   in TextEdit. Nothing is sent as keystrokes.
2. **Background keys:** `type` falls back to Unicode key events posted to the
   app's process; `key` always uses them. US key positions; the cursor
   doesn't move.
3. **Real input:** M3.

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

# Out-of-process file panels

Sandboxed apps' Open and Save panels run in "Open and Save Panel Service
(<app>)". AX reaches them through the app's own tree, but keys sent to the
app don't. `key` notices an open sheet and posts to the panel's process
instead, so ⇧⌘G (Go to Folder) and Return work.[^acceptance]

# On screen

Each action shows a ripple where it acted, the window outline with
"<agent> · step N", and the "<agent> is driving" panel for 8 s. Pause stops
that agent; Stop stops everyone (see [the UI design](/design/ui-control-tower.md)).

# MCP server

`macos-harness mcp` speaks MCP over stdio (protocol 2025-06-18, also 2025-03-26
and 2024-11-05) with 13 tools: `doctor`, `apps`, `windows`, `snapshot`,
`find`, `screenshot` (returns an image, default 1280 px), `menu`, `act`,
`menu_select`, `window`, `launch`, `quit`, `wait`. Outputs are the CLI's text.
Tool failures are results with `isError`, so the agent sees the message.
Hosts start MCP servers outside their command sandbox, which is the clean
way around Codex's socket block. Setup per host is in
[agent hosts](/references/agent-hosts.md).

[^acceptance]: M2 acceptance run
[^s4]: "S4: background input"
