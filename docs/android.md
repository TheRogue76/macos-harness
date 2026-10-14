# Android emulators and phones

With the Android SDK installed (adb), every command that takes `-a` also takes
`android:<device>`: an adb serial, an emulator's name, a phone's model, or
`android:booted` for the only running device.

```bash
macos-harness android boot Pixel_9_Pro_XL
macos-harness android install booted app-debug.apk
macos-harness android launch booted com.example.app
macos-harness snapshot -a android:booted
macos-harness press -a android:booted --id sign_in
macos-harness type "ada@example.com" -a android:booted --into a12
macos-harness android button booted back
```

MCP agents use the same tools with `app="android:<device>"`, plus `android` for the device
itself.

## How it works

Everything goes through adb: nothing is installed on the device, no macOS permission is
involved, and your cursor never moves. The helper finds adb in `ANDROID_HOME`,
`ANDROID_SDK_ROOT` or `~/Library/Android/sdk`, then on Homebrew's path; it doesn't see
your shell's environment.

The tree comes from `uiautomator`: Android classes become the usual roles (`Button`,
`EditText` a text field, `Switch`, `SeekBar` a slider, `RecyclerView` a list), labels come
from the content description or the text, and identifiers are the resource ID's name
(`sign_in` for `com.example:id/sign_in`). Coordinates are the screen's pixels.

| You ask for | On Android |
|---|---|
| `press`, `select`, `focus`, `click` | A tap |
| `set-value` | Text fields: tap, select all, delete, type. Switches and checkboxes: tap if needed |
| `type` | Plain ASCII text, typed into the focused field |
| `key` | Android key codes: `enter`, `back`, `ctrl+a`, or any `KEYCODE_…` |
| `long-press`, `swipe`, `scroll`, `drag` | Swipes and drag-and-drop through `input` |
| `increment`, `decrement`, `hover`, right-click | Not available (a right-click becomes a long press) |

A selector that matches nothing swipes the screen's main scrolling list down, then up,
looking for it.

## The `android` command

`android list|boot|shutdown|install|uninstall|launch|terminate|open-url|button|permission|location|appearance|rotate|status-bar`
(MCP: `android` with an `action`). `boot` starts an emulator (`--headless` for no window)
and waits until it has booted; phones are never started or stopped. `location` works on
emulators only. Creating, wiping and deleting emulators stays with you.

Screenshots and recordings come from the device (`screencap`, `screenrecord`, three
minutes at most).

## Speed

Each read of the screen takes 2–3 s, so a tap takes about 5 s end to end and scrolling to
a far element 20–30 s. Prefer one `snapshot` and several actions by ref over a snapshot
per step.

More: [Android targets](../knowledge/design/android.md) and
[known limitations](limitations.md#android).
