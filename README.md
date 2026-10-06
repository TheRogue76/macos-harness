# macos-harness

Lets coding agents (Claude Code, Codex, pi and others) see and operate macOS apps:
screenshots, the accessibility tree, clicks, typing, menus and windows. It's the Mac
counterpart of the iOS Simulator tools some agents already have.

**Status: early development (milestone M0).** Only `doctor` and `apps` work so far. See
the [roadmap](knowledge/plan/roadmap.md).

## How it works

A small menu bar app, **macOS Harness**, holds the Screen Recording and Accessibility
permissions. Agents talk to it through the `macos-harness` command, which ships inside
the app and starts it when needed. Because the app holds the permissions, you never
have to give them to your terminal or your agent.

The first time a new agent (Claude Code, Codex, pi, …) uses it, the app asks you to
allow that agent. You can revoke agents from the menu bar icon.

## Build from source

Requires macOS 15 or later, Xcode 16 or later, and an Apple Development signing identity.

```bash
scripts/build-app.sh dev --install
```

This builds `macOS Harness Dev.app` and `Harness Fixture.app` into `~/Applications` and
links the CLI to `~/.local/bin/macos-harness`. Then:

```bash
macos-harness doctor
```

Grant the two permissions from the menu bar icon, restart the helper from the same menu,
and run `doctor` again until everything is green.

## Development

```bash
swift build
swift test
python3 scripts/okf_lint.py
```

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
