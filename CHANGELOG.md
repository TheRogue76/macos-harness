# Changelog

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
