---
type: Plan
title: Roadmap
description: Milestones from spikes to a public release and beyond, with acceptance criteria and risks.
tags: [roadmap, milestones, plan, risks]
status: draft
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-06T15:48:51Z }
sources:
  - id: requirements
    resource: /project/requirements.md
    title: Requirements from the kickoff interview
  - id: architecture
    resource: /plan/architecture.md
    title: Architecture
---

# How we work

Each milestone ends with a check-in: a live demo against its acceptance
tasks, then review before the next one starts.[^requirements] Findings go
into this bundle as they happen (spike results become `research/` concepts).
Sizes are relative: S, M, L.

# M0: Foundations and spikes (M) — done 2026-10-06

Build:
- Swift package: `HarnessCore`, the helper app, the CLI, and the fixture app;
  MIT license; README; CI that builds and runs unit tests.
- Helper skeleton: menu bar icon, socket server, `doctor`, pairing prompt.
  Dev-signed with the Apple Development identity and a `.dev` bundle ID.
- CLI: `doctor`, `apps`, `version`.

Time-boxed spikes, each written up in `research/`:

| ID | Question |
|---|---|
| S1 | Does the helper keep its own permissions when the CLI is called from Claude Code, Codex and pi? |
| S2 | Can ScreenCaptureKit capture covered windows and windows on other Spaces? How often does macOS ask to re-confirm Screen Recording? |
| S3 | How good and how fast are AX trees in the tier A apps and a Catalyst app? |
| S4 | Which apps accept keys and clicks posted in the background? |
| S5 | Can permissions be granted to our helper on GitHub's hosted macOS runners? |
| S6 | Do out-of-process Open/Save panels show up in the target app's AX tree? |

You'll need to: grant Screen Recording and Accessibility to the dev helper
once.

Done when `macos-harness doctor` is green and `macos-harness apps` works from
Claude Code, Codex and pi.

# M1: Eyes (M) — done 2026-10-06, see [acceptance](/research/m1-acceptance.md)

`apps`, `windows`, `screenshot` (window, app, element; covered windows;
scaling; ref labels), `snapshot` (pruned AX tree with refs and hit points,
`expand`), `find`, `menu` listing.

Done when, for each [tier A app](/plan/test-targets.md), an agent can
describe the UI and locate every visible control by ref, and screenshots
never include other apps.

# UI: Control Tower (S) — done 2026-10-06

Inserted between M1 and M2 at the owner's request: the helper's menu bar
panel, pairing card, setup window, overlay and stop hotkey, in light and
dark. See [the UI design](/design/ui-control-tower.md). It also delivered
part of M3's guard rails early: stop per agent and stop all, ⌃⌥⌘., and the
overlay pieces (glow, ripple, driving panel).

# M2: Hands through AX, plus MCP (M) — done 2026-10-06, see [acceptance](/research/m2-acceptance.md)

AX actions (`press`, `set-value`, focus, select, scroll to visible,
increment), `menu select`, `window` operations, `launch` and `quit`, `wait`,
settle detection with tree diffs, and the `macos-harness mcp` server so
Claude Code and Codex can call it natively.

Also: refs must not survive a helper restart in a way that lets an old ref
act on a different element, and actions must check `AXEnabled` before
reporting success (S4).

Delivered beyond the plan: `type` and `key` through background key events
(rung 2), the typing guard on focus changes, key routing to out-of-process
file panels. See [actions design](/design/actions.md).

Done when an agent completes, without real input: 12 × 34 in Calculator;
writing, formatting and saving a document in TextEdit to the sandbox folder;
paging through a PDF in Preview; switching cities in Weather.

# M3: Real input with guard rails (L) — done 2026-10-06, see [acceptance](/research/m3-acceptance.md)

`click`, `hover`, `drag`, `scroll`, `type`, `key` through the full ladder;
showing the existing overlay and driving panel during real input, frontmost
check, yield to the user, input lease, clipboard restore, Secure Input
detection. Tier B setup and teardown. (Stop hotkey and stop all already
exist from the UI milestone.)

Done when an agent makes a move in Chess by dragging, moves files between
sandbox folders in Finder, uses right-click menus, and creates, edits and
deletes items only inside the Notes, Reminders and Calendar test areas. The
stop hotkey halts it mid-task.

Delivered beyond the plan: context menus returned as refs, keyboard-style
modifier handling (a latched ⌘ broke typing), stops that survive a helper
restart, and `set-value` that starts an editing session. Clipboard restore
was dropped: nothing uses the clipboard. Tier B setup and teardown ran by
hand through the harness; scripted suites with automatic teardown move to
M5's flows. See [actions design](/design/actions.md).

# M4: First public release, 0.1 (M)

Pairing polished, policy file, journal, `--json` everywhere, `SKILL.md` and
setup docs for Claude Code, Codex and pi. Developer ID signing, notarization,
GitHub Releases and a Homebrew tap.

You'll need to: create the GitHub repo and store notarization credentials
(`xcrun notarytool store-credentials`) yourself.

Done when the same tier A task works from Claude Code (MCP), Codex (MCP) and
pi (CLI + skill) on a clean install from Homebrew.

# M5: Flows, recording and CI (L)

YAML flows, `flow run` with failure artifacts and JUnit output, `flow export`
from a session journal, window recording and frame extraction. Flows against
the fixture app run in GitHub Actions (or the S5 fallback). Tier B suites
(Notes, Reminders, Calendar test areas) as flows with setup and a teardown
that also runs on failure. Tier C (Safari with local pages) and tier D
(Mail, Messages, FaceTime read-only, strict policy) suites.

Done when a recorded agent session replays green, and CI runs fixture flows
on every push.

# M6: Electron, web and canvas apps (L)

Enable hidden trees in Electron and Chromium apps, handle very large trees,
web areas, Vision OCR for text not in the tree, screenshot ref labels for
canvas apps, Catalyst quirks found in S3.

Done when agreed tasks work in apps you name (for example VS Code, Slack,
Figma).

# M7: VM mode (L)

A macOS VM image with the helper preinstalled and permissions pre-granted;
the host CLI drives it. Optional CI runner.

# M8: iOS Simulator target (L)

`--target sim:<udid>` on the same commands: element tree, touch input,
screenshots, with simulator lifecycle through `simctl`. Gives Codex and pi
the iOS abilities Claude has now, plus an element tree.

# Risks

| Risk | Mitigation |
|---|---|
| Permissions still get charged to the agent host | S1 in M0, before anything else is built on the helper |
| Background events rarely work, so real input moves your cursor often | Guard rails in M3; VM mode in M7 for long runs |
| Apple's apps change between macOS releases | Automated tests run against the fixture app; built-in apps are the check-in suite |
| Hosted CI runners can't grant permissions | S5 decides early; fall back to a self-hosted Mac or the VM |
| Huge trees (Xcode, Electron) are slow | AX messaging timeouts, depth limits, lazy `expand` |
| Pairing isn't a real security boundary | Say so in the docs; macOS permissions remain the real boundary |
| Test areas in Notes or Calendar sync to iCloud | Prefer "On My Mac" accounts; always tear down |

[^requirements]: Requirements from the kickoff interview
