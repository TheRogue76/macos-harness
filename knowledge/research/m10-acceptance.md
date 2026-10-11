---
type: Analysis
title: M10 acceptance run
description: Several agent sessions at once, the others played by the helper's review commands; sessions told apart, window claims, keys and menu commands kept out of another session's window, turns with the mouse and keyboard, and context menus that stay open all pass twice; findings cover the slow replies that broke iOS CI and the menu bar icon that closed menus.
tags: [m10, acceptance, agents, sessions, claims, turns, findings]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-11T14:30:00Z }
verified: { by: claude-code/claude-opus-5-5, at: 2026-10-11T14:25:00Z }
stale_after: 2027-04-11T00:00:00Z
sources:
  - id: run
    resource: "scripts/acceptance-m10.sh with the dev build on macOS 27.2, run twice on 2026-10-11"
    title: M10 acceptance output
    author: claude-code/claude-opus-5-5
  - id: ci
    resource: "UI flows runs on GitHub's xcode-27 image, 2026-10-11, with stage timing added on a test branch"
    title: iOS CI investigation
    author: claude-code/claude-opus-5-5
---

# Results

The owner chose to play the other sessions with the review commands
(`session-demo`, `claim-demo`, `turn-demo`) rather than run three real
agents. `scripts/acceptance-m10.sh` runs them next to the session that
runs it; both runs passed all 20 checks.[^run]

| Check | Result |
|---|---|
| `doctor` names the session by its folder; a made-up second session of the same agent joins the panel | Pass |
| Window claims: `windows` marks the held window, reads still work, an action is refused with 1006 after about 5 s naming who works there, works once the claim lapses, and this session's claim then refuses the made-up one | Pass |
| A key over MCP aimed at this session's window, which would land in the other session's focused window, is refused; so is a menu command acting on it; typing into this session's own field works and the other document is untouched | Pass |
| A click waits its turn behind a made-up session for most of its 10 s, says so, clicks, and gives the front back | Pass |
| A right-click's context menu stays open: an item can be chosen 5 s later, and the next click doesn't wait once it closed | Pass |
| Unit tests | 199 of 199 |

Not covered by the run: claims on simulators and Android devices (unit
tests cover the claim keys), and error 1007 for a turn held longer than
20 s (unit tests cover it).

# Findings

1. **Replies waited for on-screen feedback.** Every M10 commit failed CI's
   iOS flow at a different step, while 0.7.0 passed. Stage timing on a
   test branch showed the router's observer taking up to 3.3 s after a
   request on the runner: it recorded activity and drew the window marker,
   ripple and driving panel on the main thread before the reply, and M10
   added main-thread calls to it. Recording after the reply brought that to
   a median of 0 ms, and the flow then passed 4 of 5 runs, as 0.7.0 did;
   the remaining failure was one simulator read stalling for 99 s, the
   runner's own flakiness.[^ci]
2. **The menu bar icon closed other apps' menus.** Re-setting its
   attention dot on every update, even to the same value, closed a
   right-click's context menu in another app within 2–5 s, too soon for an
   agent to choose from it. Found while building step 5, by turning parts
   of the helper off one at a time.
3. **Scripts can't be told apart by process.** The process found for an
   unrecognized caller can be a new subshell on every call (`$(…)`), so
   scripts and CI stay one session per key; otherwise a script's commands
   would claim windows from each other.

[^run]: M10 acceptance output
[^ci]: iOS CI investigation
