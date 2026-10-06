---
type: Analysis
title: "S1: who macOS holds responsible for the helper's permissions"
description: A helper started through LaunchServices is responsible for itself, so it holds its own grants; the CLI and shell are charged to the agent host.
tags: [spike, m0, permissions, tcc, responsibility]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-06T16:15:00Z }
verified: { by: claude-code/claude-opus-5-5, at: 2026-10-06T16:15:00Z }
stale_after: 2027-10-06T00:00:00Z
sources:
  - id: spike
    resource: "`macos-harness spike permissions` run from a Claude Code desktop shell, 2026-10-06 (uses the private responsibility_get_pid_responsible_for_pid via dlsym)"
    title: S1 spike output
    author: claude-code/claude-opus-5-5
---

# Result

Confirmed.[^spike] With the helper started by the CLI through `open -g`:

| Process | Responsible process |
|---|---|
| `macos-harness-helper` (parent: launchd) | itself |
| `macos-harness` CLI | `claude` (Claude Code) |
| `zsh` | `claude` |
| `claude` | itself, because the Claude app starts it through `/Applications/Claude.app/Contents/Helpers/disclaimer` |
| `Claude` (desktop app) | itself |

So the helper holds its own Screen Recording and Accessibility grants no matter
which agent starts it. Without the helper, permission prompts would name the
agent binary. For Claude Code that binary lives in a versioned path
(`…/claude-code/2.1.288/…`), so grants would be lost on every update.

# Rules that follow

- Always start the helper through LaunchServices (`open`, `SMAppService`),
  never as a child of the CLI, or it inherits the caller's responsibility.
- The exception is CI, where inheriting is the point; see
  [S5](/research/s5-ci-permissions.md).

# Confirmed after the grant

With both permissions granted to macOS Harness Dev, the helper reports
Accessibility, Screen Recording, PostEvent and ListenEvent as granted, while a
probe from the Claude Code shell still reports all four as missing. The grants
also survived several reinstalls of the helper, because they're tied to the
bundle ID and the Apple Development signing identity.

Calls from inside Codex's sandbox and from a real pi session reached the same
helper with the same grants.

[^spike]: S1 spike output
