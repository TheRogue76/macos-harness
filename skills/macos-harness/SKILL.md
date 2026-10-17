---
name: macos-harness
description: See and operate macOS apps, iOS Simulators and Android emulators and phones from the shell with the macos-harness CLI - list apps and windows, read an app's UI as refs, take screenshots, press buttons, type, choose menu items, drag, scroll, swipe and right-click; boot simulators and emulators, build and run apps on them or on the Mac. Use when a task needs a Mac, iOS or Android app's UI, such as checking an app you built or driving one of Apple's apps.
license: MIT
compatibility: macOS 15 or later with the macOS Harness app installed (brew install --cask therogue76/tap/macos-harness).
---

# macOS Harness

`macos-harness` talks to the macOS Harness menu bar app, which holds the
Screen Recording and Accessibility permissions. The first time you use it,
the user approves you in a prompt; if a command waits, tell them to look at
the menu bar. Run `macos-harness doctor` if anything seems off.

## The loop

1. Find the app: `macos-harness apps`, `macos-harness windows -a Notes`.
2. Read it: `macos-harness snapshot -a Notes` prints the window as a tree of
   refs (`k12`) with roles, labels, state and `@x,y` click points.
   `macos-harness find "Save" -a TextEdit` searches, including scrolled-out
   elements. Long labels and values are shortened there; `macos-harness read
   k12 -a Notes` gives one element whole, with all the text inside it and its
   links (`--links` on `snapshot` and `find` shows where links go too).
   For a long list that shows only part of itself (a web timeline, a feed,
   an iOS or Android list), `macos-harness collect --role article -a Chrome
   --max 100` scrolls it and returns each item once; `--continue` picks up
   where the last call stopped.
   `macos-harness screenshot -a Notes --out /tmp/notes.png` saves a
   picture; add `--labels` to draw refs on it.
3. Act: `macos-harness press k12 -a Notes`. Every action prints what it did
   and what changed (`~ k6 text "79" → "797"`, `+ k45 sheet`), so you rarely
   need a new snapshot. When you do, `snapshot -a Notes --since last` prints
   only what changed since your previous one, and `--query "Inbox"` only the
   matching elements; both save a lot on big windows.
4. Wait for slow things: `macos-harness wait --text "Done" -a App`.

Refs last until the app or the helper restarts. Instead of a ref you can
select by `--text`, `--role` (`button`, `textfield`, `checkbox`, `tab`,
`popup`, `menuitem`, …) and `--id`; ambiguous selectors fail with the
candidates listed.

## Acting

Prefer these: they use accessibility and don't move the user's cursor.

- `press <ref>`, `set-value <ref> --value "…"`, `focus`, `select`,
  `increment`, `decrement`, `scroll-to`
- `type "text" -a App` types at the focused element (`--into <ref>` to
  choose one); `key cmd+s -a App` sends a shortcut.
- `menu-select -a TextEdit File "Save…"` chooses a menu item (it brings the
  app to the front). `menu -a App File` lists a menu first.
- `steps '[{set-value: {ref: k8, value: Ada}}, {press: {ref: k9}}]' -a App`
  runs several steps you've already decided in one call, written like a
  flow's steps, and reports what they changed. It stops at the first
  failure. Don't batch past a step whose result decides what comes next.
- Icons on the right of the menu bar are menu bar extras. `menu --extras -a
  App` lists an app's (the system's Wi‑Fi, Sound, Battery and clock
  belong to `MenuBarAgent` on recent macOS, `"Control Center"` before,
  others to `SystemUIServer`);
  `menu --extras -a App Extra` reads one's menu, and
  `menu-select --extras -a App Extra "Item…"` chooses from it. With one extra
  you can leave its name out; `menu-select --extras -a App Extra` alone
  presses it, and an extra that opens a window returns that window's
  elements as refs.
- `window activate|move|resize|minimize|close -a App`,
  `launch App [--open file]`, `quit App`.

Text fields often save only when editing ends: after `set-value` or `type`,
send `key tab` or `key return` if the change didn't show elsewhere.

Use the pointer commands only when accessibility can't do it: an element
with no actions, a drag, a hover, scrolling, a right-click, or an app that
ignores background keys. Clicks and scrolls go to the window in the
background, without the user's cursor, except clicks on text fields and in
sheets, which ignore them, and except while the user has that turned off in
the menu bar settings (a `backgroundOff` notice). A background click that shows no effect isn't
repeated, since it may have worked out of sight (a `backgroundUnconfirmed`
notice): if it didn't take, repeat it with `--real`. Hovers, drags, held
keys and `--real` use the real mouse and keyboard, which bring the app to
the front, wait until the user stops typing or moving the mouse, and put the
cursor back. `--real` skips the background attempt:

- `click <ref>` (`--right`, `--count 2`), or `click --x 40 --y 120 -a App`
  for window-relative points
- `hover <ref>`, `drag <ref> --to <ref>`, `scroll <ref> --down 300`
- `type "…" --real`, `key cmd+a --real`

A right-click lists the context menu's items as refs; `press` one to choose it.

A drag can end in another window or app: `drag <ref> -a Finder --to-app
TextEdit --to <ref>` (the ref from a TextEdit snapshot), or `--to-window <id>`
for another window of the same app; `--to-x`/`--to-y` are then that window's
points. The destination is raised just behind the app the drag starts in,
and the drag is refused if anything still covers the drop point; move the
windows apart with `window move` and try again.

## Your own Mac app

