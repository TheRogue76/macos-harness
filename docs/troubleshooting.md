# Troubleshooting

Start with `macos-harness doctor`: it shows the versions, the helper's permissions, the
policy, and whether the caller is paired or stopped. Errors carry a code; `--json` prints
it, and MCP tool errors end with `(error N)`.

## Setup

**A permission shows as missing.** Turn on Accessibility and Screen Recording for
**macOS Harness** in System Settings › Privacy & Security (the dev build is **macOS
Harness Dev**), then choose **Restart Helper** from its menu and run `doctor` again.

**Homebrew says the latest version is installed, but it isn't.** Run `brew update` before
`brew upgrade --cask macos-harness`; the tap isn't refreshed otherwise.

**A sandboxed agent can't reach the helper.** The CLI talks to the helper over a Unix
socket in `~/Library/Application Support/macos-harness/`, and says so when a sandbox
blocks it (Codex's default one does). Connect the agent over MCP instead (`macos-harness
setup codex`), since agents start MCP servers outside their sandbox, or allow that path in
the sandbox (`codex --allow-unix-socket <path>`).

## Pairing and stops

**"Waiting for you to allow …", or error 1001.** The menu bar is asking whether to allow
the agent. Answer it; an unanswered prompt is refused after 2 minutes, and some agents
give up on a tool call sooner, so retry once you've allowed it.

**Error 1004, "stopped".** You (or the stop hotkey, ⌃⌥⌘.) stopped this agent. Resume it
from the menu bar panel. Stops are saved, so restarting the helper doesn't clear them.

**Error 1006, the window is in use.** Another agent session acted in that window in the
last 30 s. Work in another window, or wait for it to go quiet. `windows` shows which
windows are in use and by whom.

**Error 1007, input busy.** Other sessions held the real mouse and keyboard for longer
than the request could wait. Try again.

## Actions

**Error 1008, nothing matches; 1009, several do.** Look with `find` or `snapshot`, then
use a ref or narrow the selector with `--role` or `--id`. Refs end when the app or the
helper restarts, so an old ref may no longer match.

**Error 1010, disabled.** The element or menu item is disabled right now; something else
has to happen first (a selection, a filled-in field).

**Error 1011, timed out.** The client stopped waiting for the helper, but the request may
still finish. Check what happened (`snapshot --since last`) before repeating it.

**"The user moved the mouse" or "The user typed".** A step with the real mouse or keyboard
stopped because you used yours. Keep your hands off for a moment and retry.

**The action reports `noChange`.** The app took it but the tree didn't change. For a
`press`, try `click`; for things the tree doesn't show, take a screenshot. A text field
often saves only when editing ends: send `key tab` or `key return` after `set-value` or
`type`.

**"… is on another display, where macOS doesn't show that part of the window".** The
window spans two displays, and macOS draws it only on the one holding most of it. Move it
onto one display (`window move`) and try again.

**"… is on another Space (desktop) that isn't showing".** Accessibility only reaches
windows on the Space that's showing. Switch to that desktop, or run `launch "App"
--activate`, which takes you there.

**"… is drawn smaller than its frame, as in Stage Manager's strip".** The window is a
thumbnail in Stage Manager's strip. `window activate` brings it to the stage; `snapshot`
and `press` work without that.

**Keys go to the wrong window.** Keys go to the app's focused window; a `keyWindow` notice
says when that isn't the one you named. Focus the window first (`window activate`).

**Secure Input is on.** A password field has focus somewhere, and macOS blocks synthetic
typing until it loses focus.

## Seeing

**An Electron or Chrome app shows almost nothing.** The harness switches on its hidden
tree the first time it reads it (a `treeEnabled` notice). If a `treeHidden` notice says it
stayed hidden, quit the app and launch it again with
`launch "App" --arg=--force-renderer-accessibility`.

**A screenshot is blank.** The window is minimized.

**Text isn't in the tree** (canvases, images, games). Use `find --ocr`, `click --ocr
--text …`, or `screenshot --grid 100` and click by coordinates.

## iOS Simulators

**A simulator shows no elements** (`simulatorLoading`). Device Hub only sees simulators
that were running when it started. Boot with `macos-harness sim boot`; if Device Hub was
already open with other simulators running, quit it yourself once they can be shut down,
then boot again. Never quit Device Hub while an agent is using a simulator: it shuts them
all down.

**`sim button home` says the screen didn't change.** Device Hub didn't pass the press on,
which happens on a heavily loaded Mac. Try again once the load drops.

**A list search gives up after 35 s.** iOS lists only what's on screen, so the harness
pages through the list; on a slow Mac it may not reach the element in time. Scroll closer
first, then act.

## Android

**adb isn't found.** The helper doesn't read your shell's profile. Install the SDK in
`~/Library/Android/sdk` (Android Studio's default) or adb with Homebrew.

**Typing fails.** Android's `input text` takes plain ASCII only; use `set-value` or the
app's own input for anything else.

## Reporting a bug

Open an issue with the bug template and attach `macos-harness doctor`. If an agent did
something odd, `macos-harness journal <session>` shows what it asked for (typed text is
never recorded). Check screenshots and journal entries for personal data first.
