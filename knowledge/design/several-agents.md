---
type: Design
title: Several agents at once
description: How the helper serves several agents, including several sessions of the same agent, at the same time; what runs in parallel, what can only be shared, and how sessions are told apart (M10).
tags: [design, m10, agents, sessions, concurrency, safety]
status: draft
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-11T08:30:00Z }
sources:
  - id: roadmap
    resource: /plan/roadmap.md
    title: Roadmap, M10 decisions
---

# What runs in parallel

The helper gives every connection (each CLI call, each agent's
`macos-harness mcp` server) its own thread, so reads and accessibility
actions from different agents run at the same time. Refs are shared by all
agents and safe to share: an element keeps its ref and a ref never names
another element, so one agent's snapshot can't break another's refs.

What can only be shared is the real input of the one login session: one
cursor, one keyboard focus, one frontmost app.

# Taking turns with the mouse and keyboard

- **A whole step.** A real-input session holds the lease from bringing its
  app forward, through the gesture, until the result has settled; before,
  the lease covered the gesture only, so another session could pull the
  front away while a menu or popover opened by the first was still being
  read.
- **In order.** Sessions wait in line, first come first served, for up to
  20 s; then error 1007 (`inputBusy`) names who has the mouse and keyboard
  and how many sessions wait ahead. A session that waited says so
  (`waitedForInput`) and retakes its "before" picture, so its change list
  doesn't include the steps it waited for.
- **The front goes back.** After the step the app that was in front is
  brought back (`frontRestored`), so sessions don't leave each other's
  apps, or the user's, behind; not while a menu is open in the target app,
  after a hover or right-click, when something else took the front, or
  while the user is typing.
- **`window activate`** waits its turn the same way; `launch` doesn't, since
  starting an app can take long.

# Keystrokes and other sessions' windows

Background keys land in the app's focused window, whatever window or
element the action named, so with two sessions in one app they could
reach the other session's window.

- **Refused while another session holds the focused window:** `key`
  (including over MCP with an element), and `type` when the app doesn't
  take the text through accessibility and it would go as background keys.
  The error is 1006, naming the window and the session working in it.
- **Already safe:** `type` into a named field (`--into`, or an element over
  MCP) goes through accessibility where the app supports it, without
  touching focus elsewhere; typing or keys without an element aimed at a
  window that isn't focused were already refused, since the focused
  element has to be in the window named; and an action on the focused
  window itself meets that window's claim first.
- **Background first.** The harness already prefers accessibility and
  background keys; real input is used only when asked (`pointer`,
  `--real`) or for an element with no accessibility action, and then it
  takes its turn.

# One open menu at a time

A Mac has one open menu at a time, and any other session's step that
brings an app forward or opens a menu closes it.

- **Menu steps take a turn** with the mouse and keyboard: `menu-select`
  (it brings the app forward and the item acts on its focused window),
  opening a menu bar extra (`menu --extras` with a path, `menu-select
  --extras`), and pressing a pop-up or menu button through accessibility.
- **A menu left open keeps the turn.** After a right-click, or a press that
  opened a pop-up, the turn stays with the session while the menu is open
  (up to 30 s), so other sessions wait instead of closing it. The same
  session gets the turn back at once, to choose an item by `press` or
  `click`; the hold ends when the menu closes. Each turn has its own
  token, so the hold's late release can't end a turn that followed.

# Window claims

Two sessions acting in one window at once would undo each other's work,
so acting in a Mac window claims it for the session:

- **What claims.** `act`, `pointer` (a drag claims its destination window
  too) and `window` actions, in the resolved window, before anything is
  done. Reads (`snapshot`, `find`, `screenshot`, `wait`…) never claim, but
  a read by the holder renews its claim, since it's still working there.
- **How long.** 30 s after the holder's last step in the window. A claim
  ends at once when the holder's process ends or the user stops it (Stop
  all ends every claim).
- **Another session's action** there waits up to 5 s for the claim to end,
  then fails with error 1006 (`windowClaimed`), saying who works in which
  window, how long ago its last step was and when the claim lapses.
- **Seeing claims.** `windows` marks a window another session holds
  `in use by Claude Code · scrubs` (`claimedBy` in JSON); a session never
  sees its own claims there.
- **Devices.** Acting on a simulator or Android device claims the device
  (by UDID or serial; a device that isn't running yet by its name), the
  same way: `act`, `pointer`, and the `sim` and `android` commands that
  change it (install, launch, buttons, settings, boot and shut down; not
  `list`).
- **Menus.** `menu-select` claims the app's focused window, since a menu
  item acts on it, and is refused like a keystroke when another session
  holds that window.
- **Not claimed:** actions without a window (`key` to an app with none),
  and calls inside the helper that aren't for an agent session
  (`unattended`). Flows run through the CLI like any agent's calls, so
  they claim.

`spike claim-demo <window ID>` has a made-up session claim a window, to see
the refusal and the `windows` mark.

# Telling sessions apart

An agent is recognized from the caller's process chain, and its key (name,
signing team and identifier) is the same for every session of that agent:
two Claude Code sessions are both `Claude Code|Q6L2SF6YDW|com.anthropic.claude-code`.
The key still decides pairing and policy, so allowing Claude Code once
allows all its sessions.

Everything about a running session uses its **instance**: the key plus the
process recognized as the agent (`…#42957`). The Claude desktop app runs
each Code session as its own `claude` process, and Codex and pi run one
process per session too. A caller that isn't a recognized agent or
terminal (a script, CI) stays one session per key: the process found for it
can be a new subshell on every call (`$(…)`), which would make a script's
commands block each other.

- **Name.** A session is named by its agent process's working directory:
  its last component (`macos-harness`, or a worktree's name such as
  `musing-golick-ead708`), nothing for `/` or the home folder, and a number
  when two sessions of one agent share a folder (`macos-harness 2`). Names
  last while the process runs. `doctor` shows `Claude Code · macos-harness`.
- **Sessions in the panel.** One card per instance. While only one session
  of an agent is active the card reads as before (`Claude Code in TextEdit`);
  with more, the folder takes the app's place beside the name and the app
  moves to the last line. The Recent list, the window marker's tab and the
  driving panel add the folder only while it's needed to tell sessions
  apart.
- **Stops.** A card's Stop stops that session; its context menu has "Stop
  All Claude Code Sessions" while there are several. A stop also covers
  any process started by the stopped session's process, so a stopped
  session can't get around it by starting a new agent process (a child
  `claude`, say); and stops saved by agent key before sessions were told
  apart still apply. A stopped session whose process has ended is
  forgotten.
- **This session only.** The approval covers the one process that asked;
  another session of the same agent asks again, with its folder on the
  pairing card. "Allow" still covers the whole agent.
- **Ownership.** Recordings and the real-input lease belong to the instance,
  and another agent waiting for the lease is told which session holds it.
- **Journal.** Already kept one session per agent process.

`spike session-demo` adds a made-up second session of the calling agent
to the panel for review.

[^roadmap]: Roadmap, M10 decisions
