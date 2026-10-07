# Changelog

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
