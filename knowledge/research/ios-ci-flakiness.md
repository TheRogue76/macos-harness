---
type: Analysis
title: Why the iOS UI flow fails on GitHub's runners
description: Twenty failed iOS flow runs between 9 and 14 October 2026 came down to Device Hub's accessibility bridge being slow on a loaded runner (scroll searches running out of time, the client giving up on the helper), the Home press not taking, the home screen's dock missing from the bridged tree, and a crash dialog from a simulator app covering the screen; the job now boots the simulator first, builds the fixture before Device Hub opens, turns crash dialogs off, checks Home took, and checks the app left instead of looking for Safari.
tags: [ci, ios, simulator, device-hub, flakiness]
status: draft
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-14T16:40:00Z }
stale_after: 2027-04-14T00:00:00Z
sources:
  - id: runs
    resource: "Failed `ios` jobs of the UI flows workflow on the xcode-27 image (iOS 27.0 simulators): runs 37989087958, 37990707577, 38060134976, 38123396168, 38123813659, 38124405266, 38124731832, 38127436908, 38127440626, 38135830012, 38135834684, 38136916806, 38136912781, 38138755098, 38165471016, 38569733569, 38571851629, 38574252972, 38574815167 and 38577174761, with the artifacts of eight of them (steps, failure trees and screenshots, recordings, the screen and the helper journal)"
    title: iOS CI failures, 9–14 October 2026
    author: claude-code/claude-opus-5-5
  - id: home
    resource: "The `ios` job of UI flows run 38636205832 (commit 309efd1, 14 October 2026): steps, failure screenshot, simctl recording, `top` sample"
    title: iOS Home failure, run 38636205832
    author: claude-code/claude-opus-5-5
  - id: local
    resource: "The dev helper (0.9.0 plus these changes) against a new iPhone 18 Pro simulator on iOS 27.0 booted the way the new job does, Device Hub (Xcode 27.1), macOS 27.2, 2026-10-14"
    title: Local check of the new CI order
    author: claude-code/claude-opus-5-5
---

# What failed

Of 20 failed `ios` jobs, at least 13 reached a different step from the
others' failures.[^runs]

| Step | Failures | What the artifacts show |
| --- | --- | --- |
| `wait for id=Safari` after `sim button home` | 6 | Twice the app was still in front: Device Hub's Home button didn't take, and the Controls › Home fallback didn't either (the step reported success). Once Home worked but the bridged home screen listed only the first page's icons, not the dock with Safari. Once a "MobileCal quit unexpectedly" dialog sat over Device Hub. |
| `scroll-to id=last-item`, `press id=item-35` | 4 | The 35 s search ended after 0–2 pages: each page and read took several seconds. |
| `expect` or `press` timing out, "timed out waiting for the helper" | 3 | The helper didn't answer within the client's wait, twice on the first steps right after the flow's 70–110 s build. |
| `swipe id=swipe-target` | 1 | "Covered by UserNotificationCenter": a simulator app's crash dialog in the middle of the screen. |
| others (`wait for id=details-link`, `expect id=volume-value`, `sim button home`, `press id=alert-button`) | 4 | Reads taking 6–60 s. |

The macOS `flows` job failed separately on a drag stopped with "The user
moved the mouse" (5 runs on 11 October), which a runner has no user to do;
that's a different problem from the ones here, now explained in
[why drags stopped on CI](/research/ci-drag-stops.md).

# Why

- **The bridge is slow when the machine is busy.** Device Hub serves the
  simulator's elements over its accessibility bridge, and a fresh
  simulator spends minutes on first-boot work while the job builds the
  fixture next to it. On the runner a tree read took 1.4–6.6 s and single
  steps up to 60 s; the whole flow took 4–12 min against about 1 min on
  the dev Mac before. On the dev Mac under heavy load (load average near
  500) Device Hub's window tree read at 72 ms per element and the same flow
  slowed to 3–4 min.[^local]
- **Home can fail without saying so.** The Home press waited 3 s for the
  screen to change, then chose Controls › Home once and reported success
  either way. In the passing run the toolbar button didn't take either
  (the step took 4 s, the fallback's time).
- **The dock isn't always in the bridged tree.** On the runner the home
  screen's first page showed and the dock (Safari, Messages) didn't, 45 s
  later; on the dev Mac it appears once loaded.
- **Crash dialogs.** Simulator system apps (Calendar, Preferences) crash on
  the runner, and macOS shows their reports as dialogs that cover the
  screen and take focus ([S7](/research/s7-simulator-window.md)).

# What changed

- The job turns crash dialogs off (`defaults write com.apple.CrashReporter
  DialogType none`), creates and boots the simulator before building the
  harness, builds the fixture with `macos-harness build --sim` while the
  simulator finishes booting (so the flow's own build has nothing to do),
  then waits for `simctl bootstatus` and opens Device Hub with `sim boot`.
  Device Hub still starts after the simulator is running, which it needs.
- `sim button home` checks the screen changed after the toolbar button and
  after each of two Controls › Home tries, and fails with a clear message
  when it never did instead of reporting success.
- The flow checks the app left after Home (`wait: { id: tap-button, gone:
  true }`) instead of waiting for Safari's dock icon.
- Failure diagnostics take a second `top` sample (the first always reads
  0 % CPU) and read the helper's log by its process name,
  `macos-harness-helper` (the old predicate named the app and matched
  nothing).

The local check confirmed the new order works (pre-build 25 s, the
flow's build 11 s on the second run, Home took on the first press and the
app was gone 2 s later), but the machine was too loaded to compare speeds,
and the real-input steps stopped because the owner was using the Mac.
Whether the runner passes more often has to be measured there.

# Still open

- Scroll searches and slow reads under load: the 35 s search limit and the
  client's 60 s wait may still be too short on a slow runner.
- The macOS drag's "user moved the mouse" on a runner with no user: see
  [why drags stopped on CI](/research/ci-drag-stops.md).
- Home that never takes. On the first run with the new checks (run
  38636205832, 14 October, load average near 300) all three Home tries
  failed over 18.6 s: Device Hub's toolbar button, then Controls › Home
  twice. The step now said so instead of passing, and simctl's recording
  shows the app in front for the whole step, so the presses never reached
  the simulator.[^home] Earlier runs on the same changes passed (5 of 6
  confirmation runs that day passed; the sixth failed the same way). A
  Home route that doesn't go through Device Hub would need CoreSimulator's
  private HID calls. A fourth try, pressing Device Hub's button again after
  a 3 s pause and waiting up to 12 s, failed the same way in 2 of 4 runs
  (34–36 s in all). Checking the simulator's pixels through `simctl io
  screenshot` as well as its elements through Device Hub didn't help
  either (1 of 5 runs failed): in every failure the simctl screenshot taken
  at the failure shows the app, up to 77 s after the first press, so Home
  never reached the simulator. (The runner's screen captured in the
  diagnostics shows the home screen, which first looked like Home arriving
  late; but that capture comes after the flow's teardown, whose `sim
  terminate` closes the app.) Home now presses at most twice (Device Hub's
  button, then Controls › Home) and fails, checking pixels and elements.
  Why Device Hub's Home doesn't reach the simulator on a loaded runner is
  still open ([#35](https://github.com/TheRogue76/macos-harness/issues/35)).
  Every failed run had a load average of about 100–300 while the flow ran;
  the job now waits, up to 5 minutes, for the 1-minute load to drop below
  twice the CPU count before running the flow, and logs it.

[^runs]: iOS CI failures, 9–14 October 2026
[^home]: iOS Home failure, run 38636205832
[^local]: Local check of the new CI order
