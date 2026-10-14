# iOS Simulators

With Xcode 27 or later, every command that takes `-a` also takes `sim:<device>`: a UDID, a
name, or `sim:booted` for the only booted simulator.

```bash
macos-harness sim boot "iPhone 18 Pro"
macos-harness build --device booted --run
macos-harness snapshot -a sim:booted
macos-harness press -a sim:booted --text "Sign in"
macos-harness type "ada@example.com" -a sim:booted --into s12
macos-harness swipe -a sim:booted --up 400
macos-harness sim button booted home
```

MCP agents use the same tools with `app="sim:<device>"`, plus `simulator` for the device
itself and `build`/`build_status` for builds.

## How it works

The simulator's screen is reached through Device Hub, Xcode's simulator window, which
passes the iOS accessibility tree to macOS. Trees, hit points, `--x/--y`, screenshots and
grids are in the device's own points, top-left at 0,0, whatever Device Hub's zoom.

| You ask for | On a simulator |
|---|---|
| `press`, `select`, `increment`, `decrement`, `set-value`, `type` | Accessibility, in the background |
| `key` | The on-screen keyboard's key when it shows one; otherwise a tap on the field, then the key |
| `scroll`, `scroll-to` | Accessibility scrolling, a page at a time |
| `click`, `long-press`, `swipe`, `drag` | The real mouse in Device Hub's window |
| `sim button home`, `rotate-left/right` | Device Hub's own buttons |
| `sim button lock`, `siri`, `app-switcher`, `action` | Device Hub's Controls menu, which brings it to the front |

iOS lists only what's on screen, so a selector that matches nothing pages through the
screen's main list looking for it, for up to 35 s. The bridged tree lags the screen by
1–4 s, so actions wait for it.

Screenshots and recordings come straight from the simulator (`simctl`), with no window
around them and no Screen Recording permission needed.

## The `sim` command

`sim list|boot|shutdown|install|uninstall|launch|terminate|open-url|button|privacy|push|location|appearance|status-bar|pasteboard`
(MCP: `simulator` with an `action`). For example, `sim status-bar booted --time 9:41
--battery 100` gives clean screenshots, and `sim privacy booted grant photos <bundle-id>`
skips a permission prompt. Creating, erasing and deleting simulators stays with you
(`xcrun simctl`).

## Building

`build` finds the `.xcworkspace` or `.xcodeproj` in the current folder (or `--project`,
`--workspace`, `--scheme`), builds it for the simulator with `xcodebuild`, and reports
errors and the built app. `--device booted --run` installs and launches it afterwards. The
full log goes to `~/Library/Logs/macos-harness/builds`. Over MCP, `build` returns an ID at
once (builds outlast tool timeouts) and `build_status` reports progress and the result;
`run=true` installs and launches it.

## Device Hub

- Device Hub only sees the screens of simulators that were already running when it
  started. Boot with `macos-harness sim boot`, which boots first and opens Device Hub
  after; a simulator booted while Device Hub was open may have no elements until Device Hub
  restarts.
- Quitting Device Hub shuts down every simulator it shows, so the harness never quits it
  while a simulator runs, and you shouldn't either while an agent is working.
- The harness works in a Device Hub window of its own when it needs one and leaves yours
  alone.

More: [iOS Simulator targets](../knowledge/design/ios-simulator.md) and
[known limitations](limitations.md#ios-simulators).
