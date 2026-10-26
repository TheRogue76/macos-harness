# Getting started

## Install

macOS Harness needs macOS 15 or later, on Apple silicon or Intel.

```bash
brew install --cask therogue76/tap/macos-harness
```

To upgrade later, refresh the tap first; without `brew update`, Homebrew can say the
latest version is already installed when it isn't:

```bash
brew update && brew upgrade --cask macos-harness
```

## Permissions

```bash
macos-harness doctor
```

The **macOS Harness** menu bar app opens a setup window. Turn on **Accessibility** and
**Screen Recording** for it in System Settings, then choose **Restart Helper** from its
menu. Run `doctor` again until everything is green.

The menu bar app holds these permissions, so you never give them to your terminal or your
agent. Agents talk to it through the `macos-harness` command, which ships inside the app
and starts it when needed.

`macos-harness permissions` lists what the helper has; `macos-harness permissions grant`
asks for what's missing, opening System Settings at the right page, and `macos-harness
permissions reset` takes it all back so you can start over.

### On Linux

On Linux the helper needs no special rights from the system; the desktop decides what it
may do. Run:

```bash
macos-harness permissions grant
```

It says before each step what the desktop will ask:

- **Sway and other wlroots compositors** let the harness see windows, take screenshots
  and use the mouse and keyboard without asking, so there's nothing to grant.
- **KDE Plasma** shows the harness its windows without asking, and asks once each to
  allow screenshots and remote control of the mouse and keyboard; let it remember
  the answer.
- **GNOME** asks three things once each: to install the macOS Harness extension from
  extensions.gnome.org (it tells the harness where windows are and brings them forward,
  and can't read or type anything), to allow screenshots, and to allow remote interaction
  for the mouse and keyboard (turn on **Allow Remote Interaction**). GNOME remembers each
  answer.

If an agent needs one you haven't granted, a notification offers **Set up**, which runs the
same steps. `doctor` lists each one, and `macos-harness permissions reset` takes them all
back: it uninstalls the extension and makes GNOME forget its answers.

## Connect your agent

```bash
macos-harness setup claude
```

`setup` shows what it will change and asks first. Use `codex`, `cursor`, `gemini` or
`opencode` for those agents, or `pi` to install the skill for pi; `macos-harness setup`
alone shows what's connected. All but pi get an MCP server; pi and other shell-based
agents use the CLI directly. For Cursor and opencode, which have no command to add a
server, `setup` edits their config file (`~/.cursor/mcp.json`,
`~/.config/opencode/opencode.json`), keeps a copy of the old one beside it, and won't
touch a file with comments.

Any other MCP host can run the server itself: the command is `macos-harness mcp`
(stdio). Any agent that can run shell commands can use the CLI.

## Pairing

The first time each agent uses macOS Harness, the menu bar asks you to allow it. Agents
are recognized by their code signature, so updates don't ask again. **Allow** covers every
session of that agent; **This session only** covers just the one asking, and the agent's
next session asks again with its folder on the card. An unanswered prompt is refused after
2 minutes. See and revoke paired agents any time in the panel's settings (gear menu ›
**Settings…**).

## A first look

```bash
macos-harness apps                                  # running apps, frontmost first
macos-harness snapshot -a Calculator                # the window's UI as refs (k12) with click points
macos-harness press -a Calculator --id Seven        # press through accessibility
macos-harness steps '[{press: {id: Multiply}}, {press: {id: Six}}, {press: {id: Equals}}]' -a Calculator
macos-harness screenshot -a Calculator -o calc.png
```

Every action reports what changed in the window, so agents rarely need a new snapshot,
and says whether its effect was seen (`confirmed`, `noChange` or `unverifiable`). Every
command takes `--json`.

## What agents can do

| Command | What it does |
|---|---|
| `doctor` | Check the helper, its permissions, the policy and who's calling |
| `apps` | Running apps, frontmost first |
| `windows [-a app]` | Windows with the IDs other commands take |
| `snapshot -a app [--since last] [--query text]` | The window's UI as a tree of refs (`k12`) with click points; `--since last` shows only what changed since your last snapshot, `--query` only matching elements |
| `find text -a app` | Elements by text, `--role` or `--id`, including scrolled-out ones; `--ocr` reads text from the window's pixels; `--links` shows where links go |
| `collect --role article -a app` | Every item of a long list (a web timeline, a table, an iOS or Android list), scrolled through without your mouse, each once with its text and links; `--max`, `--until`, `--continue` |
| `read ref -a app` | One element in full: its whole label and value, all the text inside it, and its links with where they go; without a ref, the whole window |
| `screenshot -a app` | One window as PNG (to `-o`, or a temporary file deleted after an hour); `--labels` draws refs, `--grid 100` draws coordinates, `--element k12` crops |
| `menu -a app [File …]`, `menu --extras -a app [extra …]` | Menus with shortcuts and enabled state; `--extras` lists the app's menu bar extras (status items) or reads one's menu |
| `press`, `set-value`, `type`, `key`, `focus`, `select`, `scroll-to`, `increment`, `decrement` | Act on an element by ref or `--text`/`--role`/`--id`, through accessibility; reports what changed |
| `steps '[…]' -a app` | Several steps in one call, written like a flow's steps; stops at the first failure and reports what changed |
| `click [--right] [--count 2]`, `hover`, `drag --to … [--to-app app] [--to-window id]`, `scroll --down 200`, `swipe --left 200`, `long-press` | The mouse, on an element or a window point (`--x --y`): clicks and scrolls try the window in the background first (`--real` skips that), the rest use the real mouse; a drag can end in another window or app; a right-click lists the menu's items as refs |
| `type --real`, `key --real` | Real keystrokes, for apps that ignore background ones |
| `paste text -a app [--into k12]`, `clipboard` | Paste through the clipboard, for apps that ignore typing (your clipboard is put back); read what's on the clipboard |
| `menu-select -a app File "Save…"`, `menu-select --extras -a app [extra] item` | Choose a menu item, or one from a menu bar extra's menu (the system's Wi‑Fi, Sound, clock and so on belong to MenuBarAgent, or Control Center on older macOS, and SystemUIServer); `--real` clicks an extra that opens only on a click, such as a SwiftUI window-style one |
| `window activate\|move\|resize\|minimize\|restore\|fullscreen\|close -a app` | Manage windows |
| `launch app [--open file] [--new-instance] [--appearance dark] [--language fr]`, `quit app`, `wait --text … [--gone]` | App lifecycle and waiting; `--new-instance` starts a second copy, such as a Chrome with its own profile; `--appearance`, `--language` and `--locale` apply to that app only |
| `journal [session]` | What agents did, per session |
| `record start -a app`, `record stop`, `record frames file.mov` | Record an app's windows to a movie; pull stills out of it |
| `flow run`, `flow check`, `flow export <session>` | Repeatable UI checks in YAML ([flows](flows.md)) |
| `build [--mac] [--run]` | Build your own app with xcodebuild; for a Mac app, `--run` replaces the running copy with the new build and prints its pid and windows ([below](#your-own-mac-app)) |
| `sim …`, `build --device sim [--run]` | iOS Simulators ([guide](ios-simulators.md)) |
| `android …` | Android emulators and phones ([guide](android.md)) |
| `setup [claude\|codex\|pi]`, `mcp` | Connect agents; run as an MCP server |

Every option of every command is in the [CLI reference](reference/cli.md), and the MCP
tools are in the [MCP reference](reference/mcp.md).

## How agents act

Agents work through accessibility first, so your cursor stays put. Clicks and scrolls on
things accessibility can't press go to the window in the background where the app accepts
them. Drags, hovers, clicks the app ignores in the background, and real typing use the
real mouse and keyboard, behind guard rails: they wait until you're idle, stop if you touch
the mouse or keyboard, and put your cursor and front app back
([staying in control](security-model.md)).

## Apps without a full tree

Electron, Chrome and other Chromium-based apps hide most of their accessibility tree until
asked; the harness switches it on the first time an agent reads one, and says so. For text
no tree has (canvases, images), `find --ocr` and `click --ocr --text …` use on-device text
recognition, and `screenshot --grid 100` draws coordinates to aim by. Details:
[Chromium apps, text recognition and grids](../knowledge/design/chromium-and-canvas.md).

## Your own Mac app

```bash
cd ~/Code/MyApp
macos-harness build --run            # build the scheme, replace the running copy, print its pid and windows
macos-harness snapshot -a <pid>      # then look at it and act on it as usual
```

`build` finds the `.xcworkspace` or `.xcodeproj` in the folder (or `--project`,
`--workspace`, `--scheme`) and asks xcodebuild where the scheme can run. A scheme without
an iOS Simulator builds for this Mac; one with both builds for the simulator unless you add
`--mac`, which builds it natively or as Mac Catalyst, whichever the scheme supports.

With `--run`, a copy of the app that's already running (the same bundle ID, no other app)
is asked to quit first; one that asks to save stops the run instead of losing your work.
The new build then opens in the background, like `launch`, and the command waits for its
first window. Over MCP it's `build` with `mac=true` and `run=true`, then `build_status`; in
a flow, `build: { mac: true, launch: true, as: myapp }` and `app: myapp`. Details:
[building and running your own Mac app](../knowledge/design/mac-app-builds.md).
