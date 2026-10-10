# Knowledge log

## 2026-10-10

* **Update**: Version 0.6.0 released with the fixes below.
* **Update**: [Actions](/design/actions.md) covers the 0.5.0 feedback fixes: drags into another window or app ([#3](https://github.com/TheRogue76/macos-harness/issues/3)), a drag stopped partway cancelled instead of dropped, menu bar extras with `--extras` including macOS 27's MenuBarAgent and the panels Control Center draws for it ([#2](https://github.com/TheRogue76/macos-harness/issues/2)), and refusing the helper's own UI.
* **Update**: [Snapshot format](/design/snapshot-format.md): title-bar buttons are always shown, named, and found by `find` and selectors ([#4](https://github.com/TheRogue76/macos-harness/issues/4)).
* **Update**: [Platform quirks](/research/implementation-notes.md): an app pressing its own controls through AX runs their handlers off the main thread; macOS 27's MenuBarAgent extras and their Control Center panels.

## 2026-10-09

* **Update**: [S7](/research/s7-simulator-window.md) records that Device Hub's Home button sometimes doesn't take on CI, and the menu fallback.
* **Creation**: M9 done: [Android targets](/design/android.md) and the [acceptance run](/research/m9-acceptance.md); roadmap, requirements, architecture, test targets and platform quirks updated.
* **Creation**: [S8](/research/s8-android-adb.md): adb alone reads and operates an Android emulator; reads take 2–3 s, typing is ASCII only, CI can't run the emulator.
* **Update**: [Roadmap](/plan/roadmap.md) adds M9, Android targets, with the owner's decisions: emulators and phones, adb only, no Gradle builds, start and stop only.
* **Update**: [S7](/research/s7-simulator-window.md) and the [M8 acceptance run](/research/m8-acceptance.md) record what iOS CI on GitHub's `xcode-27` image found: Device Hub listed without a process ID, a slow first text entry, slow first boots and builds; [platform quirks](/research/implementation-notes.md) updated.

## 2026-10-07

* **Creation**: M8 done: [iOS Simulator targets](/design/ios-simulator.md) and the [acceptance run](/research/m8-acceptance.md); [S7](/research/s7-simulator-window.md) gains what building found about Device Hub; roadmap, requirements, architecture, test targets and platform quirks updated.
* **Update**: [Roadmap](/plan/roadmap.md) M8 records the owner's decisions: through the simulator window (Device Hub, Xcode 27+), full scope including build, flows and recording; boot and shut down only.
* **Creation**: [S7](/research/s7-simulator-window.md): Device Hub replaces Simulator.app in Xcode 27 and exposes the simulator's iOS tree through AX; press, text, page scrolling and Home work without the mouse.
* **Update**: The owner dropped VM mode (M7) as too heavy for a light tool; [roadmap](/plan/roadmap.md) and [requirements](/project/requirements.md) record why, and a footprint requirement.
* **Creation**: M6 done: [Chromium apps, text recognition and grids](/design/chromium-and-canvas.md) and the [acceptance run](/research/m6-acceptance.md); flows, platform quirks and roadmap updated.
* **Update**: [Roadmap](/plan/roadmap.md) M6 records the owner's decisions: VS Code, a throwaway Chrome, Slack read-only and Spotify; hidden trees on automatically.
* **Creation**: M5 done: [flows, recording and export](/design/flows.md) and the [acceptance run](/research/m5-acceptance.md); updates to [journal and policy](/design/journal-and-policy.md), [actions](/design/actions.md) and [platform quirks](/research/implementation-notes.md).
* **Update**: [S5](/research/s5-ci-permissions.md) verified: a helper started from the CI job's shell gets the hosted runner's permissions.
* **Update**: [Roadmap](/plan/roadmap.md) M5 records the owner's decisions: placeholders in exported flows, unit-only CI fallback, tiers B–D in one milestone.
* **Creation**: M4 released: [acceptance run](/research/m4-acceptance.md), roadmap updated (Codex and pi on the release build still to confirm).

## 2026-10-06

* **Creation**: [Release process](/plan/release-process.md): Developer ID signing, notarization, GitHub release and the Homebrew cask.
* **Update**: [Agent hosts](/references/agent-hosts.md): the `setup` command, where each host keeps its config, and pi's new MCP support.
* **Creation**: [Journal and policy](/design/journal-and-policy.md): redacted per-session journal and the blocked/read-only policy file.
* **Update**: [Snapshot format](/design/snapshot-format.md) documents JSON errors under `--json`.
* **Update**: [Roadmap](/plan/roadmap.md) M4 records the owner's decisions: public repo and tap, redacted journal, app-level policy, a `setup` command, `macos-harness-dev` for the dev CLI.
* **Creation**: Code no longer carries explanatory comments (rule in AGENTS.md); the reasons they held that weren't recorded elsewhere moved to [platform quirks](/research/implementation-notes.md).
* **Creation**: M3 done: [acceptance run](/research/m3-acceptance.md); [actions design](/design/actions.md) gains real input guard rails, context menus, text field commits and saved stops.
* **Creation**: M2 done: [actions design](/design/actions.md) and [acceptance run](/research/m2-acceptance.md); snapshot format updated for launch-lettered refs and display-based capture.
* **Creation**: [Helper UI: Control Tower](/design/ui-control-tower.md), built from design direction B in light and dark; roadmap gains a UI milestone before M2.
* **Creation**: M1 done: [snapshot format](/design/snapshot-format.md) and [acceptance run](/research/m1-acceptance.md); roadmap updated with M2 prerequisites.
* **Update**: M0 exit criteria met: `doctor` green, `apps` works from Claude Code, Codex (in its sandbox, with `--allow-unix-socket`) and pi. Fixed pi detection after pi renamed its own process ([agent hosts](/references/agent-hosts.md)).
* **Update**: [Agent hosts](/references/agent-hosts.md) now records how agent sandboxes treat the helper socket (Codex's default sandbox blocks it) and the pairing identities seen. [S1](/research/s1-permission-attribution.md) confirmed after the grant.
* **Creation**: M0 spike results: [S1](/research/s1-permission-attribution.md), [S2](/research/s2-window-capture.md), [S3](/research/s3-ax-tree-quality.md), [S4](/research/s4-background-input.md), [S5](/research/s5-ci-permissions.md) and [S6](/research/s6-out-of-process-panels.md).
* **Creation**: Recorded the kickoff interview as [requirements](/project/requirements.md) and drafted the [architecture](/plan/architecture.md), [test targets](/plan/test-targets.md) and [roadmap](/plan/roadmap.md), pending the owner's review.
* **Initialization**: Created the bundle (OKF v0.2) from the kickoff session: [project goal](/project/goal.md), [macOS gap analysis](/research/macos-gap-analysis.md), [macOS permissions](/research/macos-permissions.md), references for [OKF](/references/okf-spec.md), [Claude's iOS Simulator tool](/references/claude-ios-simulator-tool.md) and [agent hosts](/references/agent-hosts.md), and [dev machine](/environment/dev-machine.md) facts.
