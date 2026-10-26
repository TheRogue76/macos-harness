---
type: Plan
title: Linux support
description: Decisions, architecture seams and stacked milestones for adding GNOME, KDE and wlroots Wayland support in Swift without breaking macOS.
tags: [linux, wayland, plan, memory-safety, ci, packaging]
status: draft
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-25T15:45:00Z }
sources:
  - id: interview
    resource: Interview with the owner in a Claude Code session on the Linux desktop, 2026-10-25
    title: Linux kickoff interview
  - id: audit
    resource: /research/linux-port-audit.md
    title: Linux port audit
---

# Goal

Linux support adds Linux to macos-harness without breaking macOS: every CLI command
and MCP tool works on Linux, or says clearly why it can't on that
compositor.[^interview] Swift stays the repo's first language; C libraries
are reached through thin system-library targets, and the only non-Swift
code is a small GNOME Shell extension.

# Decisions from the interview

| Topic | Decision |
|---|---|
| Desktops | GNOME, KDE Plasma and wlroots (Sway, Hyprland), all Wayland. No X11 session support |
| Apps | GTK/GNOME, Qt/KDE, Electron/Chromium, and the Android emulator on Linux |
| Parity | Feature parity per command; unsupported cases return a structured error and show in `doctor` |
| GNOME window access | A minimal Shell extension (in-process access to Mutter, exposed over D-Bus, no logic) because Mutter keeps window data private. KDE and wlroots need no compositor code |
| GNOME input and capture | Portals first (RemoteDesktop plus libei, ScreenCast), Mutter's private D-Bus as fallback; `doctor` says which is in use |
| Input elsewhere | libei preferred, `/dev/uinput` as fallback |
| C interop | `.systemLibrary` targets with pkg-config, wrapped by safe Swift in per-backend targets |
| Memory safety | Strict memory safety on every target, warnings as errors in CI |
| Helper UI | Headless helper core first, then a GTK4/libadwaita Control Tower in Swift over our own thin GTK bindings; tray via StatusNotifierItem |
| Packaging | Homebrew on Linux, .deb and .rpm on GitHub Releases, tarball with an install script |
| Targets | x86_64 and arm64; Ubuntu, Fedora and Arch |
| Naming | Decide later; plan as if a rename can happen (one product-name constant, aliases kept) |
| Branches | One `linux/<step>` branch and PR per step, against `main`. Nothing merges without the owner's say-so and green CI. (Work began on a `2.0` integration branch with stacked PRs; it was merged into `main` on 2026-10-25 without a version bump and retired.) |

# Architecture

The audit[^audit] found HarnessCore mixes portable logic with macOS calls.
The work splits it:

- **`HarnessCore`** (portable): socket server, router, policy, journal,
  activity, pairing, agent classifier, tree shaping, search, settle diffing,
  input lease and turns, Android, and the backend protocols below.
- **`HarnessMac`**: today's AX, CGEvent, ScreenCaptureKit, SkyLight, Vision,
  Simulator and NSWorkspace code, moved without behaviour changes.
- **`HarnessLinux`**: AT-SPI, portals, compositor backends, xkbcommon,
  Tesseract, `/proc`.
- **`HarnessImaging`** (portable): an RGBA `Bitmap` with crop, resize, PNG
  encoding, pixel diff and label drawing, replacing `CGImage` in shared
  code. macOS may keep CG underneath.
- **`HarnessHelperCore`** (portable): helper models and handlers, with
  Combine replaced by Observation.
- **C shims**: `CAtspi`, `CDBus`, `CLibei`, `CPipeWire`, `CXkbcommon`,
  `CWayland`, `CTesseract`, `CGtk`, each a module map and nothing else.

Backend seams, each a protocol with one macOS and one Linux implementation:

