# Changelog

## 1.0.0-rc.4

The fourth release candidate for 1.0: `setup` no longer hangs, and menu bar
extras that open only on a click (SwiftUI's window-style ones) can be opened,
read and pressed. Upgrade with `brew update && brew upgrade --cask
therogue76/tap/macos-harness@rc`.

- **Window-style menu bar extras open.** SwiftUI's window-style
  `MenuBarExtra`s ignore an accessibility press, so `menu --extras` reported
  nothing. `--real` (MCP `real=true`) on `menu --extras` and `menu-select
  --extras` clicks the extra with the real mouse; `menu-select` leaves its
  panel open as a window you can snapshot, screenshot and press until `key
  escape`, and a press that shows nothing suggests `--real`. Flows' `menu`
  step takes `real: true`
  ([#53](https://github.com/TheRogue76/macos-harness/issues/53)).
- **`setup` no longer hangs.** After you answered "y", `setup claude` could
  wait forever on `claude mcp add`, which macOS had stopped for touching the
  terminal from the background. The commands `setup` runs now get no terminal
  and a time limit, and say to run the command yourself if they run out of
  time ([#52](https://github.com/TheRogue76/macos-harness/issues/52)).

## 1.0.0-rc.3

The third release candidate for 1.0, shaped by an agent reading long web
timelines: whole text and link targets (`read`, `--links`), `collect` for long
lists, background-only agents for scheduled jobs, windows on other desktops,
and a guide for unattended runs. Install or upgrade it with `brew update &&
brew upgrade --cask therogue76/tap/macos-harness@rc` (or `brew install
--cask therogue76/tap/macos-harness@rc` the first time).

- **Windows on another desktop can be used without switching to it.** A
  window on a Space that isn't showing can now be read (`snapshot`, `find`,
  `read`, `collect`), screenshotted, and acted on through accessibility and
  background clicks, scrolls and keys, with an `otherSpace` notice; only steps
  that need the real mouse or keyboard still ask you to switch. It works for
  an app's main or focused window there, or one read before it moved
  ([#50](https://github.com/TheRogue76/macos-harness/issues/50)).
- **Agents can be held to the background.** `macos-harness mcp
  --background-only` (or `MACOS_HARNESS_BACKGROUND_ONLY=1`, or
  `background_only: true` in the policy file for every agent) keeps agents off
  the real mouse and keyboard and stops them bringing apps to the front:
  steps that would need that fail with error 1005, and `menu-select` chooses
  without activating. For agents that run while you work
  ([#49](https://github.com/TheRogue76/macos-harness/issues/49)).
- **`collect` reads long lists.** `collect --role article -a App` (MCP
  `collect`) scrolls a list that shows only part of itself at a time (a web
  timeline or feed, a long table, an iOS or Android list), without the real
  mouse, and returns each item once with its text and links. It stops at
  `--max`, at an item containing `--until`, at the end of the list or after
  `--max-seconds`, and `--continue` carries on without repeats; `--key` tells
  items apart by a link. Flows have a `collect` step
  ([#47](https://github.com/TheRogue76/macos-harness/issues/47)).
- **`read` gives an element whole.** Snapshots and `find` shorten long labels
  and values; `read <ref>` (MCP `read`) returns the whole label and value,
  all the text inside the element in reading order (a post's author, text and
  counts), and the links inside it as refs with where they go. Without a ref
  it reads the window
  ([#44](https://github.com/TheRogue76/macos-harness/issues/44)).
- **Links say where they go.** `snapshot --links` and `find --links` (MCP
  `links`) add `url=` to links, `read` and `--json` include it, and a web
  page's own address now shows on its `webArea` line
  ([#46](https://github.com/TheRogue76/macos-harness/issues/46)).
- **Web articles show in snapshots.** A page's `<article>` elements, the posts
  of feeds and timelines, appear as `article` even without a label, and
  `--role article` finds them.
- **`--no-diff` no longer takes your mouse.** Clicks and scrolls with
  `--no-diff` (`diff=false`) used the real mouse, moving your cursor and the
  front app, because the background route needed a diff to judge them. They
  now go to the window in the background, unchecked, and a right-click still
  lists its menu ([#38](https://github.com/TheRogue76/macos-harness/issues/38)).
- **A missed link click in Chrome is no longer taken as done.** Chrome opens
  a small status bubble with the link's address on every link click, and that
  window counted as the click's effect; thin untitled windows like it are now
  ignored, as tooltips were.
- **Chrome's context menus are found in the background.** A background
  right-click in Chrome reads the menu Chrome shows inside its window, instead
  of falling back to the real mouse when it isn't checked by a diff.
- **Disabled menu items say why.** When a menu item is disabled because the
  app isn't frontmost, `menu-select` says so and, for window commands such as
  File › Close Window, points to `window close`, which works in the background
  ([#40](https://github.com/TheRogue76/macos-harness/issues/40)).
- **A guide for unattended runs** ([docs/unattended.md](docs/unattended.md)):
  scheduled agents, approving them once, keeping the Mac unlocked, and where
  their windows should be
  ([#42](https://github.com/TheRogue76/macos-harness/issues/42)).

## 1.0.0-rc.2

The second release candidate for 1.0: 1.0.0-rc.1 with background clicks
that no longer crash Chrome pages. Install or upgrade it with `brew update &&
brew upgrade --cask therogue76/tap/macos-harness@rc` (or `brew install
--cask therogue76/tap/macos-harness@rc` the first time).

- **Background clicks no longer crash Chrome pages.** Since 0.9.0, a click
  sent to Chrome in the background could crash the tab ("Aw, Snap!", error
  code 5), most often a click that rebuilds the page. One field the clicks'
  events carried caused it; it's gone, and the clicks work as before
  ([#37](https://github.com/TheRogue76/macos-harness/issues/37)).

## 1.0.0-rc.1

The release candidate for 1.0: what 0.11.0 has, with the interface frozen as
the [interface contract](https://github.com/TheRogue76/macos-harness/blob/main/knowledge/design/interface-contract.md)
describes. Try it with `brew install --cask therogue76/tap/macos-harness@rc`
(it replaces `macos-harness`; go back with `brew uninstall --cask
macos-harness@rc && brew install --cask therogue76/tap/macos-harness`), and
report what breaks with `macos-harness doctor --report`
([#29](https://github.com/TheRogue76/macos-harness/issues/29)).

- **Pre-releases have their own cask,** `macos-harness@rc`, so `brew
  upgrade` doesn't move anyone who installed `macos-harness` onto them, and
  the next release moves RC testers back.

## 0.11.0

The last gaps before 1.0: your own Mac apps, the clipboard, more agents, and
settings you control.

- **Build and run your own Mac app.** `build --run` now builds a Mac app's
  scheme too (when it has no iOS Simulator destination, or with `--mac`),
  quits the copy that's running, launches the new build and returns its
  windows, so "change code, build, look at it, act on it" is one command. MCP
  `build` takes `mac`, and flows `build: { mac: true, launch: true }`
  ([#21](https://github.com/TheRogue76/macos-harness/issues/21)).
- **Launch in another appearance or language.** `launch --appearance
  light|dark --language fr --locale fr_FR` (MCP and flows too) applies to that
  app only. An app that's already running says so instead of silently
  ignoring them ([#22](https://github.com/TheRogue76/macos-harness/issues/22)).
- **The clipboard.** `paste` puts text in an app through the clipboard, for
  apps that ignore typing, and puts back what you'd copied. `clipboard` reads
  what's on it, but never text a password manager marked concealed. The
  journal records neither ([#23](https://github.com/TheRogue76/macos-harness/issues/23)).
- **More agents.** `setup cursor`, `setup gemini` and `setup opencode` connect
  Cursor, Gemini CLI and opencode, showing what they'll change and asking
  first ([#25](https://github.com/TheRogue76/macos-harness/issues/25)).
- **Bug reports.** `doctor --report` writes one file with the versions, the
  doctor check, recent errors and what the agent asked for lately, without
  typed text, screenshots or window titles; the bug template asks for it
  ([#26](https://github.com/TheRogue76/macos-harness/issues/26)).
- **Settings in the menu bar panel.** Turn clicks in the background off,
  hide the window outline or the driving panel and click ripple, clear
  recent activity, and see and revoke paired agents. Only you can change
  them, and `doctor` shows them
  ([#27](https://github.com/TheRogue76/macos-harness/issues/27)).
- **Covered Chromium apps keep working.** Chromium, Electron and CEF apps
  the harness launches no longer go idle when other windows cover them, so
  background clicks reach them; `--allow-idle-when-covered` opts out
  ([#34](https://github.com/TheRogue76/macos-harness/issues/34)).
- **A locked screen is named.** While the Mac is locked, commands say so
  instead of reporting that apps have no windows, and `launch` doesn't wait
  15 s for one.

## 0.10.0

The first step toward 1.0: a settled interface, fewer surprises from
background clicks, and checks on more kinds of Mac setup.

- **A stable interface.** Command, option, tool and parameter names, JSON
  fields, notice kinds, error codes and exit codes are now written down in
  the [interface contract](https://github.com/TheRogue76/macos-harness/blob/main/knowledge/design/interface-contract.md); from 1.0
  they change only in major versions, and renamed options keep working until
  then. New error codes say what went wrong: 1008 nothing matched, 1009
  several elements matched, 1010 disabled, 1011 timed out (MCP errors now
  end with the code). A timed-out MCP call is no longer sent again, which
  could repeat an action
  ([#12](https://github.com/TheRogue76/macos-harness/issues/12)).
- **MCP tools take what the commands take:** snapshot `max_depth`, quit
  `timeout`, `build` with `run=true` (install and launch after the build),
  `diff` on pointer and menu_select, and every simulator status bar
  setting. Renamed, with the old names still accepted: `record start --max`
  is `--max-seconds`, MCP `record` `path` is `out`, `build --sim` is
  `--device`.
- **Background clicks don't repeat themselves.** A click sent to a window in
  the background that shows no visible effect is no longer repeated with
  the real mouse, which did the action twice when it had worked out of
  sight. The result says it can't tell (`backgroundUnconfirmed`); repeat it
  with `--real` if it didn't take. Text fields, text views and sheets, which
  ignore background clicks, get the real mouse straight away. A blinking
  caret, a window turning active or a tooltip no longer pass for a click's
  effect, and changes to elements scrolled out of view now count
  ([#32](https://github.com/TheRogue76/macos-harness/issues/32)).
- **Background scrolls go the distance asked;** they went twice as far
  ([#31](https://github.com/TheRogue76/macos-harness/issues/31)). Background
  clicks and scrolls are now checked in Catalyst apps and VS Code too, and
  fall back cleanly if a future macOS removes the private calls they use
  ([#17](https://github.com/TheRogue76/macos-harness/issues/17)).
- **Keyboard layouts.** `key` sends shortcuts where your layout has them,
  so `cmd+z` on a German keyboard is ⌘Z, not ⌘Y
  ([#15](https://github.com/TheRogue76/macos-harness/issues/15)).
- **Displays, Spaces, full screen and Stage Manager.** Windows on a second
  display and full-screen windows work like any other. Windows across two
  displays no longer give half-blank screenshots or drags that drop onto
  the desktop. Windows on another desktop are listed as "on another Space"
  instead of reported missing, and windows in Stage Manager's strip get
  real input once they're on stage
  ([#14](https://github.com/TheRogue76/macos-harness/issues/14)).
- **Smaller fixes.** `press` no longer opens a context menu on web buttons
  ([#30](https://github.com/TheRogue76/macos-harness/issues/30)); `wait
  --ocr` waits for text in the pixels
  ([#33](https://github.com/TheRogue76/macos-harness/issues/33)); a drag on
  a machine nobody is using no longer stops with "the user moved the mouse",
  and typing during a mouse step now stops it
  ([#16](https://github.com/TheRogue76/macos-harness/issues/16)); the CLI
  deletes its temporary screenshots after an hour
  ([#18](https://github.com/TheRogue76/macos-harness/issues/18)); `sim button
  home` checks the simulator's own pixels as well as its elements before
  saying Home didn't take
  ([#35](https://github.com/TheRogue76/macos-harness/issues/35)); `launch`
  right after the same app quit no longer reports that it quit at once.
- **Guides.** The README is short now, with guides in [docs/](https://github.com/TheRogue76/macos-harness/tree/main/docs)
  and a CLI and MCP reference generated from the code
  ([#19](https://github.com/TheRogue76/macos-harness/issues/19)), plus
  CONTRIBUTING, SECURITY and issue templates
  ([#20](https://github.com/TheRogue76/macos-harness/issues/20)). Every
  change is tested on macOS 15 and 26, Apple silicon and Intel
  ([#13](https://github.com/TheRogue76/macos-harness/issues/13)).

## 0.9.0

Fewer interruptions and fewer round trips.

- **Clicks and scrolls in the background.** Clicking something that has no
  accessibility action (a canvas, a custom control, web content), and
  scrolling, now go to the window in the background first: the window
  takes them without coming forward, and your cursor, front app and
  keyboard focus stay where they are. When that changes nothing, as in
  AppKit text views, the real mouse takes over as before and the result
  says so. `--real` (`real` over MCP and in flows) goes straight to the real
  mouse. A right-click still waits until you stop typing, because the menu
  it opens holds the keyboard until it closes
  ([#8](https://github.com/TheRogue76/macos-harness/issues/8)).
- **Several steps in one call.** `macos-harness steps` and the MCP `steps`
  tool run up to 64 steps written like a flow's steps, refs included, stop
  at the first failure, and report each step plus the changes they made (or
  a snapshot). Each step goes through the same pairing, policy, claims and
  turns as a single call; shell, build, launch, quit, screenshot and device
  steps aren't allowed in a batch
  ([#9](https://github.com/TheRogue76/macos-harness/issues/9)).
- **Snapshots of only what changed.** `snapshot --since last` (`since:
  "last"` over MCP) shows only what changed since your previous snapshot of
  the window, with the same refs, and `--query` keeps only the elements that
  match; both save a lot on big windows
  ([#10](https://github.com/TheRogue76/macos-harness/issues/10)).
- **Results say whether anything happened.** Every action now says whether
  its effect was confirmed, showed no change, or can't be told from the
  window (keys, menu commands, hovers, scrolls), with a suggested next step
  when it wasn't confirmed
  ([#11](https://github.com/TheRogue76/macos-harness/issues/11)).

## 0.8.1

- **Actions on a ref work in its own window.** A ref used without
  `--window` (`press k12`, `type --into k12`, pointer commands, `wait`,
  `snapshot --root`, `screenshot --element`) now targets the window that
  holds the element instead of the app's focused window, so the window
  claim, the reported changes and the on-screen outline are about the
  window the action reached. Typing into a document behind another one
  used to outline the front one and report no changes
  ([#7](https://github.com/TheRogue76/macos-harness/issues/7)).
- **`window activate` works on windows that can't be raised.** Some
  windows, like Calculator's on macOS 27, refuse the accessibility raise
  action; `window activate` now makes them main and focused instead and
  succeeds with a notice, failing only if the window doesn't come forward
  ([#6](https://github.com/TheRogue76/macos-harness/issues/6)).
- The README shows a demo video.

## 0.8.0

Several agents at once, including several sessions of the same agent.

- **Sessions of the same agent are told apart.** Two Claude Code (or Codex,
  pi…) sessions using the harness at once get their own cards in the
  panel, named by the folder each works in, their own stop (the Stop
  button's menu stops all of an agent's sessions), their own "this
  session only" approval, recordings and real-input turns. `doctor` shows
  the session, e.g. `Claude Code · macos-harness`. A stop also covers
  processes the stopped session starts.
- **Window claims.** Acting in a window keeps it for that agent session
  for 30 s after its last step. Another session's action there waits up
  to 5 s, then fails with error 1006 saying who is working where; reading
  is always allowed. `windows` marks windows other sessions hold "in use
  by …". Claims end when the session's process ends or the user stops it.
- **Simulators and Android devices are claimed** like windows: acting on
  one, or changing it with `sim`/`android` commands, keeps it for that
  session for 30 s.
- **Taking turns with the mouse and keyboard.** Real input now holds its
  turn for the whole step, from bringing the app forward until the result
  has settled, and sessions wait in line in the order they asked (up to
  20 s, then error 1007 naming who has it). Afterwards the app that was in
  front gets the front back, unless a menu is open or the action was a
  hover or right-click. `window activate` waits its turn too.
- **Keys don't reach another session's window.** Background keys land in
  an app's focused window, so `key`, and typing that can't go through
  accessibility, are refused (error 1006) while another session is working
  in that window; typing into a named field still works.
- **One open menu at a time.** `menu-select`, opening menu bar extras and
  pressing pop-up buttons take a turn with the mouse and keyboard, and a
  menu left open (a right-click's context menu, an opened pop-up) keeps
  the turn until it closes, so another session doesn't close it.
  `menu-select` also claims the window its item acts on.
- **See who waits.** The driving panel says when a session is waiting for
  the mouse and keyboard, for whom, and who else is in line, and the menu
  bar panel shows who has them while others wait.
- **Faster replies.** The helper no longer makes agents wait while it
  updates the menu bar panel and draws the window marker; that took up to
  a few seconds per request on slow machines.
- **Context menus stay open.** A menu opened by a right-click (in any app)
  closed by itself within a few seconds, because the helper redrew its
  menu bar icon on every update; it now redraws only when the icon's dot
  changes, so an agent has time to choose an item.

## 0.7.0

A refreshed helper UI.

- **A refreshed menu bar panel.** The settings gear is centered in its
  button, sessions read "Codex in Invoices · now · step 14", a single
  readiness line replaces the permission chips while both permissions are
  on, and activity leaves element refs out.
- **The window marker stays with its window.** The orange ring now sits
  just outside the window's edge with the window's own corner radius and a
  tab on its top edge. It stays directly above that window, so a window in
  front of it covers it, follows the window as it moves, and isn't drawn at
  all while the window is minimized or on another Space (it used to float
  over everything, full-screen apps included). Ripples are left out where
  another window covers the click.

## 0.6.1

- **Finding elements on a simulator is faster and bounded.** Searching
  a list page by page now stops in a direction once a page changes
  nothing, starts upward when the list is already at its end, and gives
  up after 35 s with an error saying how far it scrolled, instead of
  paging up to 30 times and outlasting the CLI's 60 s wait.
- After the CLI gives up waiting on a request, the helper's late reply no
  longer fails the next request with "Unexpected reply from the helper".

## 0.6.0

Menu bar extras, drags between windows, and other fixes from agent
feedback on 0.5.0.

- **Menu bar extras:** `menu --extras` and `menu-select --extras` (MCP
  `extras`) list an app's status items, read their menus and choose from
  them, or open their panels and return the panel's controls as refs. On
  macOS 27 the system's extras (Wi‑Fi, Battery, Control Center, the clock…)
  belong to `MenuBarAgent`. Nothing is left open after reading.
- **Drags into another window or app:** `drag --to-app/--to-window` (MCP
  `to_app`, `to_window`; flows `to: { app, window }`). The drop point is
  checked before the button goes down, and the result reports both
  windows' changes.
- A drag stopped partway (the user moved the mouse, a stop) is cancelled
  instead of dropping where it stopped.
- Window title-bar buttons (close, minimize, zoom, full screen) are always
  in snapshots, past the node and depth limits, and `find` and selectors
  match them by name.
- Actions refuse the helper's own windows and menu bar extra; pressing
  its status item through AX crashed it.

## 0.5.0

Android emulators and phones.

- **`android:` targets:** `snapshot`, `find`, `screenshot`, `press`,
  `set-value`, `type`, `key`, `scroll-to`, `click`, `long-press`, `swipe`,
  `drag`, `scroll`, `wait` and `record` work on an Android emulator or phone
  with `-a android:<device>` (serial, emulator name or `booted`), through
  adb alone: nothing is installed on the device and the Mac's cursor never
  moves. Coordinates are the screen's pixels. Actions scroll to find
  elements that aren't on screen yet.
- **`android` commands** (MCP `android`): list, boot and shut down
  emulators, install, uninstall, launch and stop apps, open URLs, Home,
  Back and other buttons, permissions, an emulator's location, dark mode,
  rotation and a clean status bar.
- Flows gain `android:` steps; an Android fixture app builds without Gradle.
- Change lists only pair a removed and an added element by an identifier
  that's unique on both sides.
- A simulator's Home button falls back to Device Hub's menu when the press
  doesn't take.

## 0.4.0

iOS Simulators (Xcode 27 or later).

- **`sim:` targets:** `snapshot`, `find`, `screenshot`, `press`, `type`,
  `scroll` and the other commands work on an iOS Simulator with
  `-a sim:<device>` (UDID, name or `booted`), through the tree Device Hub
  (Xcode 27+) exposes. Coordinates are the device's points. Taps, text and
  scrolling go through accessibility; swipes and long presses use the mouse
  in the simulator's window. Actions scroll to find elements iOS hasn't
  listed yet.
- **`sim` commands** (MCP `simulator`): list, boot, shut down, install,
  uninstall, launch, terminate, open URLs, hardware buttons, permissions,
  push notifications, location, appearance, status bar and pasteboard.
- **`build`** (MCP `build` and `build_status`): builds an iOS app for the
  simulator with xcodebuild and, with `--run`, installs and launches it.
- **`swipe` and `long-press`** for Macs and simulators.
- Screenshots and recordings of simulators come from `simctl`; flows gain
  `sim`, `build`, `swipe` and `long-press` steps; CI runs an iOS fixture
  app on GitHub's `xcode-27` image; `doctor` reports Device Hub.
- Change lists show an element that was replaced by one with the same
  identifier as a change.
- Works with Device Hub from Xcode 27.0 and 27.1. Device Hub only sees the
  screens of simulators that were running when it started, so boot them
  with `macos-harness sim boot`; and don't quit Device Hub while a
  simulator you need is running, since that shuts it down.

## 0.3.0

Electron, Chromium and canvas apps.

- **Hidden accessibility trees switched on:** the first time an agent reads
  an Electron, Chromium or CEF app (VS Code, Slack, Chrome, Spotify…), the
  helper switches its tree on and says so. When an app ignores that (CEF
  apps such as Spotify), a notice says to relaunch it with
  `--force-renderer-accessibility`.
- **A browser of the agent's own:** `launch --new-instance` starts another
  copy of a running app, such as a Chrome with a temporary profile next to
  yours; flows name it with `as:` and target only it.
- **Text recognition:** `find --ocr` reads text from the window's pixels
  with click points, `click --ocr --text …` clicks it, and flows can check
  drawn text with `ocr: true`.
- **Coordinate grids:** `screenshot --grid 100` labels window coordinates
  for canvas apps.
- An element that Chromium lists twice now counts once; variables can use
  other variables in flows; launches that never complete time out.

## 0.2.0

Flows, recording and CI.

- **Flows:** YAML files of steps with expectations, run with `macos-harness
  flow run`. Setup, steps and a teardown that always runs; `${variables}`;
  `expect` checks for values, state, visibility and counts, retried until
  they hold; `only_if` guards so cleanup only touches what a flow created.
  Failures save a screenshot, the UI tree, the step log and, with
  `--record failures`, a movie; `--junit` writes a report for CI.
  `flow check` validates files without running them.
- **Export:** `flow export <session>` turns an agent's journal session into
  a flow. Text the agent typed becomes `${text_N}` variables to fill in,
  because the journal never records it.
- **Recording:** `record start/stop` captures one app's windows (nothing
  else) to a movie; `record frames` pulls stills out. MCP agents get a
  `record` tool.
- **Run-scoped policy:** a flow (or any connection) can add blocked or
  read-only apps on top of your policy for its own requests, never remove
  any.
- **Real input reaches more of the screen:** targets scrolled out of view,
  or past the edge of the display, are scrolled into view first, with the
  real wheel when an app offers no other way (SwiftUI). Visibility now
  accounts for every scroll area around an element.
- Selectors find items in open context menus; `role: window` matches a
  window by its title; quitting an app that isn't running succeeds.
- The journal keeps one session per agent process and the request details
  export needs, still without typed text or launch secrets.

## 0.1.0

First public release. macOS Harness lets coding agents (Claude Code, Codex, pi
and others) see and operate macOS apps.

- **See:** `apps`, `windows`, `snapshot` (the accessibility tree as refs with
  click points), `find`, `screenshot` (one window, optionally labeled or
  cropped) and `menu`.
- **Act through accessibility**, without moving your cursor: `press`,
  `set-value`, `type`, `key`, `focus`, `select`, `increment`, `decrement`,
  `scroll-to`, `menu-select`, `window`, `launch`, `quit` and `wait`. Every
  action reports what changed.
- **Real mouse and keyboard** when accessibility can't do it: `click`
  (including right-click menus), `hover`, `drag`, `scroll`, `type --real` and
  `key --real`, behind guard rails: one agent at a time, waits while you type
  or move the mouse, stops if you touch the mouse, cursor put back.
- **You stay in charge:** a menu bar panel shows which agent is driving what;
  stop one agent or all of them (also ⌃⌥⌘.); each new agent asks for your
  approval once.
- **Policy file** to block apps or make them read-only, and a **journal** of
  every agent request (typed text is never recorded).
- **Agents:** an MCP server (`macos-harness mcp`), `macos-harness setup
  claude|codex|pi`, and a skill for pi.
- Every command takes `--json`.

Requires macOS 15 or later.
