---
type: Analysis
title: "S4: which input works while the target app is in the background"
description: AX actions and background key events work without stealing focus or moving the cursor; background mouse clicks are ignored; menu items are disabled until the app is frontmost.
tags: [spike, m0, input, cgevent, accessibility]
status: draft
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-06T16:40:00Z }
verified: { by: claude-code/claude-opus-5-5, at: 2026-10-06T16:40:00Z }
stale_after: 2027-10-06T00:00:00Z
sources:
  - id: spike
    resource: "`macos-harness spike background-calculator|background-keys|menu` with Claude frontmost, macOS 27.2, 2026-10-06"
    title: S4 spike output
    author: claude-code/claude-opus-5-5
---

# Results

With Claude as the frontmost app:[^spike]

| Input | Calculator | TextEdit | Cursor moved |
|---|---|---|---|
| AX press on a button | Works | n/a | No |
| Mouse click posted to the pid (`CGEvent.postToPid`) | Ignored | not tried | No |
| Key with a virtual key code posted to the pid | Works | n/a | No |
| Unicode string key events posted to the pid | n/a | Works, inserted at the text cursor | No |
| AX press on a menu item (File > Export as PDF…) | n/a | Returns success but does nothing: the item is disabled | No |

# What it means for the input ladder

- Rung 1 (AX actions) and keyboard input on rung 2 (background events) work
  without touching the user's cursor or focus. Background mouse clicks don't,
  so clicks without an AX action go straight to rung 3 (real input).
- Many menu commands act on the key window, so they're disabled while the app
  is in the background. Menu actions need the app activated first
  (`AXFrontmost`), which takes focus from the user but doesn't move the
  cursor.
- `AXPress` returns success even on a disabled element. Check `AXEnabled`
  first and report "disabled" instead of "ok".
- Activation can be blocked: when a system alert is up, UserNotificationCenter
  stays frontmost.

# Open

Test background clicks in more apps (AppKit vs SwiftUI vs Catalyst) in M3
before treating "ignored" as universal.

[^spike]: S4 spike output
