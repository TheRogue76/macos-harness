---
type: Analysis
title: M6 acceptance run
description: VS Code, a throwaway Chrome, Slack (read-only) and Spotify all pass their flows; hidden trees switch on for Electron, need a launch flag for CEF, and are already on for VS Code; text recognition and coordinate grids cover content without a tree.
tags: [m6, acceptance, electron, chromium, cef, ocr, findings]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-07T15:00:00Z }
verified: { by: claude-code/claude-opus-5-5, at: 2026-10-07T14:55:00Z }
stale_after: 2027-10-07T00:00:00Z
sources:
  - id: run
    resource: "flow runs and CLI checks on macOS 27.2, 2026-10-07"
    title: M6 acceptance output
    author: claude-code/claude-opus-5-5
---

# Results

| App | Flow | Result |
|---|---|---|
| Chrome, throwaway profile | `flows/chromium/chrome-throwaway.yaml`: a second Chrome with a temporary profile opens the local test page, fills it and checks the greeting | Pass, 3.9 s; the owner's Chrome kept running untouched[^run] |
| Slack | `flows/chromium/slack.yaml`: read-only policy, web content and links readable, minimize refused | Pass, 0.2 s. Slack isn't signed in on this Mac user, so it read the sign-in screen |
| Spotify | `flows/chromium/spotify.yaml`: search, play the top result, pause | Pass, 12.0 s, with the app launched with `--force-renderer-accessibility` |
| VS Code | `flows/chromium/vscode.yaml`: opens a sandbox folder in a new window, edits and saves a file (checked on disk), runs a command from the palette, closes only its window | Pass, 15.7 s; the owner's four windows untouched |

Accessibility tree sizes (first window):

| App | Before | After | Note |
|---|---|---|---|
| Slack (Electron) | 12 | 42 | `AXManualAccessibility`; sign-in screen |
| Spotify (CEF) | 17 | 18 | Neither attribute works |
| Spotify, launched with the flag | – | 4,428 | Read in 0.7 s |
| VS Code (Electron) | 2,502 | – | Already on (3 windows) |

Text recognition read Calculator's result ("408") and its expression line
with click points, and `click --ocr --text 7` pressed the 7 key.

# Findings

1. **CEF apps ignore the accessibility attributes.** Spotify needs
   `--force-renderer-accessibility` at launch; the harness says so in a
   `treeHidden` notice rather than relaunching anyone's app.
2. **VS Code turns its tree on by itself** for an assistive client, so the
   switch must not wait for growth that never comes: a first window with
   40+ nodes counts as on.
3. **Chromium trees reach some elements twice.** Spotify's "Play Miles
   Davis" was reported as ambiguous with itself (same ref twice). Searches
   and snapshots now count an element once.
4. **Typing into Spotify's search needed background keys**: inserting text
   through accessibility doesn't take in its web view, and the harness
   fell back on its own.
5. **A variable inside `vars` stayed literal.** `folder: "${home}/…"` made
   the shell step create a folder literally named `${home}` in the flows
   directory (removed again; nothing outside the repo was touched).
   Variables now expand inside other variables, and an unresolvable
   reference is an error.
6. **A second Chrome never finished launching on GitHub's runner**, and
   the request hung until the client gave up. Launches now time out with a
   clear error; that flow runs locally only.
7. **Slack and Spotify are signed-in apps.** Exploration printed only
   roles, counts and control labels; Slack's flow is private and
   read-only.

[^run]: M6 acceptance output
