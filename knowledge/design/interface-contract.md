---
type: Design
title: Interface contract and compatibility
description: What agents and scripts can rely on from 1.0 (command, option, tool and parameter names, JSON fields, the via, effect, change and notice vocabularies, error and exit codes), how the CLI and MCP names line up, and how names change without breaking anyone.
tags: [design, interface, compatibility, mcp, cli, errors, 1.0]
status: draft
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-14T21:00:00Z }
sources:
  - id: audit
    resource: https://github.com/TheRogue76/macos-harness/issues/12
    title: "Interface audit before 1.0 (#12)"
    author: claude-code/claude-opus-5-5
---

# What's stable

From 1.0, these change only in a major release:

- CLI command and option names, and the meaning of their values.
- MCP tool and parameter names.
- Flow YAML keys ([flows](/design/flows.md)).
- Field names in `--json` output and in the helper's JSON-RPC results.
- The vocabularies below: `via`, `effect`, change kinds, notice kinds,
  error codes and exit codes.
- The shape of a snapshot line: `ref role "label" = value id=… @x,y`
  ([snapshot format](/design/snapshot-format.md)).

Not covered: the wording of messages, notices, suggestions and text
output, the order of JSON fields, how long things take, and the refs
themselves (they last as long as the app and the helper). Agents should
read codes and kinds, not parse sentences.

Additions don't need a major release: new commands, tools, optional
options and parameters, JSON fields, notice kinds, `via` values and error
codes can come in any minor release, so clients ignore what they don't
know.

# Renames and removals

A rename keeps the old name working as a hidden alias until the next major
release. Using it prints a note: on stderr for the CLI, after the result
text for MCP. Removals and the end of aliases are listed in the release
notes of the major release that makes them.

Renamed in 0.10 by the audit[^audit]:

| Old | New | Why |
| --- | --- | --- |
| `record start --max` | `--max-seconds` | Matches MCP's `max_seconds` |
| MCP `record` `path` | `out` | Matches the CLI's `--out` (and `screenshot --out`) |
| `build --sim` | `--device` | Matches MCP's `device`, flows' `device` and the `sim` commands |

# CLI and MCP names that differ on purpose

| CLI | MCP |
| --- | --- |
| `click --right`, `click --count 2` | `pointer` `action` = right-click, double-click |
| `scroll --down/--up/--left/--right` (pixels) | `pointer` `dy`/`dx` (negative dy scrolls down) |
| `swipe --left/--right/--up/--down` (points) | `pointer` `dx`/`dy` |
| `hover --dwell`, flows' `dwell` | `pointer` `hold` |
| `--no-diff` | `diff=false` |
| `menu-select --no-activate` | `activate=false` |
| `sim status-bar --clear` | `simulator` `operation=clear` |
| `build --run` | `build` `run=true`, then `build_status` |

Everything else uses the same name, with `-` in the CLI where MCP has `_`.

# Vocabularies

## via

How an action reached the app.

| Value | Meaning |
| --- | --- |
| `AX` | An accessibility action or attribute |
| `AX (the on-screen keyboard)` | A simulator key pressed on iOS's on-screen keyboard |
| `background keys` | Key events posted to the app without bringing it to the front |
| `background click`, `background scroll` | Mouse events posted to the window without moving the cursor ([S9](/research/s9-background-clicks.md)) |
| `real input` | The real mouse and keyboard, with the guard rails |
| `adb` | An Android `input` command |

## effect

Whether the action's result was seen ([actions](/design/actions.md)):
`confirmed`, `noChange`, `unverifiable`.

## Change kinds

`added`, `removed`, `changed`, in action results and `snapshot --since last`.

## Notice kinds