| Seam | Covers |
|---|---|
| `AccessibilityBackend` | Opaque `Element` handle, read, actions, values, focus, scroll into view, element at point, liveness; its own status type in place of `AXError` |
| `WindowBackend` | List, frames, stacking, focus, activate, move, resize, minimize, fullscreen, close, screens; synthetic stable window ids on Wayland |
| `CaptureBackend`, `RecordingBackend` | Window and screen capture into `Bitmap`; recording to a file |
| `InputBackend` | Pointer, buttons, wheel, keys, text, cursor position, idle time, with a `Capabilities` struct the shared lease code checks |
| `KeyboardLayoutBackend`, `ClipboardBackend`, `OCRBackend` | TIS or xkbcommon, NSPasteboard or data-control or extension, Vision or Tesseract |
| `AppCatalog`, `SessionState`, `ProcessIntrospection` | Launch, quit, resolve apps; lock, permissions; peer identity |
| `StatusItemsBackend` | Menu bar extras or StatusNotifierItem plus DBusMenu |

On Linux the window backend has one implementation per compositor family:
GNOME (the extension), KDE (plasma window management and KWin D-Bus) and
wlroots (Sway and Hyprland IPC plus wlr protocols), picked at run time.

`hello` gains a capability list; the MCP server and CLI hide or refuse what
the current platform and compositor can't do. The wire format stays the same
for macOS clients.

# Memory safety

- Raise the tools version to 6.2 and add `.strictMemorySafety()` and
  `.treatAllWarnings(as: .error)` to every target.
- Unsafe code lives only in the C shim wrappers and the macOS private-API
  files (SkyLight, remote AX tokens, `@_silgen_name`), each behind `@safe`
  Swift APIs.
- Replace lock-guarded `@unchecked Sendable` classes with `Mutex`; use
  `Span`/`RawSpan` for socket and bitmap buffers; model C resources (D-Bus
  connections, PipeWire streams, libei devices) as `~Copyable` types.
- Add a Linux CI job with Address and Thread Sanitizer over the unit tests.
- Check first that CI's macos-15 runners have a toolchain that understands
  tools version 6.2; if not, select a newer Xcode there.

# Milestones (one or more stacked PRs each)

Sizes follow the roadmap's S, M, L, XL.

## L0: Plan and toolchain (S)

This plan, the audit and the Linux dev machine concept.

## L1: Portable foundations (M)

No behaviour change on macOS.
- Darwin/Glibc/Musl shim for sockets; `MSG_NOSIGNAL` for `SO_NOSIGPIPE`.
- XDG paths in `HarnessPaths` (runtime, state and config directories) and a
  `logsDirectory` that flow results and build logs share.
- One product-name constant, `HarnessProduct.commandName`.
- `Package.swift` builds only the portable targets (protocol, client, CLI
  and their tests) on Linux.
- Strict memory safety and warnings as errors on the portable targets. The
  macOS-only targets get them in L2, as their code moves into `HarnessMac`,
  so they can be fixed and checked file by file.
- Portable tests moved into a `HarnessClientTests` target.
- `record frames` says it needs macOS; `CommandRunner` copes with Linux's
  late process exits.
- CI: blocking `ubuntu-24.04` and `ubuntu-24.04-arm` jobs for build and
  test; build checks on RHEL UBI 10, Fedora and Arch containers; the macOS
  15 jobs move to Xcode 26.

Moved to L2 and L3, with the HarnessCore code they belong to: the logging
facade over `os.Logger`, and JSON settings and pairings under XDG.

Acceptance: `swift build && swift test` green on macOS and Linux, and the
macOS flows still pass.

## L2: Split HarnessCore behind the seams (L, several PRs)

