---
type: Analysis
title: M4 acceptance run
description: v0.1.0 is notarized, published and installs from the Homebrew tap; Claude Code completed the Calculator task through MCP on the clean install, while Codex and pi on the release build are still to be confirmed. Findings cover notarization times, older CI toolchains, Homebrew ownership, agent sign-in and local models.
tags: [m4, acceptance, release, homebrew, notarization, agents]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-07T00:30:00Z }
verified: { by: claude-code/claude-opus-5-5, at: 2026-10-07T00:20:00Z }
stale_after: 2027-10-07T00:00:00Z
sources:
  - id: run
    resource: "scripts/release.sh, brew install and agent runs on macOS 27.2, 2026-10-06/07"
    title: M4 acceptance output
    author: claude-code/claude-opus-5-5
---

# Results

| Check | Result |
|---|---|
| Notarization | Both submissions accepted with no issues; stapled; `spctl` reports "Notarized Developer ID"[^run] |
| Release | v0.1.0 on GitHub (published as a pre-release first), cask in `TheRogue76/homebrew-tap` |
| Clean install | `brew install --cask therogue76/tap/macos-harness`: app in `/Applications`, `macos-harness` linked into `/opt/homebrew/bin`, quarantined download accepted by Gatekeeper, helper started on first `doctor` |
| Setup | `macos-harness setup claude`, `codex` and `pi` registered the MCP server (Claude Code user scope, Codex) and installed the skill (pi) |
| Claude Code (MCP) | Calculator 12 × 34 = **408** in about 90 s on the normal model, 12 requests, every harness action under a second |
| Codex (MCP) | Not run on the release build: the `codex` command had disappeared from the PATH by test time. It worked through `omlx launch` an hour earlier |
| pi (CLI + skill) | Not run on the release build yet |

The roadmap's done criterion asks for all three agents; Codex and pi remain
to be confirmed on the release build. Both worked against the dev build in M0
and through `omlx launch` with a test prompt during this run.

# Findings

1. **Notarization is slow the first times.** The first submission took
   about 45 minutes and the second about 35; Apple holds new teams' early
   submissions longer. `scripts/release.sh` waits, so run it in the
   background.
2. **CI's older toolchain catches what the newer one doesn't.** GitHub's
   `macos-15` runners (Xcode 16, Swift 6.0) failed five times where Swift
   6.4 passed: an optional inferred differently, long `??` chains it can't
   type-check in time, a missing Sendable annotation in the macOS 15 SDK, an
   actor's `let` used from another module without `nonisolated`, and tests
   that blocked the concurrency pool. See
   [platform quirks](/research/implementation-notes.md).
3. **Universal builds warn about a deployment target of macOS 27.** The
   warning is spurious; `vtool -show-build` confirms `minos 15.0` for both
   architectures.
4. **Homebrew belonged to another macOS account on this Mac**, so this
   account couldn't install anything until the owner ran `sudo chown -R`.
   Not a harness problem, but users with several accounts will hit it.
5. **`brew style` silently turns on Homebrew's developer mode**, a
   persistent setting. It was switched off again right away. Don't run
   Homebrew developer commands on the owner's machine.
6. **The desktop app's Claude Code session doesn't sign in the `claude`
   CLI.** A `claude -p` started from the session inherited the desktop app's
   `ANTHROPIC_BASE_URL` and failed with an expired OAuth session. After the
   owner ran `claude auth login`, the test ran with the desktop variables
   removed (`env -u ANTHROPIC_BASE_URL -u CLAUDECODE …`).
7. **Local models via oMLX work but are slow.** `omlx launch <tool> --model
   <model> <args>` forwards the remaining arguments; a literal `--` is
   forwarded too and drops Codex and pi into interactive mode. Claude Code's
   settings model beats omlx's tier variables, so `ANTHROPIC_MODEL` had to
   pin it. On Qwen3.8-27B (4-bit) Claude Code needed 1–2 minutes per step
   and hit a 15-minute limit one press short of the answer; the owner
   preferred the normal model for this test.
8. **Change reports let agents catch their own slips.** Claude Code pressed
   "9" instead of "4", read `× 39` in the change report, pressed Delete and
   then "4", without a new snapshot.

[^run]: M4 acceptance output
