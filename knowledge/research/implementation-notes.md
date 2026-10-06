---
type: Platform Constraint
title: Platform quirks the code works around
description: macOS, AppKit, accessibility and Swift behaviours that shaped the code but aren't visible in it, collected when code comments were removed.
tags: [macos, accessibility, appkit, swift, gotchas]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-06T23:59:00Z }
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
- **Menu shortcuts for special keys** arrive as private-use characters
  (U+F700–F72D: arrows, home, end, page up and down, forward delete) or
  control characters (return, escape, tab, delete), which `MenuService`
  maps to their symbols.

# AppKit and processes

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
- **Install replaces app bundles whole.** Overwriting a signed binary in
  place can leave macOS with a stale code signature for the file, and the
  new binary gets killed at launch.
- **Key codes follow the US ANSI layout.** On other layouts, `key` letter
  shortcuts may land on a different key. Typed text is unaffected because it
  sends characters, not key codes.
- **Real scrolling goes in steps of about 40 px**, 16 ms apart, so apps
  animate as they would for a trackpad instead of jumping.

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
  server tests run their clients on plain threads, and CI runs tests with
  `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1` (a one-thread pool), which
  reproduces the starvation on any machine.
- **CI builds with an older toolchain** (Xcode 16, Swift 6.0, macOS 15
  SDK). It times out on long `??` chains and ternaries the newer compiler
  handles, and the older SDK lacks Sendable annotations on ScreenCaptureKit
  types (hence `@preconcurrency import` in the thumbnailer).
- **`objectWillChange` fires before the new values land**, so the menu bar
  controller re-lays out on the next main-queue turn rather than
  immediately.
