---
type: Analysis
title: "S3: AX tree quality and speed in Apple's built-in apps"
description: Every tier A app exposes a usable tree in 19–233 ms; Catalyst apps nest deeply and leak debug strings; one app reports NaN geometry, which crashed the helper until frames were sanitized.
tags: [spike, m0, accessibility, ax-tree, catalyst, performance]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-06T16:40:00Z }
verified: { by: claude-code/claude-opus-5-5, at: 2026-10-06T16:40:00Z }
stale_after: 2027-10-06T00:00:00Z
sources:
  - id: spike
    resource: "`macos-harness spike axstats|axtree` on the tier A apps and the fixture app, macOS 27.2, 2026-10-06"
    title: S3 spike output
    author: claude-code/claude-opus-5-5
---

# Numbers

Full walk of each app's windows and of its menu bar, from the helper.[^spike]

| App | Window nodes | Depth | Time | Interactive | Menu bar nodes (time) |
|---|---|---|---|---|---|
| Calculator | 37 | 6 | 45 ms | 25 | 214 (103 ms) |
| TextEdit | 12 | 2 | 20 ms | 5 | 365 (102 ms) |
| Preview | 74 | 9 | 37 ms | 22 | 467 (195 ms) |
| Font Book | 276 | 11 | 233 ms | 18 | 247 (83 ms) |
| Chess | 72 | 2 | 22 ms | 68 | 203 (49 ms) |
| Clock | 22 | 5 | 88 ms | 8 | 224 (106 ms) |
| Weather | ~80 | 14+ | 72 ms | 9+ | 217 (82 ms) |
| Maps | 49 | 11 | 81 ms | 20 | 254 (95 ms) |
| Stocks | 19 | 5 | 24 ms | 5 | 283 (111 ms) |
| Harness Fixture | 17 | 4 | 19 ms | 6 | 197 (84 ms) |

# Findings

- **Good enough to act on.** Buttons carry titles or descriptions, and many
  have identifiers. Chess exposes all 64 squares as buttons, so moves may not
  need dragging. Menu bars are large (200–470 items) and should only be walked
  on demand.
- **"Unlabeled" is mostly window chrome.** The close, minimize and zoom buttons
  and scroll bar parts have no title, but their subrole (`AXCloseButton`, …)
  names them. Use the subrole as the fallback label.
- **SwiftUI fixture is clean.** `.accessibilityIdentifier` shows up as
  `AXIdentifier`; a `Toggle` is `AXCheckBox/AXSwitch` with value 0/1.
- **Catalyst and iOS-style apps (Weather, Stocks) are noisy.** Content sits
  under an `iOSContentGroup` with many empty wrapper groups that all expose
  `AXCancel`. Custom actions arrive as raw debug strings
  (`Name:Delete\nTarget:0x0\nSelector:(null)`), so parse the `Name:` part.
  Items scrolled out of view keep frames outside the window, so clip by the
  window frame. SwiftUI sometimes exposes the same control twice.
- **Geometry can be NaN or infinite.** Weather reports such a frame. Converting
  it to `Int` trapped and killed the helper, because Swift runtime traps can't
  be caught. Every frame and number from AX must be checked for finiteness
  (now done in `AX.frame`).
- **Sheets and dialogs appear in the tree.** Stocks' welcome sheet shows as
  `AXSheet` with its full content. A system alert (another app's privacy
  prompt) is readable as `AXSystemDialog` in UserNotificationCenter, so the
  harness can report "a system dialog is blocking" to the agent.

# Design consequences for M1

Prune empty wrapper groups, label with title → description → value → subrole,
clip to the visible window, parse custom action names, treat AX data as
untrusted input, and set a messaging timeout on every app element.

[^spike]: S3 spike output
