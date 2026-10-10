---
type: Design
title: Flows, recording and export
description: The YAML flow format (setup, steps, teardown, variables, guards, run-scoped policy), how flow run reports and saves failures, recording app windows to movies, turning journal sessions into flows, and how CI runs them.
tags: [design, m5, flows, recording, ci, testing]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-07T01:50:00Z }
sources:
  - id: roadmap
    resource: /plan/roadmap.md
    title: Roadmap, M5 decisions
  - id: acceptance
    resource: /research/m5-acceptance.md
    title: M5 acceptance run
---

# A flow

```yaml
name: Calculator multiplies
app: Calculator            # steps act on this app unless they say `app:`
vars:                      # ${name} anywhere; --var name=value overrides
  digit: "4"               # null means "must be given with --var"
private: false             # true: artifacts go to ~/Library/Logs/macos-harness/flow-results
policy:                    # added to the user's policy for this run only
  read_only: [Mail]
setup:
  - launch: { app: Calculator, activate: true }
steps:
  - press: { id: One }
  - type: "3${digit}"
  - expect: { role: text, text: "408", timeout: 5 }
teardown:
  - quit: { app: Calculator, if_launched: true }
```

Built-in variables: `${home}`, `${flow_dir}` (absolute). Unknown keys,
actions and variables are errors that name the step ("step 3 in steps:
unknown key `idd`"); `flow check` reports them without running anything.

# Steps

Elements are selectors: a string (its text) or `{ text, role, id, exact,
ocr }`; `ocr: true` finds the text in the window's pixels instead of the
tree (see [text recognition](/design/chromium-and-canvas.md)). Refs aren't
allowed; they end when the app quits.

| Step | Does |
|---|---|
| `launch`, `quit` | `launch` takes `open`, `activate`, `arguments`, `new_instance` and `as: name` (later steps target that copy by name); `quit` succeeds when the app isn't running; `if_launched: true` quits only an app this run launched |
| `press`, `focus`, `select`, `scroll-to`, `increment`, `decrement`, `set-value`, `type`, `key` | The `act` actions; `type` and `key` take `real: true` |
| `menu: [File, Save…]`, `window: close` | Menu items and window actions; `menu: { path: [Extra, Item], extras: true }` chooses from a menu bar extra (the extra's name may be left out when the app has one) |
| `click` (`right`, `count`), `double-click`, `right-click`, `hover` (`dwell`), `drag` (`from`, `to`), `scroll` (`down`, `up`, `left`, `right`) | Real mouse, on an element or `{ x, y }`; a drag's `to` can add `app` and `window` to end in another app or window (`to: { app: TextEdit, role: textarea }`), with `x`, `y` in that window |
| `wait` | Until an element appears (or `gone: true`), default 10 s |
| `expect` | Retries (default 5 s) until a match has `value`, `enabled`, `focused`, `selected`, `checked`, `visible`, `count`, or is `gone`; values ignore invisible formatting characters |
| `screenshot: name`, `shell: "…"`, `sleep: 0.5` | Artifacts, setup commands (run in the flow's folder), pauses |

Any step can carry:

- `app:` / `window:` to act elsewhere;
- `only_if: { … }` to run only when that element exists. Teardown uses it
  so cleanup never touches something the flow didn't create;
- `refused: true` to pass only if the policy blocks it, which proves a
  read-only policy is in force before reading (tier D).

A step whose only key is `window` is the window action, not a window
choice.

# Running

`flow run <files or folders> [--var k=v] [--junit out.xml] [--artifacts
dir] [--record off|failures|always]`. Each flow gets its own connection, so
its policy restrictions end with it. Setup failures skip the steps;
teardown always runs, every step of it. The first failure saves
`failure.png`, `failure-tree.txt` and `steps.txt` (and `recording.mov`
with `--record`). Exit code 1 if anything failed; JUnit has one test case
per flow.

# Recording

`record start -a App [--out file.mov] [--max 600]` records only that app's
windows (menus and popovers included, nothing else) on the display its
window is on, at 15 fps, at most 1440 px wide, with the cursor. It stops
on its own at `--max`. `record stop [id]` finishes the file; `record
frames file.mov --every 1` saves PNG stills with AVFoundation. MCP agents
have a `record` tool.

# Export

`flow export <session|last>` turns a journal session into a flow:
successful actions in order, reads and failures left out. Elements are
found again by identifier, then role and exact label, then the selector
the agent used. A drag into another window keeps its destination's `app`
and `window` (window IDs only last while the app runs, so edit them for a
later run). Typed text wasn't journaled, so it becomes `${text_N}`
variables set to `null` with the length as a comment; the flow won't run
until they're filled.[^roadmap] Add `expect` steps for what should be
true afterwards.

# Where flows live

| Folder | Runs | Notes |
|---|---|---|
| `flows/fixture` | CI and locally | Includes a recorded agent session, exported and replayed[^acceptance] |
| `flows/apps` | CI and locally | Tier A apps (Calculator) |
| `flows/tier-b` | Locally only | Notes, Reminders, Calendar test areas; private |
| `flows/tier-c` | Locally only | Safari, local file in a private window |
| `flows/tier-d` | Locally only | Mail, Messages, FaceTime read-only; private |
| `flows/chromium` | Locally only | VS Code (sandbox folder), a throwaway Chrome, Slack read-only, Spotify |

CI (`.github/workflows/ui.yml`) installs an ad-hoc signed dev build, starts
the helper as a child of the job's shell with
`MACOS_HARNESS_AUTO_APPROVE=1` (see [S5](/research/s5-ci-permissions.md)),
hides the Dock, and runs `flows/fixture` and `flows/apps` with `--record
failures` and JUnit output, uploading `flow-results`.

[^roadmap]: Roadmap, M5 decisions
[^acceptance]: M5 acceptance run
