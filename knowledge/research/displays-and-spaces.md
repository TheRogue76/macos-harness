---
type: Analysis
title: Second displays, full screen, Spaces and Stage Manager
description: What works when the target window is on a second display, straddles two displays, is full screen, is on another Space or sits in Stage Manager's strip, and the fixes each needed (half-blank screenshots, drags onto the desktop, windows on other Spaces reported as missing, strip screenshots and real clicks failing).
tags: [displays, spaces, full-screen, stage-manager, real-input, screenshots, 1.0]
status: draft
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-14T22:40:00Z }
stale_after: 2027-10-15T00:00:00Z
sources:
  - id: run
    resource: "The dev helper (main after #17 plus these fixes) on the owner's MacBook Pro (built-in 1728×1117 pt at 2×) with an ASUS VG27AQ1A (2560×1440 at 1×) to its right, top edges aligned, “Displays have separate Spaces” on; macOS 27.2; Harness Fixture, the Catalyst build of the iOS fixture and TextEdit on sandbox files; 2026-10-15"
    title: Second-display run
    author: claude-code/claude-opus-5-5
  - id: spaces
    resource: "The same setup with a second desktop on the external display and then Stage Manager switched on, both by the owner; the fixture and TextEdit on a sandbox file; 2026-10-15"
    title: Spaces and Stage Manager run
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

# Another Space

The owner added a second desktop on the external display; the fixture's
window was put there, then the display switched back to its first
desktop.[^spaces]

- **Accessibility doesn't list windows on a Space that isn't showing.** The
  app's `AXWindows` was empty, so every command said the app had no
  windows ("may be hidden, closed, or a menu bar app"), which was wrong.
  The window server still has the window (off screen, with its title and
  frame), and SkyLight's `SLSCopySpacesForWindows` says which Spaces a
  window is on, which tells a window on another Space from one that's
  ordered out (closed but kept: no Spaces).
- Now `windows` lists such windows as "on another Space" (`otherSpace` in
  JSON), and anything that needs one says it's on another Space that isn't
  showing, where accessibility can't reach it, and how to get there. A
  hidden app (⌘H) gets its own message.
- **Reading and acting there is possible after all**: the app's main and
  focused window attributes still return such a window, and background
  clicks, keys and SkyLight's capture reach it
  ([S10](/research/s10-other-spaces.md)); since
  [#50](https://github.com/TheRogue76/macos-harness/issues/50) the harness
  does, and only refuses real input there.
- **The way back is activating the app.** `launch App --activate` on the
  running app switched the display to that desktop (macOS's default
  "switch to a Space with open windows"); it now waits up to 2 s for the
  switch, since it listed the windows before the switch had finished and
  reported none.

# Stage Manager

The owner switched Stage Manager on.[^spaces] With the fixture on the stage,
its flows (accessibility, the pointer flow with real input, the replayed
session) all passed. With TextEdit on the stage and the fixture in the
strip on the left:

- Accessibility still reports the window's stage frame (440×648 at
  226,130), while the window server draws it as a 46×101 thumbnail in the
  strip. `snapshot`, AX `press` and background clicks worked (the canvas
  got the exact point), since none of them depends on where it's drawn.
- **Screenshots failed** with ScreenCaptureKit error -3811: the display
  capture asked for a rectangle the window doesn't occupy. Capturing the
  window on its own works but returns it at thumbnail size. Screenshots
  (and `--ocr`) of a window drawn smaller than its frame now refuse,
  saying it's in the strip and that `window activate` brings it forward.
- **Real clicks were refused** as "covered by WindowManager" (Stage
  Manager's process): the session brought the app forward but checked the
  point before Stage Manager had moved the window back to the stage. Real
  input now waits up to 1.5 s for the window to be drawn at its own frame,
  and says it's in the strip if it never is. Then a real click landed on
  the canvas, and the front went back to TextEdit, which put the fixture
  back in the strip.
- `window activate` brought it to the stage (AX raise failed with -25205,
  so it was made main and focused instead), after which screenshots and a
  real drag worked.

# Not checked

Displays arranged above, below or left of the built-in one (negative
coordinates), and separate Spaces switched off: both are system settings.
The outline overlay is drawn around a window's frame, not its thumbnail,
while the window is in the strip.

[^run]: Second-display run
[^spaces]: Spaces and Stage Manager run
