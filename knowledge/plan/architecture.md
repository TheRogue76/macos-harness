---
type: Architecture
title: Architecture
description: Proposed components, process model, observation and action model, safety and packaging.
tags: [architecture, design, plan]
status: draft
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-06T15:48:51Z }
sources:
  - id: requirements
    resource: /project/requirements.md
    title: Requirements from the kickoff interview
  - id: permissions
    resource: /research/macos-permissions.md
    title: macOS permissions for UI automation
  - id: hosts
    resource: /references/agent-hosts.md
    title: Agent hosts and how they call tools
---

# Shape

Everything is Swift, in one Swift package, shipped as one signed app bundle.

```
agent (Claude Code / Codex / pi / …)
  ├─ shell ──► macos-harness <command>     (CLI, thin client)
  └─ MCP  ──► macos-harness mcp            (stdio MCP server, same binary)
                   │  JSON-RPC over a Unix socket (user-only)
                   ▼
        macos-harness.app  (menu bar helper, holds the permissions)
          └─ HarnessCore: AX, ScreenCaptureKit, CGEvent, Vision OCR,
                          windows, app lifecycle, journal, policy
```

| Component | Role |
|---|---|
| `HarnessCore` (library) | All capture, AX, input, window and app logic. Runs only inside the helper |
| `macos-harness.app` | Menu bar helper (`LSUIElement`). Holds Screen Recording and Accessibility, serves the socket, shows pairing prompts, the activity overlay and the stop hotkey. Starts at login via `SMAppService` |
| `macos-harness` CLI | Lives inside the app bundle, linked onto `PATH`. Compact text output by default, `--json` for machines. Starts the helper through LaunchServices if it isn't running |
| `macos-harness mcp` | Stdio MCP server over the same client code (official Swift MCP SDK). Returns screenshots as image content and as a file path |
| Skill | A `SKILL.md` plus setup snippets that teach Claude Code, Codex and pi to use the CLI or MCP server[^hosts] |

**Why a helper app.** Permissions are charged to the responsible process. A
CLI spawned by an agent would borrow the agent host's permissions, so you'd
grant Claude.app or Terminal control of your Mac. A separately launched,
signed helper holds its own grants.[^permissions] The helper must always be
started through LaunchServices (`open`, `SMAppService`), never as a child of
the CLI, or it inherits the caller's responsibility. Spike S1 confirms this.

**Signing.** Release builds use the personal Developer ID with hardened
runtime and notarization. Dev builds use the Apple Development identity and a
`.dev` bundle ID, so dev and release grants don't overwrite each other.

# Targets and coordinates

- A target is an app (`--app Safari`, bundle ID or pid), optionally narrowed
  to a window (`--window <id>`). The interface reserves `sim:<udid>` for the
  later iOS Simulator milestone.
- Coordinates are window-relative points, top-left origin, matching the
  screenshot divided by its reported scale. The helper converts to global
  display coordinates (multi-display, flipped AppKit Y) internally.

# Observing

| Command | Returns |
|---|---|
| `apps` | Running apps: name, bundle ID, pid, frontmost, window count |
| `windows` | Windows: ID, title, frame, on screen, key/main, minimized |
| `snapshot` | The core "look" call: compact AX tree with refs (`e12`), role, name, value, state and a hit point per element; optional screenshot |
| `find` | Elements matching role, name, identifier or text, as refs |
| `screenshot` | PNG of a window, app or element, even when covered by other windows; downscaled by default; optional ref labels drawn on (for vision-only reasoning) |
| `menu` | The app's menu bar as a tree |

Token budget is a design constraint. The tree is pruned (non-interactive
single-child groups collapsed), capped with "… N more" markers that `expand`
opens, and actions return a diff against the previous snapshot instead of a
full tree. Refs stay valid across snapshots when the element still exists;
otherwise they're re-resolved from a fingerprint (path, role, identifier,
title) or reported stale.

Poor trees (Electron, canvases) fall back in this order: enable the hidden
tree (`AXManualAccessibility`, `AXEnhancedUserInterface`), then on-device OCR
with Vision to find text, then coordinates read from a screenshot.

# Acting

Every action takes a ref, a selector (`role=button name="Save"`) or
coordinates, and climbs this ladder until one works:

1. **AX action**: press, confirm, show menu, increment, set value, focus,
   select, scroll to visible. The cursor never moves.
2. **Background events** posted to the target process. The cursor doesn't
   move; many apps ignore background mouse events, so this is mostly for keys.
3. **Real input**: activate the app, check it's frontmost, move the cursor,
   post the events, and restore the cursor afterwards.

The result reports which rung was used, then waits for the UI to settle (AX
notifications quiet and the screenshot stable) and returns the tree diff.

Commands: `press`, `click` (single, double, right, with modifiers), `hover`,
`drag`, `scroll`, `type`, `key` (`cmd+shift+s`), `set-value`, `menu select
"File > Export…"`, `window` (activate, move, resize, minimize, full screen,
close), `launch` (args, env, appearance, language; waits for the first
window), `quit`, `wait` (for an element or condition), `logs`.

# Guard rails for real input

Real input is allowed by default, with:[^requirements]

- an overlay that marks where the next action lands and outlines the
  controlled window;
- a global stop hotkey (Carbon hotkey, so no Input Monitoring permission)
  that cancels all sessions;
- a frontmost-app check immediately before every keystroke batch;
- yielding when the user is actively using the mouse or keyboard;
- one input lease: only one session at a time may send real input, while
  reads and AX actions can run in parallel;
- clipboard saved and restored when typing goes through paste;
- a clear error when macOS Secure Input is on (password fields), which blocks
  synthetic keys by design.

# Access, policy and journal

- **Pairing.** On a connection the helper reads the peer pid, walks the
  process ancestry to the agent host (Claude, Codex, a `node` process running
  pi, a terminal) and identifies it by code signature, or by path and
  arguments when unsigned. A new identity gets a one-time approval prompt in
  the menu bar. This is a consent step, not a hard boundary against malware
  running as the same user; the docs will say so.
- **Policy.** `~/.config/macos-harness/policy.yaml` can block apps or
  elements. It ships empty (no restrictions, per the requirements). The test
  suite uses a strict policy of its own.
- **Journal.** Every action is logged as JSON Lines per session with its
  semantic selector, rung used and result. This feeds `flow export`,
  debugging and the user's own audit.

# Flows and recording

- **Flow files** are YAML: `launch`, `find`, `press`/`click`/`type`/`key`,
  `wait`, `expect` (element exists, value, enabled) and `screenshot` steps
  that use selectors, never refs or raw coordinates where avoidable.
  `macos-harness flow run` replays them, saves a screenshot and tree on
  failure, and can write JUnit XML for CI.
- **Export.** `flow export --session <id>` turns a journal into a flow.
- **Recording.** `record start/stop` writes a single window or app to a
  `.mov` with `SCRecordingOutput`; `record frames` pulls stills out with
  AVFoundation, so no ffmpeg is needed.

# Diagnostics

`macos-harness doctor` checks that the helper is running and its version
matches, which permissions are granted (with a button to open the right
System Settings pane; the user flips the switch), pairing state, and whether
Secure Input is on.

[^requirements]: Requirements from the kickoff interview
[^permissions]: macOS permissions for UI automation
[^hosts]: Agent hosts and how they call tools
