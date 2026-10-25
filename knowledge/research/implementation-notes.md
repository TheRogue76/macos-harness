---
type: Platform Constraint
title: Platform quirks the code works around
description: macOS, AppKit, accessibility and Swift behaviours that shaped the code but aren't visible in it, collected when code comments were removed.
tags: [macos, accessibility, appkit, swift, gotchas]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-06T19:30:00Z }
stale_after: 2027-10-06T00:00:00Z
---

The code carries no explanatory comments (see AGENTS.md), so the reasons
behind its less obvious choices live here. Behaviour found during
acceptance runs is in the [M1](/research/m1-acceptance.md),
[M2](/research/m2-acceptance.md) and [M3](/research/m3-acceptance.md) write-ups.

# Accessibility

- **Attribute names are string literals.** The `CFSTR` constants
  (`kAXTitleAttribute` and friends) don't import cleanly under Swift 6
  strict concurrency, so `AX` spells names out (`"AXTitle"`).
- **Batched reads report missing attributes as errors, not nil.**
  `AXUIElementCopyMultipleAttributeValues` returns an `AXValue` of type
  `.axError` for each attribute an element lacks; `AXReader` treats those as
  absent.
- **Window IDs need a private call.** `_AXUIElementGetWindow` (private, but
  stable for years) maps an AX window to its `CGWindowID`. Matching by frame
  and title instead fails for identical windows. An ID of 0 means it isn't a
  real window (Finder's desktop is one).
- **`AXSelectedText` insertion can land late.** Some apps apply it a beat
  after the call returns, so `type` polls the value (5 × 40 ms) before
  falling back to key events; otherwise the text would be typed twice.
- **An app pressing its own controls through AX runs their handlers on
  the calling thread.** The helper pressing its own status item ran the
  `@MainActor` toggle off the main thread and crashed (Swift's isolation
  check traps), so actions refuse the helper's own windows and extra.
- **macOS 27 moves the system's menu bar extras to MenuBarAgent.** Each
  `AXMenuBarItem` sits inside an `AXGroup` (a SwiftUI hosting view) in its
  `AXExtrasMenuBar`, and their panels are layer-101 windows of Control
  Center (Notification Center for the clock), listed by AX as `AXWindow`
  with subrole `AXSystemDialog` only when the extra was pressed with
  `AXPress`, not `AXShowMenu`.
- **Some windows don't support `AXRaise`.** Calculator's SwiftUI window
  on macOS 27.2 answers it with -25205 (`kAXErrorAttributeUnsupported`)
  even though making the app frontmost brings it forward, so `window
  activate` falls back to setting `AXMain` and `AXFocused` and checks the
  app's focused window rather than failing.
- **Background clicks need the point inside the window.** Events posted with
  `SLEventPostToPid` reach SwiftUI and Chrome only when
  `CGEventSetWindowLocation` gets the window-relative point; the screen point
  does nothing on macOS 27.2. Wheel events reach AppKit only when also posted
  with the public `CGEvent.postToPid`. Making a window key without raising it
  redraws its title bar, so the background route compares pictures taken
  after that, or every click would look like it changed something. These
  events don't reset the system's idle counters (`leftMouseDown` stayed
  idle after one), so they aren't mistaken for the user's input. See
  [S9](/research/s9-background-clicks.md).
- **Menu shortcuts for special keys** arrive as private-use characters
  (U+F700–F72D: arrows, home, end, page up and down, forward delete) or
  control characters (return, escape, tab, delete), which `MenuService`
  maps to their symbols.

# AppKit and processes

- **A child started with Foundation's `Process` is a background job.** It
  gets a process group of its own, so if it inherits the terminal as stdin
  and touches it, the kernel stops it (SIGTTIN or SIGTTOU, state `T` in
  `ps`) and whoever waits for it waits forever. `setup claude` hung that way
  on `claude mcp add`, which works when typed in a shell because it's then
  in the foreground. Children get `/dev/null` as stdin (`CommandRunner`,
  flow `shell` steps, `build`'s tools) and `setup`'s a time limit too
  ([#52](https://github.com/TheRogue76/macos-harness/issues/52)).
- **A locked screen hides every app window.** Accessibility lists no
  windows, launched apps never show one, and the lock screen's password
  field turns Secure Input on. `CGSessionCopyCurrentDictionary()` says so
  (`CGSSessionScreenIsLocked`; `kCGSessionOnConsoleKey` false after a
  switch to another user), so window lookups, real input and `doctor` say
  the screen is locked instead of that the app has no windows, and `launch`
  stops waiting for a window.
- **Light mode for one app on a dark system:** the launch arguments
  `-AppleInterfaceStyle Light` change nothing (TextEdit stayed dark);
  `-NSRequiresAquaSystemAppearance YES` makes it light, for AppKit and
  SwiftUI apps alike. Dark is `-AppleInterfaceStyle Dark` (with
  `-NSRequiresAquaSystemAppearance NO` for apps that opt out of dark
  mode); not checked on a light system. `-AppleLanguages (fr)` gave
  TextEdit French menus.
- `NSWorkspace.openApplication` right after the same app quit (a flow's
  teardown quits it, the next flow's setup launches it) can hand back the
  old process, which is gone a moment later; seen once on GitHub's Intel
  macOS 26 runner. `launch` tries again, up to three times, half a second
  apart, when the process it got back has already ended.
- **`NSRunningApplication.isActive` is false for every app** when read
  inside an accessory (menu bar) app like the helper.
  `NSWorkspace.frontmostApplication` is reliable.
- **`apps` always lists the frontmost app**, even a background-only
  process: one showing a system dialog is often what's frontmost.
- **Window counts don't need Screen Recording.** The window list hides
  titles without it, but not owners or bounds. Windows under 50 pt on a side
  are invisible helper windows and aren't counted.
- **`$HOME` can't be trusted.** Agent sandboxes sometimes override it, so the
  harness reads the home directory from the user database.
- **Unix socket paths are limited to 104 bytes**, so a very long home
  directory moves the socket to a per-user directory under `/tmp`.
- **A leftover socket file** from a crashed helper is removed at start; one
  that still accepts connections means another helper is running.
- **The helper answers a connection's requests one at a time, in order.**
  When the client stops waiting for a reply, the helper still finishes
  that request, and its reply arrives before the next one's. The client
  remembers the requests it gave up on and skips their replies instead of
  failing the next request; see [S7](/research/s7-simulator-window.md).
- **Install replaces app bundles whole.** Overwriting a signed binary in
  place can leave macOS with a stale code signature for the file, and the
  new binary gets killed at launch.
- **Key codes used to follow the US ANSI layout.** Since
  [#15](https://github.com/TheRogue76/macos-harness/issues/15) `key` finds
  printable keys through the current layout; see Keyboard layouts below.
- **Real scrolling goes in steps of about 40 px**, 16 ms apart, so apps
  animate as they would for a trackpad instead of jumping.
- **The cursor can jump back to where it rested in the middle of a step.**
  On GitHub's runners, starting a drag-and-drop session put the cursor
  back where it sat before the step's posted events (where the last warp
  left it), and the drag stopped as if the user had moved the mouse. The
  idle counters can't tell during a gesture, since our own events reset
  them every 16 ms, so the cursor check only blames the user for a place
  that no posted event, no lag behind them and no such return explains;
  see [the analysis](/research/ci-drag-stops.md).
- **Replies don't wait for on-screen feedback.** The router answered only
  after its observer had recorded the activity, which on the main thread
  also drew the window marker, ripple and driving panel. On CI's slow VMs
  that added up to 3 s to a request, and the iOS flow's slow simulator
  steps started passing the client's timeouts. The journal entry and claim
  renewal still happen before the reply; the activity log and overlays
  follow it.
- **Touching the menu bar icon closes other apps' open menus.** Setting
  the attention dot's `isHidden` on every activity update, even to the
  value it already had, made the menu bar redraw, and a right-click's
  context menu in another app closed within 5 s, before an agent could
  choose from it. The dot is set only when it changes.
- **An overlay that joins all Spaces shows on every Space.** The old window
  outline was a floating panel with `canJoinAllSpaces`, so it was drawn over
  a full-screen app (or whatever was in front) even when the agent's window
  was behind it or on another desktop. The marker now sits at the normal
  level instead.
- **`NSWindow.order(.above, relativeTo:)` works with another app's window
  number** at the same level: the marker lands directly above the agent's
  window in the window server's list, under anything in front of it. When
  that window isn't on the current Space, the order goes to the top instead,
  so the marker checks first.
- **Only the window server's on-screen list knows the current Space.**
  `CGWindowListCopyWindowInfo(.optionOnScreenOnly)` leaves out windows that
  are minimized, hidden or on another Space; ScreenCaptureKit's `isOnScreen`
  reported a window on another desktop as on screen.
- **Borderless panels are pushed below the menu bar.** AppKit's
  `constrainFrameRect` moved the marker 36 pt down for a window at the top
  of the screen, so overlay panels return the frame unchanged.
- **Window corners on macOS 27 measure about 16 pt** (TextEdit, Finder and a
  SwiftUI window all fit 16.5 pt); the marker measures each window from a
  capture of its top-left corner without the shadow.

# Keyboard layouts

How `key` maps combinations is in [actions](/design/actions.md); these are
the API facts behind it, checked on macOS 27 with the installed layouts
(the selected input source left alone).

- **Apps recompute a key event's characters.** A `CGEvent` made from a key
  code gets a Unicode string at creation, but `NSEvent(cgEvent:)` ignores
  it unless it was set with `keyboardSetUnicodeString`: key 18 with Shift
  set afterwards reads "!" in `characters` while the event's own string is
  "1". So background and real key events must carry the key code the
  receiving app's layout puts the character on, and typed text, which sets
  its string, doesn't depend on the layout.
- **`charactersIgnoringModifiers` drops ⌘ but `characters` doesn't.** For
  ⌘⇧ and key 18 on US, `characters` is "1" (the layout's ⌘⇧ layer) and
  `charactersIgnoringModifiers` is "!".
- **Layouts have their own ⌘ layer.** Dvorak – QWERTY ⌘, Russian and Greek
  type QWERTY letters with ⌘ held (⌘ plus key 6 types z), so combinations
  with ⌘ search that layer (`UCKeyTranslate` with `cmdKey >> 8`) before the
  plain one. US's ⌘⇧ layer keeps unshifted characters ("1", "z"), and
  French AZERTY needs Shift for digits even with ⌘.
- **`kUCKeyTranslateNoDeadKeysBit` is a bit number, not a mask.** Passing
  it as the options (0) leaves dead keys on, and a dead key then types
  nothing; pass `kUCKeyTranslateNoDeadKeysMask` to get its accent instead
  (German ^ and ´).
- **The keyboard type moves keys.** `UCKeyTranslate` takes the physical
  keyboard type (`LMGetKbdType()`; this Mac's built-in keyboard reports 92,
  ISO), and ISO keyboards swap what keys 10 and 50 type. The table is
  cached per input source and keyboard type; tests pass 40 (ANSI) so they
  don't depend on the Mac.
- **Text Input Sources calls belong on the main thread.** The header says
  the API isn't thread safe and UI apps must call it there, so
  `KeyLayout.current()` and `installed(_:keyboardType:)` are `@MainActor`
  (a quick off-main call in a command-line tool didn't crash, but the
  helper is a UI app).
- **`TISCopyCurrentKeyboardLayoutInputSource`** gives the layout an input
  method types with, so Japanese or Chinese input still has a table.
  `TISCreateInputSourceList` with `includeAllInstalled` finds layouts the
  user hasn't turned on, which is how the tests load German, French,
  Dvorak and Russian without touching the user's settings.
- **Not verified on a real non-US layout:** that every app takes ⌘⇧ plus
  the &/1 key as ⌘1 on AZERTY, and how apps with "Automatically switch to
  a document's input source" on pick the layout; switching layouts wasn't
  allowed while another session used the Mac.

# Apps and environments

- **SwiftUI scroll areas expose no scroll bars and no `AXScrollToVisible`**
  on their content, so only the real wheel scrolls them.
- **GitHub's macOS runners have a small screen** (the fixture's lower half
  sat under the Dock and past the bottom edge); CI hides the Dock.
- **A server on 127.0.0.1 still triggers the local network prompt** for
  Python, and the prompt blocks real input until answered.
- **Messages and FaceTime ignore a quit request at their sign-in screens.**
- **CEF apps (Spotify) ignore `AXManualAccessibility` and
  `AXEnhancedUserInterface`**; only `--force-renderer-accessibility` at
  launch builds their tree. Electron apps honor `AXManualAccessibility`.
- **Chromium trees reach some elements by two paths**, so searches and
  snapshots de-duplicate by element identity.
- **Device Hub's bridged iOS tree** reports positions in only the newest
  view showing a simulator, serves only simulators that were running when
  Device Hub started, and lags the screen by seconds; quitting Device Hub
  shuts its simulators down. Target resolution, `sim boot` and the waits
  around simulator actions are shaped by this; see
  [S7](/research/s7-simulator-window.md).
- **Android list rows are recycled**, so an Android element's identity
  includes its text as well as its place and resource ID; see
  [Android targets](/design/android.md).
- **`wm size` doesn't follow rotation**; the Android screen size comes from
  `dumpsys window displays` (`cur=`).
- **Emulators are started through `/bin/sh` with `nohup … &`** so they
  outlive the helper that started them.
- **LaunchServices can list Device Hub with process ID -1** (Xcode 27.0),
  even as the frontmost app, so the harness finds its process by
  executable path and maps that entry to it in frontmost checks.
- **Key events reach a simulator only after a real click on its screen**,
  and by key code alone, so simulator typing sets AX values and key codes
  follow a US map.
- **Opening an app can never complete** (a second Chrome on GitHub's
  runner); `launch` waits for the system with a deadline from a main-actor
  task, because the launch configuration can't leave the main actor.
- **Each Claude Code session is its own process.** The Claude desktop app
  starts a `claude` process per Code session with the session's folder (a
  worktree for most) as its working directory, read with `proc_pidinfo`
  and `PROC_PIDVNODEPATHINFO`; every session shares one signing identity,
  so only the process tells them apart.
- **Test apps started from an agent's shell need a bundle.** LaunchServices
  credits an unbundled GUI process started by Claude Code to Claude.app, so
  it shows up under Claude's name; wrapping it in a minimal `.app` and
  starting it with `open` gives it its own name.

# Swift

- **Swift 6.2 wants `SendableMetatype` spelled out** when handlers capture a
  method's metatype in `@Sendable` closures; `RPCMethodBase` adopts it under
  `#if compiler(>=6.2)`.
- **Connection threads block, concurrency threads don't.** Each socket
  connection has its own thread, which waits on a semaphore while the
  handler runs in a `Task`. Blocking a Swift concurrency thread that way
  could starve the pool.
- **Tests must not block on sockets from async code.** A blocking client
  call inside an async test holds a concurrency thread; on a small CI runner
  the server's handlers then have none left and every call times out. The
  server tests run their clients on plain threads. Locally,
  `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test` (a one-thread pool)
  reproduces the starvation; on CI's Swift 6.0 that setting hangs the whole
  test run, so CI doesn't use it.
- **CI's compiler is older than a local one.** 1.x built with Xcode 16
  (Swift 6.0, macOS 15 SDK). Since the Linux work (October 2026) the tools version is 6.2 and
  code uses the `unsafe` keyword, so the macOS 15 jobs select the runner's
  newest Xcode 26; the macOS 26 runners use Xcode 26.6 (Swift 6.3), still
  older than a local Swift 6.4. An older compiler times out on long `??`
  chains and ternaries the newer one handles, and Xcode 16's SDK lacked Sendable annotations on ScreenCaptureKit
  types (hence `@preconcurrency import` in the thumbnailer) and treats more
  AppKit properties as main-actor only (`NSWindow.windowNumber`). A local
  Xcode 27 build passes either way, so find the risky expressions before
  pushing with `swift build --scratch-path .build/slowcheck -Xswiftc
  -Xfrontend -Xswiftc -warn-long-expression-type-checking=25`: anything it
  flags (a big array literal of tool definitions at 50 ms, an activity
  summary built from four `??` and a `.map`) is worth splitting. In October
  2026 such a summary failed CI on macOS 15 for six commits in a row before
  anyone looked, so check CI after every push.
- **`objectWillChange` fires before the new values land**, so the menu bar
  controller re-lays out on the next main-queue turn rather than
  immediately.

# Linux

- **Foundation's `Process` reports an exit late.** On Linux it learns that
  a child exited through a socket the child inherits, so the termination
  handler and `isRunning` wait until every program the child left running
  in the background has exited too, even when the output goes to a file.
  `CommandRunner` instead watches `/proc/<pid>/stat`: an exited, unreaped
  child is in state `Z`, and field 52 holds its raw wait status. The last
  field ends in a newline, so split on whitespace.
- **Swift's Glibc module has no `ucred`.** It's declared only under
  `_GNU_SOURCE`, which the module isn't built with, though `SO_PEERCRED` is
  there. `LinuxProcesses` reads the peer's credentials into three `Int32`s
  (pid, uid, gid), the same layout.
- **`/proc/<pid>/stat`'s command name can contain spaces and parentheses**,
  so fields are counted from the last `)`. `/proc/<pid>/exe` and `cwd` are
  unreadable for other users' processes, so their absence is normal, not an
  error.
- **Glibc differs from Darwin in small ways.** `SOCK_STREAM` is an enum
  (`Int32(SOCK_STREAM.rawValue)`), `timeval.tv_usec` is `Int`, there is no
  `SO_NOSIGPIPE` (send with `MSG_NOSIGNAL`), `stdout` is a mutable global
  that Swift 6 refuses to read (flush with `fflush(nil)`), and
  `FileManager.createFile` isn't `@discardableResult`.
- **Swift on Fedora and Arch comes from swiftly's RHEL 9 build.** swiftly
  refuses distros it doesn't know (Fedora after 39, Arch) unless given
  `--platform ubi9`. It then exits with an error over RHEL packages it can't
  find, even after installing, unless `--post-install-file` takes the
  dependency script. Arch needs `libxml2-legacy` for `libxml2.so.2`, and
  `libncurses.so.6` linked to `libncursesw.so.6` (it has `libtinfo.so.6`). In a
  CI container, set `SWIFTLY_HOME_DIR`, because swiftly installs under the
  account's home while `$HOME` points elsewhere.
- **Apple's SDK marks C-variadic APIs unsafe, Linux's Foundation doesn't.**
  `String(format:)` builds clean under strict memory safety on Linux and
  fails on macOS, so a Linux build doesn't prove the portable code is clean.
  Shared code formats decimals with `Double.fixed(_:)` instead.
- **Where `unsafe` goes depends on the compiler.** Swift 6.2 and 6.3 count
  `withUnsafePointer(to:)`, `withUnsafeBytes(of:)` and
  `withUnsafeMutableBytes(of:)` as unsafe; Swift 6.4 doesn't, and warns that
  a marker on them is unnecessary. CI runs all three (6.2 and 6.3 on macOS,
  6.4 on Linux and the iOS runner), so no placement of the marker satisfies
  them all. Code that needs memory of a C struct instead allocates an
  `UnsafeMutablePointer`, initializes it and works through it
  (`LineSocket`), which every version rates the same way, and needs no
  `allocate` marker. A value derived from an unsafe buffer
  (`$0.prefix { … }`) needs the marker on the expression that consumes it
  (`unsafe String(decoding: …)`). To check older compilers on Linux, run
  swift.org's Ubuntu 24.04 tarballs from a scratch folder; on Ubuntu 26.04
  they need `libxml2.so.2` pointed at `libxml2.so.16` through
  `LD_LIBRARY_PATH`.
