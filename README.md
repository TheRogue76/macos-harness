# macos-harness

Lets coding agents (Claude Code, Codex, pi and others) see and operate macOS apps, iOS
Simulators and Android emulators and phones: screenshots, the element tree, clicks and taps,
typing, menus and windows. It's the Mac counterpart of the iOS Simulator tools some agents
already have, and gives every agent those simulator tools too, plus Android, with an element
tree.

Agents work through accessibility first, so your cursor stays put. When they have to,
they use the real mouse and keyboard (clicks, drags, hovers, scrolling, right-click menus,
typing) behind guard rails, and you can stop them at any moment.

## Install

Requires macOS 15 or later.

```bash
brew install --cask therogue76/tap/macos-harness
```

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

`setup` shows what it will change and asks first. Use `codex` for Codex, or `pi` to
install the skill for pi; `macos-harness setup` alone shows what's connected. Claude Code
and Codex get an MCP server; pi and any other shell-based agent use the CLI directly.

The first time each agent uses macOS Harness, the menu bar asks you to allow it, once.

## What agents can do

| Command | What it does |
|---|---|
| `doctor` | Check the helper, its permissions, the policy and who's calling |
| `apps` | Running apps, frontmost first |
| `windows [-a app]` | Windows with the IDs other commands take |
| `snapshot -a app` | The window's UI as a tree of refs (`k12`) with click points |
| `find text -a app` | Elements by text, `--role` or `--id`, including scrolled-out ones; `--ocr` reads text from the window's pixels |
| `screenshot -a app` | One window as PNG; `--labels` draws refs, `--grid 100` draws coordinates, `--element k12` crops |
| `menu -a app [File …]`, `menu --extras -a app [extra …]` | Menus with shortcuts and enabled state; `--extras` lists the app's menu bar extras (status items) or reads one's menu |
| `press`, `set-value`, `type`, `key`, `focus`, `select`, `scroll-to`, `increment`, `decrement` | Act on an element by ref or `--text`/`--role`/`--id`, through accessibility; reports what changed |
| `click [--right] [--count 2]`, `hover`, `drag --to … [--to-app app] [--to-window id]`, `scroll --down 200`, `swipe --left 200`, `long-press` | The real mouse, on an element or a window point (`--x --y`); a drag can end in another window or app; a right-click lists the menu's items as refs |
| `type --real`, `key --real` | Real keystrokes, for apps that ignore background ones |
| `menu-select -a app File "Save…"`, `menu-select --extras -a app [extra] item` | Choose a menu item, or one from a menu bar extra's menu (the system's Wi‑Fi, Sound, clock and so on belong to MenuBarAgent, or Control Center on older macOS, and SystemUIServer) |
| `window activate\|move\|resize\|minimize\|restore\|fullscreen\|close -a app` | Manage windows |
| `launch app [--open file] [--new-instance]`, `quit app`, `wait --text … [--gone]` | App lifecycle and waiting; `--new-instance` starts a second copy, such as a Chrome with its own profile |
| `journal [session]` | What agents did, per session |
| `record start -a app`, `record stop`, `record frames file.mov` | Record an app's windows to a movie; pull stills out of it |
| `flow run`, `flow check`, `flow export <session>` | Repeatable UI checks in YAML; turn an agent's session into one |
| `sim list\|boot\|shutdown\|install\|launch\|terminate\|open-url\|button\|…` | iOS Simulators: lifecycle, apps, hardware buttons, permissions, push, location, appearance, status bar |
| `build [--sim device] [--run]` | Build an iOS app for the simulator with xcodebuild, then install and launch it |
| `android list\|boot\|shutdown\|install\|launch\|terminate\|open-url\|button\|…` | Android emulators and phones through adb: lifecycle, apps, Back and Home, permissions, location, dark mode, rotation, status bar |
| `setup [claude\|codex\|pi]`, `mcp` | Connect agents; run as an MCP server |

Every command takes `--json`. The output conventions are in
[the snapshot format](knowledge/design/snapshot-format.md).

Electron, Chrome and other Chromium-based apps hide most of their accessibility tree until
asked; the harness switches it on the first time an agent reads one, and says so. For text
no tree has (canvases, images), `find --ocr` and `click --ocr --text …` use on-device text
recognition. Details: [Chromium apps, text recognition and grids](knowledge/design/chromium-and-canvas.md).

## iOS Simulators

With Xcode 27 or later, every command that takes `-a` also takes `sim:<device>` (a UDID, a
name, or `sim:booted`):

```bash
macos-harness sim boot "iPhone 18 Pro"
macos-harness build --sim booted --run
macos-harness snapshot -a sim:booted
macos-harness press -a sim:booted --text "Sign in"
macos-harness type "ada@example.com" -a sim:booted --into s12
macos-harness swipe -a sim:booted --up 400
macos-harness sim button booted home
```

The tree, taps, typing and scrolling go through accessibility in the background, in the
device's own points; swipes and long presses use the mouse in Device Hub's window.
Screenshots and recordings come straight from the simulator. Details and limits:
[iOS Simulator targets](knowledge/design/ios-simulator.md).