`macos-harness build --run` in the project's folder builds the scheme with
xcodebuild and, for a Mac app, quits the copy that's running, launches the
new build in the background and prints its pid and windows; target it with
`-a <pid>` from then on. `--scheme` picks a scheme, and `--mac` builds a
scheme that also has an iOS Simulator for this Mac (natively or as Mac
Catalyst). An older copy asking to save stops the run; ask the user before
forcing it to quit.

## Apps with little or no tree

- Electron, Chrome and other Chromium apps hide their tree until asked; the
  first read switches it on (a `treeEnabled` notice). If a `treeHidden`
  notice appears, ask the user before relaunching their app with
  `launch "App" --arg=--force-renderer-accessibility`.
- For text the tree doesn't have, `find --ocr "Text" -a App` reads the
  window's pixels and gives click points; `click --ocr --text "Text"` clicks
  it. `screenshot --grid 100` draws window coordinates for canvases; then
  `click --x … --y …`.
- Need a browser of your own? `launch "Google Chrome" --new-instance
  --arg=--user-data-dir=/tmp/my-profile` and target it by the pid it prints;
  never drive the user's own browser profile without asking.

## iOS Simulators

Needs Xcode 27 or later. Give any `-a` command `sim:<device>` (a UDID, a
name, or `sim:booted`) and it works on that simulator's screen, in the
device's own points:

- `sim list`, then `sim boot "iPhone 18 Pro"` (waits for the home screen).
- `build --device booted --run` builds the project here, installs and launches
  it; or `sim install booted App.app` and `sim launch booted com.example.app`.
- `snapshot -a sim:booted`, `press -a sim:booted --text "Sign in"`,
  `type "ada@example.com" -a sim:booted --into <ref>`, `key return -a sim:booted`.
- `scroll -a sim:booted --down 600` pages through a list; actions also
  scroll to find an element iOS hasn't listed yet. `swipe --left 200`,
  `long-press <ref>` and `click --x --y` use the mouse in the simulator's
  window.
- `sim button booted home` (also lock, siri, app-switcher, rotate-left…),
  `sim open-url booted <url>`, `sim privacy booted grant photos <bundle-id>`,
  `sim appearance booted dark`, `sim location booted 59.33,18.07`.
- `screenshot -a sim:booted` and `record start -a sim:booted` come straight
  from the simulator.

The simulator's tree lags its screen by a second or two; the commands wait
for it. If a snapshot stays empty, Device Hub has lost the simulator's
screen: tell the user, since the fix (quitting Device Hub) shuts down its
simulators. Never quit Device Hub, or boot, shut down or erase a simulator
the user is using, without asking.

## Android emulators and phones

Needs the Android SDK (adb). Give any `-a` command `android:<device>` (an
adb serial, an emulator's name, or `android:booted`); coordinates are the
screen's pixels and nothing touches the user's Mac:

- `android list`, then `android boot <emulator>` (`--headless` for no
  window).
- `android install booted app.apk`, `android launch booted <package>`,
  `android terminate booted <package>`.
- `snapshot -a android:booted`, `press -a android:booted --id sign_in`,
  `type "ada@example.com" -a android:booted --into <ref>`,
  `key enter -a android:booted`, `android button booted back`.
- `scroll`, `swipe`, `long-press` and `drag` work as on a simulator;
  actions scroll to find an element that isn't on screen yet.
- `android open-url`, `android permission booted grant <package> camera`,
  `android appearance booted dark`, `android rotate booted landscape`.

Each read takes 2–3 s: act on refs and read the change lists rather than
snapshotting after every step. Only plain ASCII can be typed. A connected
phone is the user's own: ask before acting on it, and never start, stop or
wipe the user's emulators without asking.

## Recording and repeatable checks

- `record start -a App --out /tmp/run.mov` records only that app's windows;
  `record stop` finishes the file. Useful to show the user what happened.
- `flow run checks.yaml` replays a YAML flow of steps and `expect`s, and
  `flow export last` turns your latest session into one (typed text becomes
  `${text_N}` variables). `macos-harness flow --help` has the details.

## When things go wrong

- **"No change seen. …"** or **"Can't tell from the tree whether it
  worked. …"**: the action ran but nothing visible changed. Read the
  suggestion that follows before trying the same thing again.

- **"The user stopped …"** (error 1004): the user paused you from the menu
  bar or with ⌃⌥⌘. Stop and ask them to resume. Never restart the helper or
  work around it.
- **"… policy blocks …" or "read-only"** (1005): the user's policy file
  doesn't allow this app or action. Tell them; don't look for another way.
- **"isn't allowed to use macOS Harness"** (1001): the user declined the
  pairing prompt.
- **"… is working in …"** (1006): another agent session (maybe another
  session of you) is acting in that window, simulator or device. Acting in a window keeps it
  for 30 s after the last step; `windows` marks such windows "in use by".
  Work in another window, or try again once it's quiet. Reading it is fine.
  Keys go to the app's focused window, so `key` (and typing that can't go
  through accessibility) is refused the same way when that window is
  another session's; `type --into <ref>` a field of your own window.
- **"… is using the mouse and keyboard"** (1007): other sessions held the
  real mouse and keyboard longer than you could wait. Try again shortly, or
  use an accessibility action (`press`, `set-value`), which needs no turn.
  After real input, a notice may say the front was given back to the app
  that had it; that's expected.
- **Notices** (`!` lines) flag things like a system dialog, a sheet, Secure
  Input, or that the app isn't frontmost. Read them before acting.

Every command takes `--json`; errors then come back as
`{"error": {"code": …, "message": …}}`.

## Manners

You're sharing the user's Mac while they work. Do only what the task needs,
and ask before anything hard to undo: sending messages or email, deleting,
purchasing, or changing settings. Work in test files and folders when you
can.
