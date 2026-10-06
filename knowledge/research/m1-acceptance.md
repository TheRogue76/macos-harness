---
type: Analysis
title: M1 acceptance run
description: Snapshot, find and labeled screenshots work on all ten tier A apps (29–393 ms per snapshot); AX frames in Chess don't match its 3D board, so acting should go through AX rather than coordinates.
tags: [m1, acceptance, built-in-apps, performance]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-06T17:55:00Z }
verified: { by: claude-code/claude-opus-5-5, at: 2026-10-06T17:55:00Z }
stale_after: 2027-10-06T00:00:00Z
sources:
  - id: run
    resource: "scripts/acceptance-m1.sh on macOS 27.2, 2026-10-06, apps opened in the background"
    title: Acceptance script output
    author: claude-code/claude-opus-5-5
---

# Results

`scripts/acceptance-m1.sh` opens every [tier A app](/plan/test-targets.md)
in the background, then snapshots it and takes a labeled screenshot.[^run]

| App | Shown / read | Snapshot | Actionable shown | Screenshot | Notes |
|---|---|---|---|---|---|
| Calculator | 31 / 35 | 69 ms | 26 | 460×816 | |
| TextEdit | 8 / 12 | 29 ms | 5 | 1312×844 | |
| Preview | 38 / 74 | 85 ms | 22 | 1600×1189 | offscreen items |
| Font Book | 149 / 276 | 393 ms | 63 | 1600×1040 | offscreen items |
| Chess | 70 / 72 | 68 ms | 68 | 1600×1173 | AX frames don't match the 3D board |
| Clock | 17 / 22 | 111 ms | 12 | 1600×1200 | |
| Weather | 48 / 104 | 124 ms | 44 | 1600×977 | offscreen items |
| Maps | 61 / 76 | 161 ms | 55 | 1600×1200 | 2 elements without a frame |
| Stocks | 13 / 19 | 72 ms | 11 | 1600×1342 | welcome sheet open |
| Harness Fixture | 27 / 71 | 71 ms | 10 | 840×1256 | 26 rows scrolled out of view |

Every visible control has a ref and a click point. Labeled screenshots show
only the target window.

# Findings

- **Coordinates can lie.** Chess reports its 64 squares as flat rectangles
  over a perspective-drawn board; the bottom ranks' boxes sit above the real
  pieces. Acting through AX (pressing the square) avoids this. M2's ladder
  already puts AX first.
- **Horizontal lists inside plain groups aren't clipped.** Weather's hourly
  strip scrolls inside an `AXGroup` with scroll actions, not an
  `AXScrollArea`, so items past the card edge still count as visible.
- **Minimized windows capture fine.** ScreenCaptureKit returns the last
  contents, which answers the open S2 question. Other Spaces are still
  untested.
- **Refs reset when the helper restarts.** That's safe today (unknown-ref
  error), but M2 must stop an old ref from acting on whatever element now
  holds the same number.
- **Unsandboxed TextEdit and Preview menus disable items when in the
  background**, as S4 found; `menu` now says so.

[^run]: Acceptance script output