## Android emulators and phones

With the Android SDK installed (adb), every command that takes `-a` also takes
`android:<device>` (an adb serial, an emulator's name, or `android:booted`):

```bash
macos-harness android boot Pixel_9_Pro_XL
macos-harness android install booted app-debug.apk
macos-harness android launch booted com.example.app
macos-harness snapshot -a android:booted
macos-harness press -a android:booted --id sign_in
macos-harness type "ada@example.com" -a android:booted --into a12
macos-harness android button booted back
```

Everything goes through adb: nothing is installed on the device and your cursor never
moves. Coordinates are the screen's pixels. Each read of the screen takes 2–3 s, and only
plain ASCII can be typed. Details: [Android targets](knowledge/design/android.md).

## Flows: repeatable UI checks

A flow is a YAML file of steps with expectations:

```yaml
name: Calculator multiplies
app: Calculator
setup:
  - launch: Calculator
steps:
  - press: { id: One }
  - press: { id: Two }
  - press: { id: Multiply }
  - press: { id: Three }
  - press: { id: Four }
  - press: { id: Equals }
  - expect: { role: text, text: "408" }
teardown:
  - quit: { app: Calculator, if_launched: true }
```

`macos-harness flow run flows/` runs them. A failure saves a screenshot, the UI tree,
the step log and, with `--record failures`, a movie, and `--junit report.xml` feeds CI.
`macos-harness flow export last` turns an agent's latest journal session into a flow;
text it typed becomes `${text_1}` variables to fill in, since the journal never records
it. The format is in [flows](knowledge/design/flows.md); the flows in [flows/](flows) run in
GitHub Actions on every push.

## Staying in control

- **One approval per agent.** Each new agent (identified by its code signature) asks
  once; revoke it any time from the menu bar's gear menu.
- **See who's driving.** The menu bar panel shows which agent is working in which app and
  what it did recently. Windows an agent reads glow briefly; where it clicks, a ripple
  shows.
- **Stop anything.** Pause one agent from the panel, or stop them all with the big button
  or **⌃⌥⌘.** from any app. Stopped agents stay stopped, even across restarts, until you
  resume them.
- **Real input waits for you.** Before using the real mouse or keyboard, an agent waits
  until you've stopped typing and moving the mouse, and only one agent drives at a time.
  Touch the mouse mid-gesture and it stops. Your cursor is put back afterwards.
- **Policy.** Block apps, or make them read-only, in `~/.config/macos-harness/policy.yaml`
  (gear menu › **Edit Policy…**):

  ```yaml
  blocked:
    - com.apple.Passwords
  read_only:
    - Mail
    - Messages
  ```

  Agents can't see blocked apps at all, and can read but not act on read-only ones.
- **Journal.** Every agent request is logged per session in
  `~/Library/Logs/macos-harness/journal` (gear menu › **Show Journal**, or
  `macos-harness journal`). Text agents type is never recorded, only its length. Sessions
  are kept for 30 days.

Everything stays on your Mac: macOS Harness makes no network connections.

These guard rails protect you from agents' mistakes. They aren't a security boundary
against software that's determined to get around them: anything running as you can
edit the policy file.

## How it works

The **macOS Harness** menu bar app holds the Screen Recording and Accessibility
permissions, so you never give them to your terminal or your agent. Agents talk to it
through the `macos-harness` command, which ships inside the app and starts it when
needed. Design notes, research and the roadmap are in [knowledge/](knowledge/index.md).

## Build from source

Requires Xcode 16 or later and an Apple Development signing identity.

```bash
scripts/build-app.sh dev --install
```

This builds `macOS Harness Dev.app` and `Harness Fixture.app` into `~/Applications` and
links the CLI as `~/.local/bin/macos-harness-dev`, so it never shadows a released
`macos-harness`. Then run `macos-harness-dev doctor` and grant the permissions as above.
Releases are built with `scripts/release.sh` (Developer ID signing and notarization).

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
| `Sources/HarnessProtocol` | JSON-RPC wire types, paths, the journal format and socket I/O shared by every process |
| `Sources/HarnessCore` | Everything that runs inside the helper: process inspection, pairing, policy, journal, services |
| `Sources/HarnessClient` | Finds, starts and talks to the helper; text rendering; the MCP server |
| `Sources/macos-harness` | The CLI |
| `Sources/MacosHarnessHelper` | The menu bar helper app |
| `Sources/HarnessFixture` | A small app with predictable state for the harness's own tests |
| `fixtures/ios` | The same for iOS: an Xcode project the iOS flows build and run on a simulator |
| `fixtures/android` | The same for Android: a plain-Java app `scripts/build-android-fixture.sh` builds without Gradle |
| `skills/macos-harness` | The agent skill `setup pi` installs |
| `packaging/` | The Homebrew cask template |
| `knowledge/` | Project knowledge in [Open Knowledge Format](knowledge/references/okf-spec.md); start at [knowledge/index.md](knowledge/index.md) |

Agents working in this repo: read [AGENTS.md](AGENTS.md) first.

## License

[MIT](LICENSE)
