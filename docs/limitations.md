# Known limitations

## Platforms

- macOS 15 or later, on Apple silicon or Intel. There's no Linux or Windows version.
- Agents drive the Mac you're using; there's no virtual-machine mode that keeps them off
  your desktop.
- Windows on a second display and full-screen windows work like any other. A window
  across two displays is only drawn on the one holding most of it (while each display has
  its own Spaces, the default), so the real mouse can't reach the rest; move it onto one
  display. Recordings show only that display.
- In a full-screen window, moving the pointer to the top slides the menu bar and title bar
  down over the window's top edge, where real clicks can hit them instead.
- Windows on a Space that isn't showing, and Stage Manager, haven't been checked yet
  ([#14](https://github.com/TheRogue76/macos-harness/issues/14)). A window on another Space
  gives a blank screenshot.
- There's no way to reset an app to a clean state between checks; flows clean up after
  themselves with teardown steps.

## Mac apps

- Hovers, drags, swipes, long presses and clicks with modifier keys always use the real
  mouse: your cursor moves (it's put back after) and the app comes to the front. They wait
  for you to be idle.
- Clicks and scrolls go to a window in the background only where the app accepts them.
  AppKit text views ignore background clicks, so those fall back to the real mouse, and so
  does anything else a background click doesn't change. Background clicks use private
  macOS functions that a future macOS could remove; the real mouse would then be used.
- Some apps ignore background keystrokes; `type --real` and `key --real` send real ones,
  which need the app in front. Secure Input (a password field with focus anywhere) blocks
  synthetic typing entirely.
- Electron, Chrome and other Chromium apps hide most of their accessibility tree; the
  harness switches it on, but some apps need relaunching with
  `--force-renderer-accessibility`. Canvases and images have no tree: text recognition and
  coordinate grids are the only way in.
- A change to an element scrolled out of view only shows as a `changedOutOfView` notice,
  and apps that list only what's on screen (Catalyst, like iOS) don't show it at all. A
  background click whose only effect is there reads as no change, so the real mouse clicks
  again ([#32](https://github.com/TheRogue76/macos-harness/issues/32)).
- Refs last as long as the app and the helper; after either restarts, take a new
  snapshot.
- Key combinations follow the Mac's keyboard layout; typed text doesn't depend on the
  layout.
- System dialogs and permission prompts are reported, never answered.

## iOS Simulators

- Simulators only, with Xcode 27 or later; physical iPhones and iPads aren't supported.
- The tree comes through Device Hub, which only sees simulators that were running when it
  started and shuts them all down when it quits.
- iOS lists only what's on screen, and the bridged tree lags the screen by 1–4 s. Finding
  an element further down a list means paging to it, for up to 35 s.
- Taps, long presses, swipes and drags use the real mouse in Device Hub's window.
- Keys and real typing use US key positions; `type` refuses characters a US keyboard can't
  type and suggests `set-value`.
- `launch` and `quit` don't apply; use `sim launch` and `sim terminate`. Creating, erasing
  and deleting simulators is left to you.
- On a heavily loaded Mac, Device Hub can drop Home presses.

## Android

- Every read of the screen takes 2–3 s; a tap takes about 5 s end to end.
- `type` sends plain ASCII only.
- `increment`, `decrement`, `hover` and right-clicks aren't available (a right-click
  becomes a long press); `menu`, `menu-select`, `window`, `launch` and `quit` don't apply.
- `location` works on emulators only; recordings stop after three minutes.
- Creating, wiping and deleting emulators is left to you; phones are never started or
  stopped.
