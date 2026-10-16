# Troubleshooting

Start with `macos-harness doctor`: it shows the versions, the helper's permissions, the
policy, the menu bar panel's settings, and whether the caller is paired or stopped. Errors
carry a code; `--json` prints it, and MCP tool errors end with `(error N)`.

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

**"The screen is locked".** While the Mac is locked, macOS shows no app windows and takes
no input, and the lock screen's password field turns Secure Input on. Unlock it and try
again; `doctor` says when it's locked.

**`clipboard` or `paste` fails with "doesn't let macOS Harness read the clipboard".** You
denied macOS Harness pasting from other apps. Allow it in System Settings › Privacy &
Security › Paste from Other Apps (`doctor` shows the setting), or use `type` or
`set-value` instead.

## Pairing and stops

**"Waiting for you to allow …", or error 1001.** The menu bar is asking whether to allow
the agent. Answer it; an unanswered prompt is refused after 2 minutes, and some agents
give up on a tool call sooner, so retry once you've allowed it.

**Error 1004, "stopped".** You (or the stop hotkey, ⌃⌥⌘.) stopped this agent. Resume it
from the menu bar panel. Stops are saved, so restarting the helper doesn't clear them.

**An agent you revoked asks again.** That's expected: revoking (in the panel's settings)
removes the approval, so its next action asks for a new one. Deny it to keep it out.

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

**Every click and scroll moves your cursor (`backgroundOff`).** **Clicks and scrolls in
the background** is turned off in the menu bar panel's settings (`doctor` says so), so they
use the real mouse and wait until you're idle. Turn it back on to leave your cursor alone.

**No outline or "is driving" panel shows.** They're turned off in the panel's settings, or
the window is covered or on another Space. Agents work the same either way.

**A click reports `backgroundUnconfirmed`.** It went to the window in the background and
nothing visible changed. It may have worked out of sight (an effect scrolled away), so it
wasn't repeated. If it didn't take, repeat it with `--real` (MCP `real=true`).

**Chrome shows "Aw, Snap!" (error code 5) after a click.** Versions 0.9.0 to 1.0.0-rc.1
sent background clicks with an event field that crashes Chrome's page renderer, mostly on
clicks that rebuild the page. Update; on those versions, turn off **Clicks and scrolls in
the background** in the menu bar panel's settings, or click with `--real` (MCP
`real=true`).

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

Run `macos-harness doctor --report`. It writes one text file with the versions,
permissions, pairing, recent errors and the latest agent session's requests, leaving out
typed text, screenshots and window titles (`--include-titles` keeps titles). Look it over,
then attach it to an issue made with the bug template.
