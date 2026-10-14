---
type: Analysis
title: Why drags stopped with "the user moved the mouse" on GitHub's runners
description: Six of 26 macOS flow runs between 11 and 14 October 2026 stopped the fixture's drag as its drag-and-drop session began, and one recording shows the cursor back at the spot it rested on before the step rather than moved by anyone; the check now only calls it the user's when no event of the step, no lag behind those events and no return to that resting spot explains where the cursor is, and puts the cursor back after such a return.
tags: [ci, real-input, guard-rails, drag, flakiness]
status: draft
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-14T21:30:00Z }
stale_after: 2027-04-14T00:00:00Z
sources:
  - id: runs
    resource: "The `flows` job of the UI flows workflow on GitHub's macos-15 runner: failed runs 38136912781, 38138755098, 38138759156, 38138763041, 38164397341 (11 October) and 38627000999 (14 October), and 20 runs between them that passed the drag, with the failed runs' artifacts (steps, failure tree and screenshot, and a 13 fps recording of the 1024×768 screen)"
    title: macOS flow runs, 11–14 October 2026
    author: claude-code/claude-opus-5-5
  - id: issue
    resource: https://github.com/TheRogue76/macos-harness/issues/16
    title: "\"The user moved the mouse\" on CI runners with no user"
    author: human:parsa.nasirimehr
---

# What failed

The fixture flow's `drag: { from: { id: drag-source }, to: { id:
drop-target } }` failed with "The user moved the mouse, so the action
stopped partway." in 6 of the 26 `flows` jobs run between 11 and 14
October; the other 20 passed it.[^runs][^issue] Three runs dispatched
together at 12:18 on 11 October all failed. A failing drag step took
2.1–2.3 s, a passing one 4.4–5.2 s (which includes the drop and the
settle afterwards).

# What the recordings show

- In all six recordings the stop comes at the same moment: the cursor
  reaches "Drag me", the button goes down, the translucent drag image of the
  fixture's drag-and-drop session appears a few points from the start, and
  the next frame shows the drag cancelled (Escape, then the button released
  at the start). The drag never got past its first few events.[^runs]
- In run 38627000999 the frame after the press has no cursor on
  "Drag me": the cursor is back in the screen's top-left corner, on the
  same pixel it sat on when the recording began. That's where the runner's
  cursor rests, and where every real-input step puts it back when it ends.
  The next frame shows it at the drag source again (the cancel). In the
  other five the 77 ms between frames missed that moment: the cursor only
  stays there until the next check, at most 16 ms, and the cancel.[^runs]
- Nothing in the harness moves the cursor mid-step: the only warp is the
  restore when a step ends.

So the cursor wasn't moved by a user: as the drag-and-drop session began,
something put it back where the system last had it before the step's
posted events. The likely mechanism, not verified, is that the runner's
pointer position as the HID system (or the VM's virtual pointing device)
knows it isn't updated by posted events, only by warps, and starting a drag
session makes macOS fall back to it. Nothing in the frames shows the window
server lagging behind the posted events, the other suspect.

# Why the old check fired

The check compared the cursor with the last point the step had posted and
stopped at more than 3 pt. The system's idle counters can't help during a
drag: the harness's own events reset them every 16 ms, and input only
counts as the user's when it's at least 50 ms newer than the harness's
last event ([M3](/research/m3-acceptance.md) #2).

# What changed

- The cursor counts as moved by the user only when it's more than 3 pt
  from every place the step explains: the last posted point, the points
  posted in the 0.25 s before it (a window server that hasn't caught up),
  and where the cursor rested before the step or where the harness last
  warped it (the system putting it back). After such a return the step
  posts its last point again and carries on.
- A key press during a pointer step, after it began and more than 0.25 s
  after the harness's own last key event, now stops it too ("The user
  typed"). Pointer steps post no keys while they move, so the idle counter
  tells the user's keys apart. A stop pressed with ⌃⌥⌘. still reads as a
  stop: the check waits 150 ms for it before blaming typing.
- A user moving the mouse during a drag still stops it: their movement
  starts from the cursor's current place, so it lands off the posted path
  and away from the resting spot. Only a move that ends within 3 pt of one
  of those goes unseen for that check, and the next event moves the cursor
  on anyway.

# How to confirm

On CI, the fixture flow's drag step passing in every `flows` job over at
least a dozen runs, including several dispatched at once; at the old rate
(6 of 26 failed) twelve passes in a row would happen by chance about 5 % of
the time.

[^runs]: macOS flow runs, 11–14 October 2026
[^issue]: "The user moved the mouse" on CI runners with no user
