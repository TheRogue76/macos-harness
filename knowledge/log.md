# Knowledge log

## 2026-10-07

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
