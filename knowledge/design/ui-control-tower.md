---
type: Design
title: "Helper UI: Control Tower"
description: The chosen menu bar design (direction B, refined in October 2026) in light and dark, what each surface shows, and the rules behind sessions, stopping, pairing and the on-screen window marker.
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
  - id: refresh
    resource: https://claude.ai/artifact/6JYfMGVngHSUDSbuHUthAn
    title: macOS Harness UI refresh (design canvas, private)
    author: claude-code/claude-opus-5-5
  - id: refreshChoice
    resource: Design review with human:parsa.nasirimehr, 2026-10-10
    title: Owner's pick of direction 1, Control Tower refined
    author: human:parsa.nasirimehr
---

# Decision

Three directions were drawn: A Quiet Native, B Control Tower and C Co-pilot
Island.[^canvas] The owner chose **B**, in both light and dark.[^choice] The
helper follows the system appearance.

In October 2026 the owner asked for a refresh after three complaints: the
gear wasn't centered, the window outline didn't line up with the window, and
it was drawn over whatever the user was looking at when the agent's window
was behind it or on another Space. A second canvas drew four directions
(Control Tower refined, Beacon, Ledger, Modules);[^refresh] the owner picked
**Control Tower, refined**.[^refreshChoice]

One rule across everything: **orange means an agent is in control**. Blue
stays the system's "you".

# Surfaces

| Surface | What it shows |
|---|---|
| Menu bar icon | Template glyph (window with a cursor). An orange dot appears when agents are active or stopped, a pairing request waits, or a permission is missing |
| Panel (click the icon) | Header: the app mark, the name, an `Idle` / `● N driving` / `Stopped` pill and a 28 pt gear button (set up permissions, paired agents to revoke, show activity on screen, edit policy, show journal, restart, quit). Session cards: window thumbnail (orange ring while the agent acted in the last 10 s), `agent in app`, last step, `now · step N · mm:ss` or `38 s ago · …`, Stop or Resume. Rows for stopped agents that are idle. A readiness line (`Screen Recording and Accessibility are on` and the paired count); chips that open setup only while a permission is missing. The last 5 activities under a divider. Summaries leave element refs out. `Stop all agents ⌃⌥⌘.`, or `Resume all agents` while stopped |
| Pairing card (inside the panel, opens by itself) | Monogram, name, "Signed by <organization> · team <ID>" (or a warning when unsigned), what an allowed agent can do, a "Started from" chain ending in the command, then Deny / This session only / Allow |
| Setup window | Progress ring, a card per permission with a picture of its switch, "Open System Settings", a restart note while Screen Recording is off, and Done once both are on. Opens at launch when a permission is missing |
| Window marker | A 2 pt orange ring just outside the edge of the window an agent read, captured or acted in, with the window's own corner radius and a soft glow, and a tab on its top edge (`Codex · pressed button “Save” · step 14`; inside the title bar, clear of its buttons, when there's no room above). Fades after ~1.6 s; never on our own windows; reads can be switched off in the gear menu |
| Ripple and HUD | A ripple where an agent clicks or presses, left out when another window covers that point, and a "<agent> is driving" panel with Pause and Stop, both for M2 and M3 actions |
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
- **The marker belongs to its window.** It sits at the normal window level,
  ordered directly above the agent's window, so whatever is in front of that
  window covers the ring and tab too. Every 100 ms it rereads the window
  from the window server: it follows moves and resizes, reorders itself if
  the window comes forward, cuts out what covers the window, and hides while
  the window is minimized, hidden or on another Space. The corner radius is
  measured once per window from a capture of its corner (16 pt until then).

# Colours

The organization design system's neutral greys plus its orange, as dynamic
light/dark tokens in `UI/Theme.swift`. Filled orange buttons use `#D93100`
so white text keeps a 4.5:1 contrast.

# Debug commands

Hidden `spike` commands for reviewing the UI without touching real state:
`panel`, `setup [missing]`, `pairing-demo` (a made-up agent; the answer is
discarded), `overlay-demo <app or window ID>`, `appearance light|dark|system` (the
helper only) and `stop-all`.

`screen <x> <y> <w> <h>` saves a capture of part of the screen with the
helper's own windows in it, and `corners <app>` reports each window's
measured corner radius; both are for checking the UI against the design.

# Not done yet

- The HUD's Pause button and showing the HUD automatically while an agent
  acts (M2/M3).
- A Dock presence: the helper is a menu bar app with no Dock icon by
  design.

[^canvas]: macOS Harness UI directions (design canvas, private)
[^choice]: Owner's pick of direction B, light and dark
[^refresh]: macOS Harness UI refresh (design canvas, private)
[^refreshChoice]: Owner's pick of direction 1, Control Tower refined