1. **Module split (done first).** `Sources/HarnessCore` moved to
   `Sources/HarnessMac` with its history. Then the files that need no
   platform API moved back into a new, portable `HarnessCore`, along with
   the plain data types they needed:
   - **Data types:** `RawNode` (minus its `AXUIElement`, which HarnessMac
     now reads from the node's key), `CoordinateSpace`, `ProcessSnapshot`,
     the rectangle helpers and the interactive-role set.
   - **Files:** tree shaping and search, policy (with the Mac app lookup
     injected as `PolicyStore.mac()`), journal, pairing and settings
     stores, activity, router, window claims, adb and the tool runner.

   The core builds on Linux with strict memory safety. Its members that
   were implicitly `internal` are now `package`, keeping the visibility
   they had when everything was one module. Tests that use only the core
   run on Linux; the rest are in `HarnessMacTests` until their subjects
   move.
2. **Shared logic before seams.** Key chords (`KeyChord`, `KeyModifiers`;
   `KeyCombo` stays as their macOS key-code form) and the input lease,
   `ActionContext` and turns moved to the core, with their tests. Then the
   socket server, with a logging facade, and the first interface with both
   implementations: `ProcessIntrospection`, which identifies the agent behind
   a connection. It's `MacProcesses` over `ProcessInspector`, and
   `LinuxProcesses` in the new Linux-only `HarnessLinux` module, which uses
   `SO_PEERCRED` and `/proc`. Linux has no "responsible process", so that
   fallback answers nil there.

   Android's logic followed: the adb control, tree, input and service, plus
   the shared service layer they stand on (the element registry, now keyed
   without an `AXUIElement`; read and collect; settle's diff; action and
   pointer helpers). The Mac service enums are now extensions of core
   declarations that hold the pure parts. Screenshots and text recognition
   go through `ScreenImaging`, the second interface: `MacScreenImaging` uses
   Core Graphics and Vision, and the helper registers it at start. A Linux
   implementation and a headless Linux helper come next, in L3.

   The backend protocols (accessibility, windows, capture, input) are no
   longer designed ahead in L2. Each one arrives in L3–L5 together with its
   Linux implementation, and the macOS code moves behind it then.
   Designing them with only the macOS side to go on risked the wrong shape.
   `LaunchArguments` stays in HarnessMac for the same reason: its presets
   are macOS arguments that become environment variables on Linux.
3. **`HarnessImaging`** in place of `CGImage` in shared code.
4. **Capability gating** in `hello`, the MCP server and the CLI.
5. **Strict memory safety for `HarnessMac`**, and the logging facade.

This is the riskiest step for macOS. Each PR moves code without editing it
where it can, and runs the full macOS validation from the release process.

## L3: Headless Linux helper and Android (M)

- `HarnessHelperCore`.
- Peer identity from `SO_PEERPIDFD`/`SO_PEERCRED`, `/proc` and cgroup
  scopes, feeding the agent classifier and pairing.
- Helper discovery next to the CLI.
- A systemd user unit with socket activation.
- `doctor` on Linux.
- Android on Linux: SDK paths, `Bitmap` decoding, Tesseract OCR.

Acceptance: `flows/android` passes on Linux, and CI runs it on an Ubuntu
runner with KVM.

Progress:
- The helper's models moved to Observation and into a shared
  `HarnessHelperCore`, with a repo-wide ban on Combine-style observation.
- The headless Linux helper serves the socket, identifies callers through
  `LinuxProcesses`, and answers `doctor` with the session, desktop and
  distribution. It serves Android targets and refuses desktop ones.
- Until the GTK Control Tower exists, pairing asks through a desktop
  notification with Allow, This session and Deny buttons, sent over D-Bus
  (`notify-send` 0.8.8 drops the buttons on GNOME 50).
- The CLI finds the helper next to itself (or in `../libexec/macos-harness`),
  starts it with `setsid -f` and logs to the logs directory.
- adb is found on Linux too (`~/Android/Sdk`, `/usr/bin`, `PATH`).
- Linux `ScreenImaging`: `HarnessImaging` decodes, scales, crops and marks up
  screenshots in Swift (zlib is its only C), and text recognition runs the
  `tesseract` command (sparse-text mode, TSV output), grouping words into
  lines like Vision's results. Without Tesseract, `--ocr` says how to install
  it. `findText` became `async` so the process doesn't block a concurrency
  thread.
- CI runs `flows/android` on an Ubuntu 24.04 runner with KVM: an Android 35
  x86_64 emulator booted headless through the harness, driven by the Linux
  helper. It's non-blocking until it has proved steady.
- A systemd user socket and service (`packaging/linux/`) start the helper on
  the first connection. The helper adopts the socket systemd hands over
  (`LISTEN_FDS`) and leaves the socket file to systemd. The CLI connects to
  the socket even when it can't find the helper binary. Packages install the
  units in L7.

## L4: Seeing and element actions through AT-SPI (L)

- Spike first: libatspi against our own D-Bus client, measured on snapshot
  latency. Done ([S11](/research/s11-atspi-access.md)): one
  `Cache.GetItems` call plus pipelined `GetExtents` reads a whole tree with
  frames 8 to 20 times faster than libatspi's call per property, and fails
  fast on a hung app. So the helper talks D-Bus itself, through
  `HarnessDBus`: the wire protocol in Swift over the socket code, with no C
  library (the owner's choice over GDBus and sd-bus), which L5's portals,
  Mutter and KWin calls and the pairing notifications will use too.
- Frames are relative to the window: on Wayland, GTK 4 reports screen
  positions of 0,0. Placing them on the screen waits for L5.
- PRs, stacked: the D-Bus client; AT-SPI trees for `snapshot`, `find` and
  `read`; element actions; the GTK 4 fixture and `platform:` in flows;
  menus and menu extras.

Progress:
- `HarnessDBus`, the D-Bus client in Swift.
- `apps`, `windows`, `snapshot`, `find` and `read` on desktop apps
  (`LinuxDesktop`): apps are matched by pid, AT-SPI name, its last part or
  the executable; the window is the one named by `--window` (a hash of the
  app's bus name and the window's object path), else the active one. Trees
  come from the cache, or a pipelined walk for apps without one, keep only
  what's showing, and map onto AX roles. `since` and `query` moved to the
  core (`SnapshotNarrowing`), so Android targets on Linux have them too.
  Calculator's whole window reads in about 12 ms.
- Element actions through AT-SPI, with no mouse or keyboard: `press`
  (`DoAction`), `select` (the parent's `SelectChild`, else a press),
  `set-value` (`SetTextContents`, the `Value` property, or a press to flip a
  check box), `increment` and `decrement` (`Value` in steps of its minimum
  increment, else the element's increment actions), `scroll-to`
  (`ScrollTo`), `type` (`InsertText` at the caret) and `focus`; and `wait`.
  Each reports what changed, as on the other platforms. `key` and `paste`
  wait for real input in L5.
- `launch` and `quit`: an app is found by path, by a desktop entry's name or
  file ID (XDG and Flatpak folders), or as a program named like it beside
  the helper or on PATH, then started with `posix_spawn` and quit with
  SIGTERM (SIGKILL with `--force`).
- The GTK 4 fixture (`fixtures/linux`, its own package so the main one
  doesn't need GTK's headers) has the macOS fixture's identifiers and text
  for the basics, pickers, sheet and rows; `scripts/build-linux-fixture.sh`
  installs it with a hidden desktop entry named "Harness Fixture". Flows
  take `platforms:` and steps `platform:`, so `flows/fixture` runs on both
  (pointer, menu-extra and background-only flows are macOS only), and the
  non-blocking `linux-desktop` CI job runs it in a private headless desktop
  (`scripts/headless-desktop.sh`: `dbus-run-session` and headless Mutter).
- `menu` and `menu-select`: a window's menu bar (GTK 3, Qt, GTK 4's
  `GtkPopoverMenuBar`) and GTK 4's header-bar menu buttons, whose menus
  exist only while open, so the harness opens them, reads or chooses, and
  closes them again. GTK 4's menu bar items have no action, so their menus
  wait for real clicks in L5; the fixture has one, and a "More" button that
  `flows/fixture/menus.yaml` uses.
- Menu bar extras are status icons (`menu --extras`, `menu-select
  --extras`): StatusNotifierItem and DBusMenu over the session bus, found
  through the watcher (GNOME's AppIndicator support, KDE, waybar) and any
  `StatusNotifierItem-*` name, matched by title, ID or process. Choosing
  sends DBusMenu's `clicked` event; an icon without a path is activated.
  `fixtures/linux/status-item.py` (Python with Gio) is the test icon, and
  `flows/fixture/status-icon.yaml` uses it. Flow `shell` steps now run
  through `CommandRunner`, so one can leave a program running.
- Hidden trees for Chromium and Electron (see
  [Chromium and canvas](/design/chromium-and-canvas.md)): the launch flag,
  the relaunch hint, and the opt-in brief screen reader flag.
- Role and action mapping onto the AX vocabulary.
- `snapshot`, `find`, `read`, `collect`, `press`, `set-value`, `focus`,
  `select`, `increment`, `scroll-to`, `type` into editable text.
- Menus.
- Menu extras over SNI and DBusMenu.
- Hidden trees for Electron, Chromium and Qt.
- A GTK4 fixture in Swift with the same ids and strings as the macOS one,
  and `platform:` filtering in flows.

## L5: Windows, capture and real input per compositor (XL, one PR per compositor)

- **wlroots first, as it needs no prompts and runs headless in CI:** IPC
  window list, screencopy capture, virtual pointer and keyboard.
- **KDE:** plasma window management, portal capture and libei.
- **GNOME:** the extension and its versioned D-Bus API, portal grants with
  restore tokens, Mutter fallback.
- Shared across all three:
  - uinput fallback.
  - Window-relative coordinates.
  - xkbcommon layouts and text typing.
  - Clipboard and paste.
  - Idle detection.
  - Screen lock.
  - Stop shortcut via GlobalShortcuts.
  - Recording.
- Background coordinate input returns a structured unsupported error.

Acceptance: the fixture flows, including pointer flows, pass on all three
compositors.

Progress:
- `HarnessWayland`, a Wayland client in Swift (the owner's choice over
  libwayland-client and external tools): the wire format, a reading
  thread with a listener per object, round trips, the registry, and
  descriptors sent with `sendmsg`. Capture through wlr-screencopy into
  POSIX shared memory (`shm_open`, unlinked at once, since Glibc's module
  hides `memfd_create`).
- Sway: windows, their pids and content rectangles from its IPC
  (`SwayIPC`), and the screen through wlr-screencopy. A `Compositor`
  interface in `HarnessLinux` matches AT-SPI windows to the compositor's
  by pid then title, so `windows` reports where windows are and
  `screenshot` works on desktop apps (cropped, labelled and gridded by
  the shared renderer). Element positions stay window-relative, as on
  macOS, and the window-relative notice goes away where the compositor
  places the window.
- `scripts/headless-desktop.sh` runs Sway as well as Mutter
  (`HEADLESS_DESKTOP_COMPOSITOR=sway`), and the `linux-desktop` CI job
  runs the fixture flows under both.
- Real input on wlroots: the virtual pointer (absolute moves on the output
  under the point, buttons, scroll axes) and the virtual keyboard, which
  uploads a keymap holding exactly the keys a step needs (as `wtype`
  does), so any text types whatever the layout. `click`, `double-click`,
  `right-click`, `hover`, `drag`, `scroll`, `long-press` and `swipe`, `key`,
  and `type --real` bring the window forward through Sway's IPC, take a
  turn with the input, are refused to background-only agents, and report
  what changed. ⌘ means Control. `focus` clicks a field when its app won't
  move focus on request. `flows/fixture/pointer.yaml` now runs on Linux
  too, against the GTK fixture's new pointer section (a click canvas, drag
  and drop, hover, a context menu); CI runs it under Sway, not yet Mutter.
- GNOME, part one (the owner chose portals over input and capture inside
  the Shell extension, as macOS asks for TCC grants once): the extension
  (`packaging/linux/gnome-extension`, installed by
  `scripts/install-gnome-extension.sh`) only lists windows (pid, title, app
  ID, frame, focus) and monitors and activates windows, over D-Bus;
  screenshots come from the Screenshot portal, non-interactive once the
  user has allowed it, cropped to the window. The headless desktop runs a
  private `gnome-shell` (its own home too) with the extension enabled,
  where the fixture flows pass. CI can't: GNOME Shell needs the system bus
  and logind, which a container lacks (its UI start-up fails and apps
  never reach accessibility), and the runners' own Ubuntu 24.04 has GTK
  4.14 without element IDs; CI covers the flows under Mutter and Sway.
- GNOME, part two: real input through the RemoteDesktop portal (pointer
  and keyboard devices, no screencast). GNOME asks once; the restore token
  is kept in the harness's state folder (`gnome-remote-desktop-token`) and
  later sessions start without asking, as a TCC grant does. The session
  closes after 30 s unused. Verified on the owner's GNOME 50 desktop: a
  click on the fixture's button, then typed text, `ctrl+a` and more text,
  the second run without a prompt. Real input reaches no app in a
  headless GNOME Shell, so that path can't be tested headless.
- KDE: windows from KWin scripts (loaded over D-Bus, reporting back to
  the helper, which now answers D-Bus method calls), screenshots and input
  through the portals as on GNOME (`PortalInput`, renamed from
  `GnomeInput`). KDE's portal takes scrolling only as wheel steps, each
  about 2.4 points in GTK. The headless desktop runs `kwin_wayland
  --virtual` with PipeWire, and CI runs every fixture flow, the pointer
  flow included, under it. Packages on Ubuntu: `kwin-wayland`,
  `kwin-common`, `xdg-desktop-portal-kde` and
  `qml6-module-qt5compat-graphicaleffects`.
- Setup: `permissions` status, grant and reset, a notification with Set
  up when an agent needs one that's missing, and the items in `doctor`
  ([permissions](/design/permissions.md)). The extension's D-Bus name moved
  to `org.gnome.Shell.Extensions.MacosHarness` for extensions.gnome.org,
  where `grant` installs it from without a log-out.

## L6: Control Tower on Linux (L)

- Thin GTK4 and libadwaita bindings.
- The sessions, pairing, settings and setup checklist windows.
- SNI tray icon.
- Overlay: extension on GNOME, layer-shell on KDE and wlroots.

## L7: Packaging and release (M)

- Static-stdlib builds for x86_64 and arm64.
- Tarball and `install.sh` with the systemd unit, udev rule and extension.
- .deb and .rpm through nfpm, and a Homebrew formula.
- A Linux path in `release.sh`.
- A release check matrix on Ubuntu, Fedora and Arch.
- Product name settled here at the latest.

## L8: Docs, skill and a release candidate (M)

- Linux sections in the guides.
- Per-platform generated reference.
- Skill wording.
- Acceptance runs on GNOME, KDE and Sway.
- A release candidate. The owner picks the version at release (likely 1.1, not 2.0).

# CI

- macOS jobs stay as they are and must pass on every PR in the stack.
- Linux build and test jobs on x86_64 and arm64 are blocking from L1.
- Headless Sway flows are blocking from L5.
- Headless KWin (`kwin_wayland --virtual`) and `mutter --headless` flows are
  non-blocking, like today's iOS job.
- Android flows on Linux run with KVM, non-blocking at first.

# Risks

- **The GNOME extension** must be kept working across GNOME 46–50+ and its
  review rules.
- **Mutter's private D-Bus** may be restricted in a later GNOME.
- **AT-SPI speed**: no multi-attribute call, but `Cache.GetItems` returns a
  whole tree in one; [S11](/research/s11-atspi-access.md) measured it. Apps
  that don't implement the cache would need a walk, pipelined.
- **Portal differences:** KDE's restricted interfaces and
  xdg-desktop-portal-wlr's missing RemoteDesktop vary by distro and version.
- **Real input is weaker on Linux:** uinput input can't be told apart from
  the user's, so idle detection and the stop guard rails are weaker there.
  Document it in the security model.
- **The L2 split could regress macOS.** Mitigated by moving code without
  edits and running full macOS validation on every PR.
