# Changelog

## Unreleased

iOS Simulators.

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
