---
type: Analysis
title: Second displays, full screen, Spaces and Stage Manager
description: What works when the target window is on a second display, straddles two displays, or is full screen (everything, after fixing half-blank screenshots and drags that dropped onto the desktop), and what's still to check (other Spaces, Stage Manager).
tags: [displays, spaces, full-screen, stage-manager, real-input, screenshots, 1.0]
status: draft
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-14T22:40:00Z }
stale_after: 2027-10-15T00:00:00Z
sources:
  - id: run
    resource: "The dev helper (main after #17 plus these fixes) on the owner's MacBook Pro (built-in 1728×1117 pt at 2×) with an ASUS VG27AQ1A (2560×1440 at 1×) to its right, top edges aligned, “Displays have separate Spaces” on; macOS 27.2; Harness Fixture, the Catalyst build of the iOS fixture and TextEdit on sandbox files; 2026-10-15"
    title: Second-display run
    author: claude-code/claude-opus-5-5
  - id: issue
    resource: https://github.com/TheRogue76/macos-harness/issues/14
    title: "Verify and document multiple displays, Spaces, full screen and Stage Manager (#14)"
---

# Setup

Global coordinates put the built-in display at (0, 0, 1728, 1117) and the
external one at (1728, 0, 2560, 1440). The fixture's pointer flow ran with a
`window: { action: move }` step after launch; the rest were single
commands.[^run]

# A window on the second display

Everything worked: `snapshot`, `find`, `screenshot` (1 px per point there,
2 on the built-in display) and `--element` crops, AX `press`, background
clicks (the canvas reported the same local points as on the built-in
display), `menu` and `menu-select` (Window › Center centered it on the
external display), `record` (the external display's picture), the outline
and the click ripple (the helper's outline window sat 36 pt around the
target), and the whole pointer flow: background and real clicks, a real
drag, hovers, a right-click and its menu, a wheel scroll and real typing. A
drag from a window on the external display into TextEdit on the built-in
one dropped its text.[^run]

# A window straddling two displays

With “Displays have separate Spaces” on (the default), macOS draws a
window only on the display that holds most of it; the rest is hidden, and
the desktop shows there. Two bugs followed from that:[^run]

- **Half-blank screenshots.** On-screen windows were captured from the
  display holding most of them (with only that window included, to avoid
  the child-window distortion in [snapshot format](/design/snapshot-format.md)),
  so the rest came out blank. Now the display capture is used only when
  one display holds the whole window; otherwise the window is captured on
  its own, whole.
- **Drags that dropped onto the desktop.** A drag inside one window checked
  only its start point, so a drag ending on the hidden part reported
  success while the drop went to the desktop. Real input now checks a drag's
  end point too when it's inside the window, and any real click, drag,
  hover, long press or scroll on the hidden part is refused with an error
  saying the point is on another display where macOS doesn't show that part
  of the window. Before, a click there said "covered by Finder", which was
  true but didn't explain why.

Background clicks reach the hidden part, since they go to the window
rather than to a screen point. Recordings show only the display holding
most of the window. With separate Spaces off, a window shows on both
displays, and none of this applies (not tried: it's a system setting).

# Full screen

TextEdit and the Catalyst fixture, full screen on the external display:
`snapshot`, `screenshot`, AX typing, `menu-select`, a real click (the caret
landed at the end of the line aimed at), a real drag selecting a line,
background clicks and a background scroll (Catalyst; AppKit text views
ignore background clicks anywhere) all worked. Moving the pointer to the top
of a full-screen window slides down the menu bar and title bar, which then
cover the window's top ~50 pt, so real input there can hit them instead.
The Mac fixture can't go full screen: its window isn't resizable.[^run]

# Still to check

- **Another Space:** a window on a Space that isn't showing (the
  background route already skips those, and screenshots of them come out
  blank). Needs a second desktop, which the owner sets up.
- **Stage Manager:** a system setting the owner switches on for the test.
- Displays arranged above, below or left of the built-in one (negative
  coordinates), and with separate Spaces off: both are system settings.

[^run]: Second-display run
