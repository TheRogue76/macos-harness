---
type: Requirements
title: Requirements from the kickoff interview
description: The owner's answers on scope, safety, interface, audience and workflow, and what each one means for the design.
tags: [requirements, scope, safety, decisions]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-06T15:48:51Z }
sources:
  - id: interview
    resource: Requirements interview in a Claude Code session with human:parsa.nasirimehr, 2026-10-06
    title: Kickoff requirements interview
    author: human:parsa.nasirimehr
---

# Answers and their consequences

All answers come from the kickoff interview.[^interview]

| Topic | Answer | What it means |
|---|---|---|
| Use cases | All four: verify own apps, drive third-party apps, repeatable UI checks, screenshots and recordings | Nothing is out of scope; ordering does the prioritizing |
| App types | Native SwiftUI/AppKit, Catalyst, Electron/web, and anything else best effort | Needs AX plus fallbacks (coordinates, OCR) for poor trees |
| First target | Third-party apps, starting with the apps preinstalled on macOS; Electron and web apps after native ones work well | Apple's built-in apps are the acceptance suite; see [test targets](/plan/test-targets.md) |
| iOS Simulator | Built in M8: `sim:<device>` targets through Device Hub (Xcode 27+) | See [iOS Simulator targets](/design/ios-simulator.md) |
| Interface | CLI + MCP server + skill, one core | pi uses the CLI; Claude Code and Codex can use either |
| Isolation | The user's Mac; no VM mode | Shared desktop rules apply from day one. VM mode was planned for later and dropped on 2026-10-07 as too heavy |
| Footprint | A light tool | Nothing multi-gigabyte or heavyweight: no VM images, no bundled runtimes. The owner dropped VM mode for this reason |
| App scope | Anything; no allowlist or blocklist by default | Policy file exists but ships empty. Each agent's own rules still apply |
| Real input | Allowed with guard rails | AX first, then background events, then real input with overlay, stop hotkey and frontmost check |
| Access | Pair each agent once | First call from a new agent asks the user; trusted after that. The chosen UI also offers "This session only" ([UI design](/design/ui-control-tower.md)) |
| Audience | Open source, public | Developer ID signing, notarization, Homebrew, public docs |
| Oldest macOS | 15 | ScreenCaptureKit screenshots and `SCRecordingOutput` are always available |
| Per-app knowledge | No | OKF stays project documentation; no app playbooks at runtime |
| Test apps | No-personal-data apps; Notes, Reminders, Calendar and Finder in test areas only; Safari without sign-ins; Mail, Messages and FaceTime read and navigate only, never send | Fixture setup/teardown and a strict test policy |
| Replay | YAML flow files, plus exporting a recorded agent session as a flow | Every action is journaled with a semantic selector |
| CI | GitHub Actions hosted macOS runners | Needs a spike: can permissions be granted there? |
| License | MIT | |
| Name | `macos-harness` | CLI, helper app, MCP server and Homebrew package share it |
| Owner | Personal GitHub, personal Developer ID | Signing identity already on the [dev machine](/environment/dev-machine.md) |
| Workflow | Check in per milestone | Each milestone ends with a demo and review before the next starts |

[^interview]: Kickoff requirements interview
