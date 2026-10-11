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
cursor, one keyboard focus, one frontmost app. Real-input gestures take a
lease, one at a time; the later M10 steps widen that to fair turns, window
claims and one open menu at a time.[^roadmap]

# Telling sessions apart

An agent is recognized from the caller's process chain, and its key (name,
signing team and identifier) is the same for every session of that agent:
two Claude Code sessions are both `Claude Code|Q6L2SF6YDW|com.anthropic.claude-code`.
The key still decides pairing and policy, so allowing Claude Code once
allows all its sessions.

Everything about a running session uses its **instance**: the key plus the
process recognized as the agent (`…#42957`). The Claude desktop app runs
each Code session as its own `claude` process, and Codex and pi run one
process per session too.

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
