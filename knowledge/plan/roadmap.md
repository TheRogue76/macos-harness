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

# M4: First public release, 0.1 (M) — released 2026-10-07, see [acceptance](/research/m4-acceptance.md)

Pairing polished, policy file, journal, `--json` everywhere, `SKILL.md` and
setup docs for Claude Code, Codex and pi. Developer ID signing, notarization,
GitHub Releases and a Homebrew tap.

Decided with the owner on 2026-10-06:

- The repo (`TheRogue76/macos-harness`) and the Homebrew tap
  (`TheRogue76/homebrew-tap`, a cask) are public from the start of M4.
- The journal redacts text: `type` and `set-value` entries record the
  length, never the value.
- The policy file lists blocked apps (no access) and read-only apps (no
  actions). Element-level rules wait for real demand.
- `macos-harness setup claude|codex|pi` shows the change it will make, asks,
  then registers the MCP server or installs the skill.
- The dev CLI is linked as `macos-harness-dev`, so it never shadows the
  release `macos-harness`.
- Release signing uses the Developer ID certificate valid to 2031, by hash
  (the keychain holds two with the same name).

You'll need to: store notarization credentials (`xcrun notarytool
store-credentials`) yourself, and grant the release app's permissions and
pairing prompts during the clean-install test.

Done when the same tier A task works from Claude Code (MCP), Codex (MCP) and
pi (CLI + skill) on a clean install from Homebrew.

Status: v0.1.0 is notarized, published and installs from the tap, and
Claude Code passed on the clean install. Codex and pi on the release build
are still to be confirmed. Delivered beyond the plan: JSON errors under
`--json`, the `journal` command, a 2-minute limit on pairing prompts, and
`macos-harness-dev` for the dev CLI. See the
[release process](/plan/release-process.md).

# M5: Flows, recording and CI (L) — done 2026-10-07, see [acceptance](/research/m5-acceptance.md)

YAML flows, `flow run` with failure artifacts and JUnit output, `flow export`
from a session journal, window recording and frame extraction. Flows against
the fixture app run in GitHub Actions (or the S5 fallback). Tier B suites
(Notes, Reminders, Calendar test areas) as flows with setup and a teardown
that also runs on failure. Tier C (Safari with local pages) and tier D
(Mail, Messages, FaceTime read-only, strict policy) suites.

Done when a recorded agent session replays green, and CI runs fixture flows
on every push.

Decided with the owner on 2026-10-07:

- One milestone, with tiers B, C and D all in scope.
- `flow export` writes `${text_1}`-style placeholders where an agent typed,
  with the redacted length as a hint; values come from the flow file or
  `flow run --var`. The journal stays text-free.
- CI first checks whether a helper started as a child of the job's shell
  inherits the runner's permissions (S5). If not, CI stays at build and
  unit tests; UI flows run locally. No CI job ever
  drives the owner's Mac.
- Suites get a run-scoped policy that can only add restrictions to the
  user's `policy.yaml` (tier D runs with Mail, Messages and FaceTime
  read-only). Failure artifacts from tier B and D runs stay on the machine;
  they'd show the owner's real data.
- Carried over from M4: confirm Codex and pi on the release build.

Delivered beyond the plan: guards for flow steps (`only_if`, `quit
if_launched`, `refused`), pointer actions that scroll off-screen targets
into view, scroll-area-aware visibility, selectors that reach open context
menus, journal sessions per agent process, and an MCP `record` tool. See
[flows](/design/flows.md).

# M6: Electron, web and canvas apps (L) — done 2026-10-07, see [acceptance](/research/m6-acceptance.md)

Enable hidden trees in Electron and Chromium apps, handle very large trees,
web areas, Vision OCR for text not in the tree, screenshot ref labels for
canvas apps, Catalyst quirks found in S3.

Done when agreed tasks work in apps you name (for example VS Code, Slack,
Figma).

Decided with the owner on 2026-10-07:

- Acceptance apps: VS Code (a folder in `~/macos-harness-sandbox`), Chrome as
  a separate instance with a throwaway profile (the owner's Chrome and
  sign-ins untouched), Slack read-only, and Spotify.
- Chromium and Electron apps get their hidden accessibility tree switched
  on automatically the first time an agent reads them, with a notice.
- Password managers are only blocked through the policy file, as the
  requirements say; nothing is hard-coded.
- Claude (the desktop app driving this work) and 1Password are left out of
  testing.

Delivered: hidden trees switched on (or a notice with the launch flag that
does it), `launch --new-instance` with flow aliases for a throwaway
browser, text recognition (`find --ocr`, `click --ocr`, `ocr: true` in
flows), coordinate grids on screenshots, and duplicate elements counted
once. Very large trees needed no new work: Spotify's 4,428 nodes read in
0.7 s within the existing limits. See [Chromium apps, text recognition and
grids](/design/chromium-and-canvas.md).

# M7: VM mode — dropped 2026-10-07

Planned: a macOS VM image with the helper preinstalled and permissions
pre-granted, driven from the host CLI, optionally as a CI runner.

Dropped by the owner before any work started. A macOS VM can't be small:
the guest is a full copy of macOS, about 15 GB at the very least and 25–50
GB for prebuilt images, which goes against keeping macOS Harness a light
tool. Isolation stays what it is: guard rails on the user's own Mac, and
GitHub's hosted runners for CI (see [S5](/research/s5-ci-permissions.md)).

# M8: iOS Simulator target (L)

`--target sim:<udid>` on the same commands: element tree, touch input,
screenshots, with simulator lifecycle through `simctl`. Gives Codex and pi
the iOS abilities Claude has now, plus an element tree.

# Risks

| Risk | Mitigation |
|---|---|
| Permissions still get charged to the agent host | S1 in M0, before anything else is built on the helper |
| Background events rarely work, so real input moves your cursor often | Guard rails in M3 (VM mode was dropped as too heavy) |
| Apple's apps change between macOS releases | Automated tests run against the fixture app; built-in apps are the check-in suite |
| Hosted CI runners can't grant permissions | S5 decided it: hosted runners work |
| Huge trees (Xcode, Electron) are slow | AX messaging timeouts, depth limits, lazy `expand` |
| Pairing isn't a real security boundary | Say so in the docs; macOS permissions remain the real boundary |
| Test areas in Notes or Calendar sync to iCloud | Prefer "On My Mac" accounts; always tear down |

[^requirements]: Requirements from the kickoff interview
