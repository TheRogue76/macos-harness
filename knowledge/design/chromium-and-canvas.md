---
type: Design
title: Chromium apps, text recognition and grids
description: How the harness reads Electron, CEF and Chrome apps (switching on their hidden accessibility trees), runs a throwaway browser instance, and works with content that has no tree through text recognition and coordinate grids.
tags: [design, m6, electron, chromium, cef, ocr, canvas]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-07T15:00:00Z }
sources:
  - id: roadmap
    resource: /plan/roadmap.md
    title: Roadmap, M6 decisions
  - id: acceptance
    resource: /research/m6-acceptance.md
    title: M6 acceptance run
---

# Hidden trees

Chromium-based apps build their accessibility tree only when an assistive
app asks. The helper recognizes them by the framework in their bundle:
`Electron Framework` (VS Code, Slack, Notion…), `Chromium Embedded
Framework` (Spotify) or a Chromium browser framework (Chrome, Edge, Brave,
Arc…).

The first time an agent reads or acts on one (snapshot, find, act,
pointer, wait), the helper:

1. reads the first window; 40 nodes or more means the tree is already on
   (VS Code switches it on for any assistive client);
2. otherwise sets `AXManualAccessibility` on the app, waits up to 2 s for
   the tree to grow, then tries `AXEnhancedUserInterface` the same way;
3. reports `treeEnabled` ("Switched on Slack's accessibility tree…") or,
   when neither worked, `treeHidden` with the fix: relaunch the app with
   `--arg=--force-renderer-accessibility`.

It switches the tree on automatically, per the owner's decision.[^roadmap]
CEF apps such as Spotify ignore both attributes; launched with the flag,
Spotify exposes over 4,000 nodes.[^acceptance] The flag can be passed
through `launch --arg=…`, MCP `args`, or a flow's `launch: { arguments: […]
}`. A value starting with `-` needs the `--arg=` form.

Chromium trees reach some elements by two paths. Searches and snapshots
count an element once (by identity), so selectors don't report false
ambiguity.

# A browser of the agent's own

`launch --new-instance` starts another copy of an app that's already
running, and the result gives its pid to target (`-a 97121`). With a
temporary profile, that's a Chrome with no sign-ins, beside the user's:

```yaml
- launch:
    app: Google Chrome
    new_instance: true
    as: test-chrome          # later steps say app: test-chrome
    arguments: ["--user-data-dir=/tmp/macos-harness-chrome-profile",
                --no-first-run, --no-default-browser-check,
                --force-renderer-accessibility, "file:///…/page.html"]
```

`quit: { app: test-chrome, if_launched: true }` quits that copy only. On
GitHub's runner, launching a second Chrome never completed, so that flow is
local only; any launch now gives up after its timeout plus 15 s.

# Text recognition

For text the tree doesn't have (canvases, a hidden tree, rendered
images):

- `find --ocr "Play" -a App` reads the window's pixels with Vision
  (accurate mode, no language correction) and returns each match with a
  click point. When the text is part of a longer line, the point is that
  text's own box, not the line's. Matches get refs `o1`, `o2`, … that
  can't be pressed. Without text it lists every line read.
- `click`/`hover`/`drag`/`scroll --ocr --text "Play"` act on that point,
  preferring a line that is exactly the text, and list the places instead
  of guessing when there are several. `press` and other accessibility
  actions refuse OCR text.
- Flows take `ocr: true` in a selector, so `expect` can check drawn text.

It reads labels and running text well and single glyphs in round buttons
poorly (Calculator's digit keys).

# Coordinate grids

`screenshot --grid 100` (MCP `grid`) draws translucent lines every 100
window points, labeled with their coordinates, so an agent can name a
point on a canvas and use `click --x --y`. It works with crops
(`--element`) and with `--labels`.

[^roadmap]: Roadmap, M6 decisions
[^acceptance]: M6 acceptance run
