# macos-harness

Lets coding agents (Claude Code, Codex, pi and others) see and operate macOS apps, iOS
Simulators and Android emulators and phones: screenshots, the element tree, clicks and taps,
typing, menus and windows. It's the Mac counterpart of the iOS Simulator tools some agents
already have, and gives every agent those simulator tools too, plus Android, with an element
tree.

Agents work through accessibility first, so your cursor stays put. Clicks and scrolls on
things accessibility can't press go to the window in the background where the app accepts
them. When they have to, agents use the real mouse and keyboard (drags, hovers, clicks the
app ignores in the background, typing) behind guard rails, and you can stop them at any
moment.

https://github.com/user-attachments/assets/bc87ab18-c768-4d3e-85a3-fe866112ebc8

<sub>A scripted agent reads Calculator's element tree and works out 7 × 6, types into a
TextEdit window behind another one, double-clicks with the real mouse, searches Wikipedia in
Safari, and stops when the user presses ⌃⌥⌘.</sub>

## Install

Requires macOS 15 or later, on Apple silicon or Intel. Every change is built and tested on
macOS 15 and 26, on both.

```bash
brew install --cask therogue76/tap/macos-harness
```

To upgrade, refresh the tap first: `brew update && brew upgrade --cask macos-harness`.

Then check it and grant its two permissions:

```bash
macos-harness doctor
```

The **macOS Harness** menu bar app opens a setup window: turn on Accessibility and
Screen Recording for it, then choose **Restart Helper** from its menu. Run `doctor` again
until everything is green.

## Connect your agent

```bash
macos-harness setup claude
```

`setup` shows what it will change and asks first. Use `codex`, `cursor`, `gemini` or
`opencode` for those agents, or `pi` to install the skill for pi; `macos-harness setup`
alone shows what's connected. All but pi get an MCP server; pi and any other shell-based
agent use the CLI directly.

The first time each agent uses macOS Harness, the menu bar asks you to allow it, once.

## What agents can do

- **See** any app's windows as an element tree with click points, screenshots of one
  window, menus and menu bar extras, and only what changed since the last look.
- **Act** through accessibility (press, type, set values, choose menu items) without
  touching your cursor, with clicks and scrolls sent to the window in the background, and
  the real mouse and keyboard only when nothing else works. Every action reports what
  changed.
- **Check your own app**: `build --run` builds a Mac app with xcodebuild, replaces the
  running copy and returns its windows, ready to look at and act on.
- **Drive iOS Simulators and Android** emulators and phones with the same commands, and
  build and run iOS apps.
- **Repeat checks** as YAML flows, export an agent's session as one, and run them in CI.
- **Stay in your control**: one approval per agent, a stop button and hotkey (**⌃⌥⌘.**),
  real input that waits for you and stops when you move, a policy file to block apps, and
  a journal of everything agents asked for. It makes no network connections.

## Guides

- [Getting started](docs/getting-started.md): install, permissions, pairing, first
  commands, and every command at a glance
- [Flows](docs/flows.md): repeatable UI checks, exporting sessions, CI
- [iOS Simulators](docs/ios-simulators.md) and [Android](docs/android.md)
- [Unattended runs](docs/unattended.md): agents on a schedule, with nobody watching
- [Staying in control](docs/security-model.md): pairing, stops, the policy file, the
  journal, and what isn't a security boundary
- [Troubleshooting](docs/troubleshooting.md) and [known limitations](docs/limitations.md)
- Reference: [CLI](docs/reference/cli.md), [MCP tools](docs/reference/mcp.md), and the
  [interface contract](knowledge/design/interface-contract.md) for what stays stable
  across versions

## Contributing

[CONTRIBUTING.md](CONTRIBUTING.md) covers building from source, testing and the code style;
[SECURITY.md](SECURITY.md) how to report a vulnerability. Design notes, research and the
roadmap are in [knowledge/](knowledge/index.md). Agents working in this repo: read
[AGENTS.md](AGENTS.md) first.

## License

[MIT](LICENSE)
