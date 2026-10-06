---
type: Design
title: "Helper UI: Control Tower"
description: The chosen menu bar design (direction B) in light and dark, what each surface shows, and the rules behind sessions, stopping, pairing and the on-screen overlay.
tags: [design, ui, menu-bar, pairing, overlay, safety]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-06T19:10:00Z }
sources:
  - id: canvas
    resource: https://claude.ai/artifact/DHWJYPmsrDZHX8coX8myyZ
    title: macOS Harness UI directions (design canvas, private)
    author: claude-code/claude-opus-5-5
  - id: choice
    resource: Design review with human:parsa.nasirimehr, 2026-10-06
    title: Owner's pick of direction B, light and dark
    author: human:parsa.nasirimehr
---

# Decision

Three directions were drawn: A Quiet Native, B Control Tower and C Co-pilot
Island.[^canvas] The owner chose **B**, in both light and dark.[^choice] The
helper follows the system appearance.

One rule across everything: **orange means an agent is in control**. Blue
stays the system's "you".

# Surfaces

| Surface | What it shows |
|---|---|
| Menu bar icon | Template glyph (window with a cursor). An orange dot appears when agents are active or stopped, a pairing request waits, or a permission is missing |
| Panel (click the icon) | Header with an `Idle` / `N driving` / `Stopped` pill and a gear menu (set up permissions, paired agents to revoke, show activity on screen, restart, quit). Session cards: window thumbnail, `agent → app`, last step, `step N · mm:ss · kind`, Stop or Resume. Rows for stopped agents that are idle. Permission chips (click opens setup). The last 5 activities. `Stop all agents ⌃⌥⌘.`, or `Resume all agents` while stopped |
| Pairing card (inside the panel, opens by itself) | Monogram, name, "Signed by <organization> · team <ID>" (or a warning when unsigned), what an allowed agent can do, a "Started from" chain ending in the command, then Deny / This session only / Allow |
| Setup window | Progress ring, a card per permission with a picture of its switch, "Open System Settings", a restart note while Screen Recording is off, and Done once both are on. Opens at launch when a permission is missing |
| Overlay | An orange glow and caption around the window an agent read or captured (fades after ~1.6 s; never on our own windows; switch off in the gear menu). A ripple where an agent clicks, and a "<agent> is driving" panel with Pause and Stop, both for M2 and M3 actions |
| App icon | The Control Tower mark, rendered by `scripts/render-icon.swift` |

# Rules

- **Sessions.** One agent's run of activity; it ends after 120 s of quiet.
  A card gets an orange edge while the agent acted in the last 10 s.
  `hello` and `doctor` aren't activity.
- **Stop.** Per agent from its card, or everyone with Stop all or ⌃⌥⌘. (a
  Carbon hotkey, so it needs no Input Monitoring). Stopped agents' gated
  calls fail with error 1004 and a message telling them to ask the user.
  `hello` and `doctor` still answer and report `stopped`. **Only the user
  resumes**; no command can. Stop state lives in memory, so a helper
  restart clears it.
- **This session only.** The approval lasts while the agent process that
  asked keeps running (its pid, from the process chain), then lapses.
- **Our own UI is never highlighted**, which avoids feedback loops when an
  agent inspects the helper.

# Colours

The organization design system's neutral greys plus its orange, as dynamic
light/dark tokens in `UI/Theme.swift`. Filled orange buttons use `#D93100`
so white text keeps a 4.5:1 contrast.

# Debug commands

Hidden `spike` commands for reviewing the UI without touching real state:
`panel`, `setup [missing]`, `pairing-demo` (a made-up agent; the answer is
discarded), `overlay-demo <app>`, `appearance light|dark|system` (the
helper only) and `stop-all`.

# Not done yet

- The HUD's Pause button and showing the HUD automatically while an agent
  acts (M2/M3).
- A Dock presence: the helper is a menu bar app with no Dock icon by
  design.

[^canvas]: macOS Harness UI directions (design canvas, private)
[^choice]: Owner's pick of direction B, light and dark
