---
type: Platform Constraint
title: What a fresh Play Store test emulator needs before flows/android passes
description: A new emulator from the Play Store image can ask to allow USB debugging, which `-skip-adb-auth` avoids, and Gboard with stylus handwriting on can take every tap while the keyboard shows, which turning stylus handwriting off fixes.
tags: [android, emulator, adb, gboard, testing, validation]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-25T14:10:00Z }
verified: { by: claude-code/claude-opus-5-5, at: 2026-10-25T14:10:00Z }
stale_after: 2027-04-25T00:00:00Z
sources:
  - id: validation
    resource: "1.0.0 validation on an emulator made with `avdmanager create avd -n macos_harness_tests -d pixel_8` from system-images;android-36;google_apis_playstore;arm64-v8a, Gboard 15.1.08 (preloaded), macOS 27.2, 2026-10-25"
    title: 1.0.0 local validation
    author: claude-code/claude-opus-5-5
---

# Allow USB debugging

On 25 October 2026 the new emulator showed "Allow USB debugging?" at boot
and stayed `unauthorized` to adb, so `android boot` timed out after five
minutes. Earlier emulators made the same way had trusted
`~/.android/adbkey` on their own.[^validation] Agents don't answer that
prompt. Stop the emulator with `adb -s emulator-5554 emu kill` (the console
works without authorization) and start it with `emulator -avd
macos_harness_tests -skip-adb-auth -no-snapshot-save`, then wait for
`getprop sys.boot_completed` to be 1. The first boot took about four minutes.

# Gboard taking every tap

The first time the keyboard opened, Gboard showed a "Try out your stylus"
tutorial over the app. Dismissing it didn't help: while the keyboard
showed, Gboard's `InputMethod` window kept the whole screen as its touchable
region (`dumpsys input`: `touchableRegion=[0,63][1080,2400]`), so taps
outside the keyboard never reached the app, and pressing GREET after typing
changed nothing. Restarting Gboard didn't help either. `adb shell settings
put secure stylus_handwriting_enabled 0` shrank the region to the keyboard
(`[0,1517][1080,2400]`), and `flows/android` passed.[^validation] The
harness doesn't detect this yet
([#54](https://github.com/TheRogue76/macos-harness/issues/54)).

[^validation]: 1.0.0 local validation
