---
type: Analysis
title: M2 acceptance run
description: All four M2 tasks pass without real input; along the way the run exposed focus stealing during user typing, keys not reaching out-of-process save panels, a focus race after new windows, toggle menus, and child windows distorting captures — each now handled.
tags: [m2, acceptance, findings, safety, screenshots]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-06T20:40:00Z }
verified: { by: claude-code/claude-opus-5-5, at: 2026-10-06T20:31:00Z }
stale_after: 2027-10-06T00:00:00Z
sources:
  - id: run
    resource: "scripts/acceptance-m2.sh and manual CLI runs on macOS 27.2, 2026-10-06"
    title: M2 acceptance output
    author: claude-code/claude-opus-5-5
---

# Results

`scripts/acceptance-m2.sh`, all passing:[^run]

| Task | How | Check |
|---|---|---|
| 12 × 34 in Calculator | `press --id` on each key, in the background | display reads 408 |
| Write, bold, save a TextEdit document to the sandbox | `menu-select File New`, `type` (AX insertion), Select All, Format › Font › Bold, `menu-select File Save…`, ⇧⌘G and Return to the save panel, `set-value` the path and name, `press OKButton` | the `.rtf` exists and uses Helvetica-Bold |
| Page through a PDF in Preview | `menu-select Go Down` twice | title reads "Page 2 of 3" |
| Switch cities in Weather | `press --text Stockholm --role button` | title reads "Stockholm" (switched back afterwards) |

The MCP server was checked with a scripted stdio session: handshake, 13
tools, a press with its change report, a screenshot as an image, and a
failing call returned as `isError`.

# Findings, and what changed because of them

1. **Taking focus while the user types loses their keystrokes.** During a
   manual run, activating TextEdit while the user was typing elsewhere
   replaced the document's text with "At" and dismissed the save sheet. Now
   `menu-select` and `window activate` wait for a typing pause and refuse
   otherwise, and results warn if the user typed while an agent had the app
   in front.
2. **Keys sent to an app don't reach its out-of-process save panel.** AX
   sees the panel through the app, but ⇧⌘G went nowhere until it was posted
   to "Open and Save Panel Service (TextEdit)". `key` now routes there when
   a sheet is open.
3. **Focus lags behind new windows.** Right after File › New, the app's
   focused element was still in the previous document, so text typed "into
   the focused element" landed in the wrong window. `type` now refuses when
   the focus is in another window.
4. **Menu toggles flip.** Format › Bold turned bold off when the text was
   already bold. The change report shows `checkbox "bold" on → off`; agents
   should read it.
5. **Single-window capture includes child windows and shrinks them into the
   frame.** A 53×48 TextEdit child window beside the document made captures
   about 6% smaller and offset. On-screen windows are now captured from
   their display with only that window included, cropped to its frame.
   Minimized windows still use the single-window filter.
6. **Settling is slow in big Catalyst trees.** Weather took 4.6 s to settle
   because each read takes ~0.5–1 s. That's acceptable for now; AX
   notifications could replace polling later.
7. **Menu item titles change with state.** "Save…" for new documents,
   "Save" for saved ones. Agents should read `menu` before choosing.

[^run]: M2 acceptance output
