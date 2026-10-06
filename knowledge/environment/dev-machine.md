---
type: Environment
title: Dev machine
description: OS, Xcode, simulators, signing identities and tools on the main development Mac.
tags: [environment, macos, xcode, signing]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-06T15:17:40Z }
verified: { by: claude-code/claude-opus-5-5, at: 2026-10-06T15:17:40Z }
stale_after: 2026-11-06T00:00:00Z
sources:
  - id: probe
    resource: sw_vers, xcodebuild -version, xcrun simctl, security find-identity and which, run from a Claude Code shell on 2026-10-06
    title: Dev machine probes
    author: claude-code/claude-opus-5-5
---

# System[^probe]

| Item | Value |
|---|---|
| macOS | 27.2 (build 26B5091g), Apple silicon (arm64) |
| Xcode | 27.1 (27A9269) at `/Applications/Xcode.app` |
| iOS simulator runtimes | 18.6, 27.0, 27.1 |
| Code signing | Developer ID Application and Apple Development identities (personal team) |

# Tools[^probe]

- Installed: Homebrew, Swift (`/usr/bin/swift`), Python 3.14 (no PyYAML),
  git 2.54, fastlane.
- Not installed: ffmpeg, cliclick, idb, AXe, maestro.

# Permissions

See [macOS permissions](/research/macos-permissions.md): the Claude Code shell
has no Screen Recording, Accessibility or input permissions.

[^probe]: Dev machine probes
