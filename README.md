# macos-harness

Lets coding agents (Claude Code, Codex, pi and others) see and operate macOS apps:
screenshots, the accessibility tree, clicks, typing, menus and windows. It's the Mac
counterpart of the iOS Simulator tools some agents already have.

**Status: early development (milestone M3 done).** Agents can see apps and act on them,
through accessibility first (your cursor stays put) and with the real mouse and keyboard
when they have to: clicks, drags, hovers, scrolling, right-click menus and typing, behind
guard rails. See the [roadmap](knowledge/plan/roadmap.md).

## Commands

| Command | What it does |
|---|---|
| `doctor` | Check the helper, its permissions and who's calling |
| `apps` | Running apps, frontmost first |
| `windows [-a app]` | Windows with the IDs other commands take |
| `snapshot -a app` | The window's UI as a tree of refs (`e12`) with click points |
| `find text -a app` | Elements by text, `--role` or `--id`, including scrolled-out ones |
| `screenshot -a app` | One window as PNG; `--labels` draws refs, `--element e12` crops |
| `menu -a app [File …]` | Menus with shortcuts and enabled state |
| `press`, `set-value`, `type`, `key`, `focus`, `select`, `scroll-to`, `increment`, `decrement` | Act on an element by ref (`k12`) or `--text`/`--role`/`--id`; reports what changed |
| `click [--right] [--count 2]`, `hover`, `drag --to …`, `scroll --down 200` | The real mouse, on an element or a window point (`--x --y`); a right-click lists the menu's items as refs |
| `type --real`, `key --real` | Real keystrokes, for apps that ignore background ones |
| `menu-select -a app File "Save…"` | Choose a menu item |
| `window activate\|move\|resize\|minimize\|restore\|fullscreen\|close -a app` | Manage windows |
| `launch app [--open file]`, `quit app`, `wait --text … [--gone]` | App lifecycle and waiting |
| `mcp` | Run as an MCP server for Claude Code, Codex and other MCP hosts |

Every command takes `--json`.

## Use it from your agent

- **Claude Code:** `claude mcp add macos-harness -- ~/.local/bin/macos-harness-dev mcp`
- **Codex:** add to `~/.codex/config.toml`:
  ```toml
  [mcp_servers.macos-harness]
  command = "/Users/<you>/.local/bin/macos-harness-dev"
  args = ["mcp"]
  ```
- **pi or any shell-based agent:** call the `macos-harness` CLI directly.

The first call from each agent asks you to allow it, in the menu bar. The output conventions are in
[the snapshot format](knowledge/design/snapshot-format.md).

## How it works

A small menu bar app, **macOS Harness**, holds the Screen Recording and Accessibility
permissions. Its menu bar panel shows which agents are working in which apps, what
they did recently, and a **Stop all agents** button (also **⌃⌥⌘.** from anywhere).
Orange always means an agent is in control. Agents talk to it through the `macos-harness` command, which ships inside
the app and starts it when needed. Because the app holds the permissions, you never
have to give them to your terminal or your agent.

When an agent needs the real mouse or keyboard, it waits until you've stopped typing and
moving the mouse, shows where it's about to act, and puts your cursor back afterwards. If
you touch the mouse mid-gesture, or press **⌃⌥⌘.**, it stops. One agent drives at a time,
and stops last until you resume them, even if the helper restarts.

The first time a new agent (Claude Code, Codex, pi, …) uses it, the app asks you to
allow that agent. You can revoke agents from the menu bar icon.

## Build from source

Requires macOS 15 or later, Xcode 16 or later, and an Apple Development signing identity.

```bash
scripts/build-app.sh dev --install
```

This builds `macOS Harness Dev.app` and `Harness Fixture.app` into `~/Applications` and
links the CLI as `~/.local/bin/macos-harness-dev`, so it never shadows a released
`macos-harness`. Then:

```bash
macos-harness-dev doctor
```

Grant the two permissions from the menu bar icon, restart the helper from the same menu,
and run `doctor` again until everything is green.

## Development

```bash
swift build
swift test
python3 scripts/okf_lint.py
```

Acceptance scripts for each milestone are in `scripts/` (`acceptance-m3.sh` moves your
cursor, so keep your hands off the mouse and keyboard while it runs).

| Path | What |
|---|---|
| `Sources/HarnessProtocol` | JSON-RPC wire types, paths and socket I/O shared by every process |
| `Sources/HarnessCore` | Everything that runs inside the helper: process inspection, pairing, services |
| `Sources/HarnessClient` | Finds, starts and talks to the helper |
| `Sources/macos-harness` | The CLI |
| `Sources/MacosHarnessHelper` | The menu bar helper app |
| `Sources/HarnessFixture` | A small app with predictable state for the harness's own tests |
| `knowledge/` | Project knowledge in [Open Knowledge Format](knowledge/references/okf-spec.md); start at [knowledge/index.md](knowledge/index.md) |

Agents working in this repo: read [AGENTS.md](AGENTS.md) first.

## License

[MIT](LICENSE)
