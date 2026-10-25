---
type: Plan
title: "2.0: Linux support"
description: Decisions, architecture seams and stacked milestones for adding GNOME, KDE and wlroots Wayland support in Swift without breaking macOS.
tags: [linux, wayland, 2.0, plan, memory-safety, ci, packaging]
status: draft
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-25T15:45:00Z }
sources:
  - id: interview
    resource: Interview with the owner in a Claude Code session on the Linux desktop, 2026-10-25
    title: 2.0 kickoff interview
  - id: audit
    resource: /research/linux-port-audit.md
    title: Linux port audit
---

# Goal

2.0 adds Linux to macos-harness without breaking macOS: every CLI command
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
| Branches | Integration branch `2.0` cut from `main`; work lands as stacked PRs on `linux/<step>` branches, the first targeting `2.0`. Nothing merges without the owner's say-so and green CI. `main` keeps taking 1.0.x fixes, merged forward into `2.0` |

# Architecture

The audit[^audit] found HarnessCore mixes portable logic with macOS calls.
2.0 splits it:

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
- Logging facade over `os.Logger`.
- XDG paths in `HarnessPaths`; JSON settings and pairings under XDG on
  Linux.
- One product-name constant.
- `Package.swift` builds only portable targets on Linux.
- Strict memory safety switched on.
- Portable tests moved into a `HarnessClientTests` target.
- CI: blocking `ubuntu-24.04` and `ubuntu-24.04-arm` jobs for build and
  test, plus build-only checks in Fedora and Arch containers.

Acceptance: `swift build && swift test` green on macOS and Linux, and the
macOS flows still pass.

## L2: Split HarnessCore behind the seams (L, several PRs)

- Introduce the protocols and `HarnessImaging`.
- Move macOS code into `HarnessMac` file by file.
- Make `RawNode`, window ids and keys platform-neutral.
- Add capability gating in `hello`, the MCP server and the CLI.

This is the riskiest step for macOS. Every PR runs the full macOS validation
from the release process.

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

## L4: Seeing and element actions through AT-SPI (L)

- Spike first: libatspi against our own D-Bus client over GDBus, measured on
  snapshot latency for Nautilus, VS Code and a Qt app.
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

## L8: Docs, skill and 2.0 release candidate (M)

- Linux sections in the guides.
- Per-platform generated reference.
- Skill wording.
- Acceptance runs on GNOME, KDE and Sway.
- `2.0.0-rc.1`.

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
- **AT-SPI speed**: no multi-attribute call. The L4 spike decides the client.
- **Portal differences:** KDE's restricted interfaces and
  xdg-desktop-portal-wlr's missing RemoteDesktop vary by distro and version.
- **Real input is weaker on Linux:** uinput input can't be told apart from
  the user's, so idle detection and the stop guard rails are weaker there.
  Document it in the security model.
- **The L2 split could regress macOS.** Mitigated by moving code without
  edits and running full macOS validation on every PR.
