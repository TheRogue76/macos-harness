---
type: Analysis
title: "S10: reaching windows on a Space that isn't showing"
description: A window on another desktop is missing from its app's AXWindows, but AXMainWindow and AXFocusedWindow still return it and a remote-token lookup finds it once its element exists; its tree can then be read, pressed and set, background clicks and keys reach it, and SkyLight's capture (not ScreenCaptureKit) pictures it live, while another app's window can't be moved between Spaces and the harness couldn't open Mission Control.
tags: [spike, spaces, accessibility, skylight, private-api, capture, 1.0]
status: draft
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-17T23:00:00Z }
verified: { by: claude-code/claude-opus-5-5, at: 2026-10-17T23:00:00Z }
stale_after: 2027-04-17T00:00:00Z
sources:
  - id: issue
    resource: https://github.com/TheRogue76/macos-harness/issues/48
    title: "Spike: reach windows on another Space (#48)"
  - id: spike
    resource: "`macos-harness-dev spike offspace` and `spike movespace` (Sources/HarnessMac/SpikeOffSpace.swift) on macOS 27.2 with one display and a second desktop the owner added (Space 99), against a probe app that moves its own window there with SLSMoveWindowsToManagedSpace, and a throwaway Chrome; 2026-10-17"
    title: S10 spike runs
    author: claude-code/claude-opus-5-5
  - id: displays
    resource: /research/displays-and-spaces.md
    title: Second displays, full screen, Spaces and Stage Manager
---

# Question

An agent's Chrome window on another desktop answered every command with
"on another Space (desktop) that isn't showing, where accessibility can't
reach it", and the only way in, `launch --activate`, switched the user's
desktop.[^issue] [Displays and Spaces](/research/displays-and-spaces.md)
found that the app's `AXWindows` leaves such windows out.[^displays] Can
the harness read and act on them anyway, or bring one to the showing
desktop without activating it?

# Method

The owner added a second desktop. A probe app (a window with a button, a
counter and a text field, run as an accessory app) moved its own window
there with `SLSMoveWindowsToManagedSpace`, which works for a process's own
windows, so the owner's view stayed on the first desktop. `spike offspace`
then tried each way in on every window of the app that wasn't on the
showing Space; `spike movespace` tried moving a throwaway Chrome's window.[^spike]

# Results

| Way in | Result |
| --- | --- |
| The app's `AXWindows` | Leaves the window out, as before |
| The app's `AXMainWindow` and `AXFocusedWindow` | Return it, even when it was never read before |
| A remote token (`_AXUIElementCreateWithRemoteToken` with element IDs 0–4999, as window switchers do) | Finds it in under 100 ms once its element exists (ID 42 or 43 here); finds nothing, even through 200,000 IDs, when nothing ever asked the app for that window's element |
| Reading its tree | Works (9 elements, labels and frames) |
| `AXPress` on its button, setting its text field's value | Work |
| A background click (SkyLight, stamped with the window) | Works: the counter went up |
| Background keys to its focused field | Work |
| ScreenCaptureKit | Fails: "Failed to start stream due to audio/video capture failure" |
| SkyLight's `SLSHWCaptureWindowList` | Works, at full resolution, showing the window as it is now (the latest count and the typed text) |
| Moving a throwaway Chrome's window to the other Space with `SLSMoveWindowsToManagedSpace` | Does nothing: Spaces 1 → 1 |

Opening Mission Control to add the desktop from the harness failed every
way tried: `open -a "Mission Control"`, launching it through the helper (it
quits at once), ⌃↑ as real input (the front app was given back, which
closes it) and ⌃↑ posted as live input without giving the front back. The
owner added the desktop by hand.

# What it means

- **Windows on other Spaces can be reached without switching**, through
  the app's main or focused window (public attributes) or a remote-token
  lookup, which needs the window's element to have been handed out once.
  An agent that read its window before the user switched desktops, or a
  window that's its app's main or focused one, is covered; a background
  window of a many-window app that nothing ever read isn't.
- **Everything but real input works there:** reading, accessibility
  actions, background clicks and keys. Real input can't reach a window
  that isn't on screen, so it should keep failing with the Space message.
- **Screenshots need SkyLight's capture** for such windows, since
  ScreenCaptureKit won't capture them.
- **Bringing a window to the showing desktop isn't possible** for another
  app's window without the Dock's privileges (what yabai's scripting
  addition gets by partly turning off SIP), so the harness can't offer it.
- **Chromium** treats a window on another Space as hidden, which pauses
  its page unless it was started with `--disable-backgrounding-occluded-windows`;
  `launch` adds that to instances it starts.

# Built

[#50](https://github.com/TheRogue76/macos-harness/issues/50) put this in
the harness: a window on another Space that isn't in `AXWindows` is reached
through its app's main or focused window, else a remote-element lookup
(resolved at run time, so a macOS without the call only loses that), and
carries `otherSpace`. Snapshots, `find`, `read`, `collect`, accessibility
actions, background clicks, scrolls and keys work there; screenshots come
from SkyLight's capture; steps that need real input fail with a message
saying why, and so does a window neither way reaches. The action diff
counts the window server's off-Space windows for such a target, since
`AXWindows` never lists it and it otherwise read as closed. The fixture
moves its own window to a desktop that isn't showing when launched with
`--other-space`, and `flows/spaces/fixture-other-desktop.yaml` (local only,
it needs a second desktop) presses, sets, clicks and screenshots it there.

# Not tried

A Chrome window on the other Space (a throwaway's window couldn't be put
there without switching the owner's view), macOS 15 and 26, several
displays, full-screen Spaces, and a many-window app whose window on the
other Space is neither main nor focused.

[^issue]: Spike: reach windows on another Space (#48)
[^spike]: S10 spike runs
[^displays]: Second displays, full screen, Spaces and Stage Manager