| Kind | Where | Meaning |
| --- | --- | --- |
| `systemDialog` | snapshot | A system dialog is in front |
| `notFrontmost` | snapshot | The app isn't frontmost |
| `sheet` | snapshot | A sheet is open on the window |
| `minimized` | snapshot | The window is minimized |
| `secureInput` | snapshot | Secure Input is on; typed keys will be blocked |
| `truncated` | snapshot | Limits left elements out |
| `offscreen` | snapshot | Elements are scrolled out of view |
| `fullSnapshot` | snapshot | `--since last` had nothing to compare with |
| `query` | snapshot | `--query` narrowed the tree |
| `treeEnabled`, `treeHidden` | snapshot | A Chromium app's tree was switched on, or stays hidden |
| `simulatorLoading` | snapshot | Device Hub doesn't list the simulator's elements yet |
| `blank` | screenshot | The image is blank |
| `windowOpened`, `windowClosed` | action | A window opened or closed |
| `stillOpen` | action | A window asked to close is still open |
| `screenLocked` | launch | The screen is locked, so the app's windows won't show until it's unlocked |
| `launchArgumentsIgnored` | launch | The app was already running, so launch arguments, environment and presets weren't applied |
| `activated` | action | The app was brought to the front |
| `raisedByFocus` | action | The window was focused because the app can't raise it |
| `keyWindow` | action | Keys went to another window of the app |
| `panel` | action | Keys went to an open file panel's process |
| `editing` | action | A text field is still being edited |
| `unconfirmed` | action | The app didn't confirm the action |
| `pixelsOnly` | action | Only the pixels changed |
| `changedOutOfView` | action | Elements scrolled out of view changed, and nothing in view did |
| `backgroundNoEffect` | action | A background click or scroll couldn't be sent, so the real mouse was used (before 0.10: it changed nothing) |
| `backgroundSkipped` | action | The target ignores background clicks (text inputs, sheets), so the real mouse was used |
| `backgroundUnconfirmed` | action | A background click showed no effect and wasn't repeated; repeat it with `--real` if it didn't take |
| `cursor` | action | The cursor stays over a hover target |
| `waitedForInput` | action | Waited for another session's real input |
| `modifiers` | action | A stuck modifier was released first |
| `frontRestored` | action | The front app was given back |
| `menuOpen`, `menuStayedOpen`, `noMenu`, `windowNotMenu`, `userTyped` | menu bar extras | What a menu bar extra did |
| `secure` | Android | A password field; typed text isn't shown |
| `longPress` | Android | A right-click became a long press |
| `deviceHub`, `deviceHubRestarted` | simulator | Device Hub couldn't show a booted simulator, or was restarted |

## Error codes

The CLI prints the code with `--json`; MCP tool errors end with
`(error N)`.

| Code | Name | Meaning |
| --- | --- | --- |
| -32700, -32600, -32601, -32602, -32603 | JSON-RPC | Parse error, invalid request, unknown method, invalid parameters, internal error |
| 1001 | pairingDenied | The user declined or hasn't answered the pairing prompt |
| 1002 | permissionMissing | The helper lacks a macOS permission |
| 1003 | failed | Valid, but couldn't be carried out (the catch-all) |
| 1004 | stoppedByUser | The user stopped this agent |
| 1005 | blockedByPolicy | The policy file blocks the app or makes it read-only |
| 1006 | windowClaimed | Another session is working in the window |
| 1007 | inputBusy | Other sessions held the real mouse and keyboard too long |
| 1008 | notFound | Nothing matched the element, menu item or text named |
| 1009 | ambiguous | Several elements matched |
| 1010 | disabled | The element, menu item or extra is disabled |
| 1011 | timedOut | The client stopped waiting for the helper; the request may still finish |

1008–1011 came in 0.10; before, those cases were 1003. A timed-out MCP
call is no longer sent again on a new connection, since repeating an
action the helper may still finish could do it twice.

## Exit codes

| Code | When |
| --- | --- |
| 0 | Success |
| 1 | An error was reported (`--json` prints `{"error": {"code", "message"}}`), or a check failed: a flow, a `wait` that timed out, a failed build |
| 64 | Usage error: unknown or invalid options |

[^audit]: Interface audit before 1.0 (#12)
