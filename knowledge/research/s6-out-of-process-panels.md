---
type: Analysis
title: "S6: Open and Save panels that run in another process"
description: A sandboxed app's save sheet is drawn by a separate panel service, yet it appears in full in the app's own AX tree and in its window capture, so no special handling is needed.
tags: [spike, m0, accessibility, save-panel, sheets]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-06T16:55:00Z }
verified: { by: claude-code/claude-opus-5-5, at: 2026-10-06T16:55:00Z }
stale_after: 2027-10-06T00:00:00Z
sources:
  - id: spike
    resource: "TextEdit File > Export as PDF… opened via `spike activate` + `spike menu`, inspected with `spike axtree|windows|capture`, cancelled with `spike press`, macOS 27.2, 2026-10-06"
    title: S6 spike output
    author: claude-code/claude-opus-5-5
---

# Result

TextEdit is sandboxed, so its save sheet comes from an
"Open and Save Panel Service (TextEdit)" process. Even so:[^spike]

- **AX tree:** the sheet appears under TextEdit's window as
  `AXSheet "save" id=save-panel`, with every control labeled and identified:
  `saveAsNameTextField`, the `where popup`, `CancelButton`, `OKButton` and so
  on. No remote placeholder, no need to inspect the service process.
- **Pixels:** capturing TextEdit's document window includes the sheet,
  composited in. The service's own window reports as off screen and captures
  blank, so ignore it.
- **Acting:** `AXPress` on `CancelButton` closed the sheet.

# Related findings

- The menu command needed TextEdit frontmost (see
  [S4](/research/s4-background-input.md)).
- Every running sandboxed app keeps its own panel service process with a
  pre-warmed hidden window. `apps --all` lists them as `prohibited` apps;
  filter them out of window lists.

# Not tested

Open panels shown as separate windows (Preview's File > Open…), and
non-sandboxed apps, whose panels run in-process. Check both in M2.

[^spike]: S6 spike output
