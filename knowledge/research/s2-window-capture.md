---
type: Analysis
title: "S2: capturing windows with ScreenCaptureKit"
description: Single-window capture works for covered windows in 14–170 ms with no other app's pixels; invisible helper windows must be filtered; minimized and other-Space windows are still untested.
tags: [spike, m0, screenshots, screencapturekit]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-06T16:40:00Z }
verified: { by: claude-code/claude-opus-5-5, at: 2026-10-06T16:40:00Z }
stale_after: 2027-10-06T00:00:00Z
sources:
  - id: spike
    resource: "`macos-harness spike windows|capture` on TextEdit, Calculator and Preview, macOS 27.2, 2026-10-06"
    title: S2 spike output
    author: claude-code/claude-opus-5-5
---

# Result

`SCScreenshotManager.captureImage` with
`SCContentFilter(desktopIndependentWindow:)` captures exactly one window, even
while another app's window covers it.[^spike]

| App | Size (px) | Time | Content |
|---|---|---|---|
| TextEdit document | 1312×844 | 166 ms first call, 63 ms later | Correct, covered by Claude at the time |
| Calculator | 460×816 | 14 ms | Correct |
| Preview (PDF) | 2546×1896 | 21 ms | Correct |

The output has transparent rounded corners and no shadow
(`ignoreShadowsSingleWindow`), with `pointPixelScale` = 2 on this display.

# Gotchas

- Apps own invisible windows (TextEdit has a 500×500 off-screen window, and
  each app's Open and Save Panel Service keeps a pre-warmed one). They capture
  as solid color. Filter on `isOnScreen` plus the AX window list, not on
  ScreenCaptureKit's list alone.
- SCWindow titles need Screen Recording; without it, only owner and frame are
  available.

# Not tested yet

Minimized windows and windows on another Space. Test both in M1, since the
roadmap promises "covered windows" only.

[^spike]: S2 spike output
