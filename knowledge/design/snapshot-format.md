---
type: Design
title: Snapshot format and pruning rules
description: What `snapshot`, `find` and `screenshot` show an agent, how the raw AX tree is pruned, how refs and coordinates work, and which notices exist.
tags: [design, m1, snapshot, refs, coordinates, accessibility]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-06T17:55:00Z }
sources:
  - id: s3
    resource: /research/s3-ax-tree-quality.md
    title: "S3: AX tree quality and speed"
  - id: acceptance
    resource: /research/m1-acceptance.md
    title: M1 acceptance run
---

# Output

One element per line, children indented two spaces:

```
e5 button "Increment" id=increment-button @69,131
e6 button "Locked" id=locked-button disabled @60,172
e11 switch off id=enabled-toggle @377,286
e16 slider "0.5" id=volume-slider actions: increment, decrement @291,415
e11 button "Stockholm, 13°" actions: Trash, Delete @136,447
e1 window "Nacka" (+34 more)
```

- `eN` is the ref. Roles are shortened (`AXStaticText` → `text`; subroles win
  where they're clearer, as with `switch`, `tab` and `searchfield`).
- Label (title, then description, then placeholder) in quotes; a value follows
  as `= "…"`. Static text shows its text directly. Toggles show `on` or `off`.
- `id=` appears only for identifiers a developer chose. Toolkit noise such as
  `_NS:8` or `_TtGC7SwiftUI…` is hidden.
- `disabled`, `focused` and `selected` appear only when true. `actions:` lists
  actions other than press.
- `@x,y` is the click point: the center of the element's visible part, in
  window-relative points (top-left origin).
- `(+N more)` marks descendants left out by limits; `snapshot --root eN`
  shows them.
- `--json` returns the same data, structured. Failures then print
  `{"error": {"code": 1004, "message": "…"}}` on stdout instead of text on
  stderr, with the JSON-RPC error code (1001 pairing denied, 1002 permission
  missing, 1003 failed, 1004 stopped by the user); the exit code is 1 either way.

# Pruning

The helper reads the raw tree (hard limits: 2,000+ nodes, a 3 s budget, a
1.5 s AX timeout per call), then:[^s3]

1. Drops scroll bars, their parts and splitters.
2. Collapses groups, scroll areas, split groups and generic elements that
   have no label, value, meaningful identifier or meaningful action; their
   children move up a level.
3. Clips to the window and to each scroll area. Fully hidden elements are left
   out and counted in an "offscreen" notice; `find` still searches them.
4. Names window buttons from their subrole (`close`, `minimize`, `zoom`,
   `full screen`) and hides their insides.
5. Drops bookkeeping actions (`AXCancel`, `AXShowMenu`, scroll-by-page,
   `AXConfirm`, `AXRaise`) and turns UIKit custom actions into their names.
6. Drops static text that only repeats its parent's label.
7. Rejects any geometry that isn't finite or is absurdly large.

# Refs

- A letter plus a number (`k12`). The letter changes each time the helper
  starts; numbers never repeat within a launch, across all apps.
- The same element keeps its ref across snapshots while it exists.
- Unknown refs, refs from an app that has since relaunched, and refs from an
  earlier helper launch all give an error asking for a new snapshot, never a
  different element.

# Coordinates and screenshots

- Everything is in window-relative points. A screenshot reports its scale:
  window point = pixel ÷ scale, plus the crop origin when cropped.
- Screenshots capture one window only, even when it's covered or minimized
  (a minimized window shows its last contents). On-screen windows are taken
  from their display with only that window included, because the
  single-window filter also draws child windows and shrinks the result. The
  default cap is 1,600 px on the longest edge (1,280 over MCP).
- `--labels` draws refs on everything that can be acted on.
- AX frames can be wrong for apps that draw their own content. Chess's
  squares are flat rectangles over a 3D board, so click points near the bottom
  miss. Prefer acting through AX over clicking at coordinates.[^acceptance]

# Notices

Printed as `! …` above the tree:

| Kind | Meaning |
|---|---|
| `systemDialog` | A system dialog is in front (its text and buttons are quoted); the agent shouldn't answer it for the user |
| `notFrontmost` | The app isn't frontmost: reading works, menus and real input need it in front |
| `sheet` | A sheet is open on the window (it's part of the tree) |
| `minimized` | The window is minimized |
| `secureInput` | Secure Input is on; typed keys will be blocked |
| `truncated` | Limits left elements out |
| `offscreen` | Elements are scrolled or clipped out of view |
| `blank` | The screenshot came out blank |

[^s3]: "S3: AX tree quality and speed"
[^acceptance]: M1 acceptance run
