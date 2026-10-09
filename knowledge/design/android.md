---
type: Design
title: Android targets
description: How `android:<device>` targets work through adb alone (uiautomator dumps for the tree, `input` for taps, swipes, text and keys, screen pixels as coordinates), how refs survive recycled list rows, the `android` command, recording, the fixture app built without Gradle, flows, policy and what's slow.
tags: [design, m9, android, adb, emulator, flows]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-09T21:30:00Z }
sources:
  - id: roadmap
    resource: /plan/roadmap.md
    title: Roadmap, M9 decisions
  - id: s8
    resource: /research/s8-android-adb.md
    title: "S8: operating Android through adb alone"
  - id: acceptance
    resource: /research/m9-acceptance.md
    title: M9 acceptance run
---

# Targets

Any command that takes `-a`/`app` takes `android:<device>`: an adb serial
(`emulator-5554`, a phone's serial), an emulator's name, a phone's model, or
`android:booted` for the only running device. `snapshot`, `find`
(including `--ocr`), `screenshot`, `press`, `set-value`, `type`, `key`,
`focus`, `select`, `scroll-to`, the pointer commands (`click`, `long-press`,
`swipe`, `drag`, `scroll`), `wait`, `windows` and `record` work on it.
`menu`, `menu-select`, `window`, `launch` and `quit` don't; `android launch`
and `android terminate` handle apps.[^roadmap]

Everything goes through adb, which the helper finds in `ANDROID_HOME`,
`ANDROID_SDK_ROOT` or `~/Library/Android/sdk` (the helper doesn't get the
user's shell environment), then on Homebrew's path.[^s8] Nothing is
installed on the device, no macOS permission is involved, and the Mac's
cursor never moves: input is injected into the device.

# The tree

`adb exec-out uiautomator dump /dev/tty` gives the screen as XML. Classes
become the roles used everywhere else (`Button` a button, `EditText` a text
field, `Switch` a switch, `SeekBar` a slider, `ScrollView` a scroll area,
`RecyclerView` a list), clickable text a button. Labels come from
`content-desc`, then `text`; an empty field's `text` (equal to its `hint`)
isn't shown as a value. Identifiers are the resource ID's name
(`tap_button` for `io.example:id/tap_button`); plain layout containers lose
theirs so they collapse. Actions are `press`, `long-press` and `scroll`.
Coordinates are the screen's pixels, the same as `screencap` and `input`,
read with the current orientation from `dumpsys window displays`.

Refs need an identity that holds from one dump to the next. A node is
known by its place (child indexes), class, resource ID and text: lists
recycle their rows, so the same place with other text is another element.
A ref whose text changed (a counter) is found again by its resource ID only
when exactly one node has it. The change list pairs a removed and an added
element into `~ old → new` only by identifiers unique on both sides.

# Acting

| Agent asks for | On Android |
|---|---|
| `press`, `select`, `focus` | `input tap` at the element's center |
| `set-value` | Text field: tap, select all, delete, type. Switch or checkbox: tap if it's not already in that state |
| `type` | Tap the field unless focused, then `input text` in runs (spaces as `%s`, Enter and Tab as key events); ASCII only |
| `key` | `input keyevent` or `input keycombination` with Android key codes (`enter`, `back`, `ctrl+a`, or any `KEYCODE_…`) |
| `click`, `long-press`, `swipe`, `scroll`, `drag` | `input tap`, a still `input swipe` held for the press, a moving `input swipe`, `input draganddrop` |
| `increment`, `decrement`, `hover`, right-click | Not available (a right-click becomes a long press) |

Elements a selector can't find are looked for by swiping the screen's
largest scrollable element down, then up, until the screen stops changing;
elements found but under the bars are swiped into reach first.

Every read takes 2–3 s, so an action reads once to find its target (that
read is also the "before" for the change list) and once after.[^s8] A tap
takes about 5 s end to end, a scroll to a far element 20–30 s.

# The `android` command

`android list|boot|shutdown|install|uninstall|launch|terminate|open-url|button|permission|location|appearance|rotate|status-bar`
(MCP: `android` with an `action`).

- `boot` starts an emulator (`--headless` without a window) detached from
  the helper, then waits for `sys.boot_completed`; `shutdown` uses `adb emu
  kill`. Phones are never started or stopped. Creating, wiping and deleting
  emulators stays with the user.[^roadmap]
- `launch` resolves the launcher activity and starts it fresh (`am start
  -S`); `permission reset` revokes each granted runtime permission of that
  one app (`pm reset-permissions` would reset every app).
- `location` works on emulators only (`adb emu geo fix`); `status-bar` uses
  System UI's demo mode.

`record` runs `screenrecord` on the device (three minutes at most) and copies
the file back when it stops. Screenshots are `screencap`.

# Fixture and flows

`fixtures/android` is a plain-Java app with one of each control and a
resource ID on each. `scripts/build-android-fixture.sh` builds it in about
4 s with the SDK's `aapt2`, `javac`, `d8`, `zipalign` and `apksigner`: no
Gradle and no network. `flows/android/fixture.yaml` builds, installs and
runs it, with `android:` steps for the lifecycle (`device` defaults to the
flow's `android:` target). GitHub's Apple-silicon runners can't run the
emulator, so Android flows run on a developer's Mac; CI parses them and runs
the unit tests.[^s8]

# Policy and journal

The policy names every Android device `Android`, and `blocked` entries also
match a package name in `android` calls. `android list` counts as reading.
The journal records the `android:` target.

[^roadmap]: Roadmap, M9 decisions
[^s8]: S8: operating Android through adb alone
