---
type: Analysis
title: "S8: operating Android through adb alone"
description: On an Android 16 emulator, `uiautomator dump` gives a usable tree (text, descriptions, resource IDs, bounds, state) in 2–3 s per read, `input` taps, swipes and types ASCII in a tenth of a second to half a second, `screencap` and `screenrecord` work, and nothing needs installing; non-ASCII text can't be typed, and GitHub's Apple-silicon runners can't run the emulator.
tags: [spike, m9, android, adb, uiautomator, emulator, ci]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-09T19:00:00Z }
verified: { by: claude-code/claude-opus-5-5, at: 2026-10-09T19:00:00Z }
stale_after: 2027-04-09T00:00:00Z
sources:
  - id: probe
    resource: "adb 37.0.1 and emulator 37.2.5 against an emulator made from system-images;android-36;google_apis_playstore;arm64-v8a (Pixel 8 profile, 1080 × 2400 px, 420 dpi) on macOS 27.2, 2026-10-09"
    title: adb probe
    author: claude-code/claude-opus-5-5
  - id: github-runners
    resource: https://docs.github.com/en/actions/reference/runners/github-hosted-runners
    title: Supported runners and hardware resources
    author: GitHub
  - id: emulator-runner
    resource: https://github.com/ReactiveCircus/android-emulator-runner
    title: android-emulator-runner
---

# Question

Can the harness see and operate Android emulators and phones with adb and
the tools Android already ships, installing nothing on the device, as the
owner chose for M9?

Yes, with two limits: reading the tree is slow, and only ASCII can be
typed.[^probe]

# Findings

| Task | How | Measured |
|---|---|---|
| Boot an emulator | `emulator -avd <name> -no-window`, then poll `getprop sys.boot_completed` | 26–31 s, no window needed |
| Read the screen | `adb exec-out uiautomator dump /dev/tty` (XML on stdout) | 2.2–3.3 s per read; `--compressed` no faster |
| Tap, long press, swipe | `input tap x y`, `input swipe x1 y1 x2 y2 ms` | 0.1–0.4 s |
| Keys | `input keyevent KEYCODE_…`, `input keycombination` | 0.1 s |
| Type | `input text` (spaces as `%s`) | ASCII only: "café" throws an exception |
| Clear a field | `keycombination KEYCODE_CTRL_LEFT KEYCODE_A`, then `KEYCODE_DEL` | Works |
| Screenshot | `adb exec-out screencap -p` | 1 s, 1080 × 2400 px |
| Record | `screenrecord --time-limit N /sdcard/x.mp4`, then `adb pull` | Works |
| Start apps, deep links | `am start` | 0.1 s |

- **The tree** names elements well: `text`, `content-desc`,
  `resource-id`, class, `bounds` in pixels, and `clickable`,
  `long-clickable`, `scrollable`, `checkable`, `checked`, `enabled`,
  `focused`, `selected`, `password`. The launcher's icons, Settings'
  search bar and its `EditText` all came through with IDs.
- **An empty text field reports its hint as its text** (`text` equals
  `hint`), like iOS placeholders.
- **`uiautomator dump` waits for the screen to settle**: a dump started
  during a swipe animation returned normally.
- **There's no shell command for the clipboard** (`cmd clipboard` doesn't
  exist), so non-ASCII text has no path without an app on the device.
- **Nothing touches the Mac:** input is injected into the device, so the
  cursor never moves, no macOS permission is involved, and the emulator can
  run without a window.

# CI

GitHub's arm64 macOS runners don't support nested
virtualization,[^github-runners] which hardware-accelerated emulators
need;[^emulator-runner] Linux runners can run them, but the harness is
macOS-only. Android flows therefore run on a developer's Mac; CI covers
parsing and unit tests.

[^probe]: adb probe
[^github-runners]: Supported runners and hardware resources
[^emulator-runner]: android-emulator-runner
