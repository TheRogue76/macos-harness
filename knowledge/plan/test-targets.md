---
type: Test Plan
title: Test targets
description: Which apps each milestone is tested against, and the guard rails for apps holding personal data.
tags: [testing, acceptance, safety, built-in-apps]
status: draft
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-06T15:48:51Z }
sources:
  - id: requirements
    resource: /project/requirements.md
    title: Requirements from the kickoff interview
---

# Two kinds of target

- **Fixture app** (`Fixtures/HarnessFixture`): a small SwiftUI + AppKit app
  in this repo with one of every control (buttons, fields, sliders, tables,
  outlines, sheets, popovers, menus, drag and drop, a canvas, a web view) and
  deterministic state. It backs the harness's own automated tests and CI,
  because Apple's apps change between macOS releases.
- **Apple's built-in apps**: the acceptance suite, run on a real Mac at each
  milestone check-in.[^requirements]

# Built-in apps by tier

| Tier | Apps | Rules |
|---|---|---|
| A: no personal data | Calculator, TextEdit, Preview, Font Book, Chess, Clock, Weather, Maps, Stocks (a Catalyst app) | Free to use. TextEdit and Preview only open and save files inside the sandbox folder. Font Book is read-only (never install or remove fonts) |
| B: personal data, test areas | Notes, Reminders, Calendar, Finder, Stickies | Only inside a test area the harness creates and removes: a `macos-harness tests` folder, list or calendar (on the local "On My Mac" account where possible, so nothing syncs to iCloud), and `~/macos-harness-sandbox` in Finder. Stickies moved here from tier A because it can hold the user's own notes |
| C: Safari | Safari | Local test pages served from the repo, private window, never signed-in sites |
| D: communication | Mail, Messages, FaceTime | Read and navigate only. The test policy blocks Send, Reply-send, Call and similar controls, so a bug can't send anything |

Setup and teardown for tier B run before and after each suite, and teardown
also runs when a suite fails partway.

# Later tiers

- Electron and web apps (milestone M6): VS Code, Slack, Figma or whichever
  are installed; they need the user's go-ahead per app since they're
  signed-in work tools.
- iOS Simulator (milestone M8): the fixture app in `fixtures/ios` and the
  apps preinstalled in the simulator (Settings, Safari, the home screen),
  on a simulator named "macos-harness tests" that the work creates with
  `xcrun simctl create` and deletes afterwards. The owner's simulators are
  left alone: never boot, shut down or reset them, and never quit Device
  Hub while one of them runs, since that shuts it down.
- Android (milestone M9): the fixture app in `fixtures/android` and the
  launcher and Settings, on an emulator named `macos_harness_tests` made
  with `avdmanager` from a system image already installed and deleted
  afterwards. Never start, stop, wipe or change the owner's emulators, and
  never act on a connected phone without asking.

[^requirements]: Requirements from the kickoff interview
