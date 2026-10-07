---
type: Analysis
title: "S5: granting permissions on GitHub's hosted macOS runners"
description: The runner images pre-grant Accessibility and Screen Recording to bash and the runner agent, and a helper started as a child of the job shell does inherit them (verified on macos-15 in M5), so UI flows can run on hosted runners.
tags: [spike, m0, ci, github-actions, permissions, tcc]
status: stable
verified: { by: claude-code/claude-opus-5-5, at: 2026-10-07T00:40:00Z }
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-06T16:15:00Z }
stale_after: 2027-04-06T00:00:00Z
sources:
  - id: runner-tcc
    resource: https://github.com/actions/runner-images/blob/main/images/macos/scripts/build/configure-tccdb-macos.sh
    title: runner-images configure-tccdb-macos.sh
    author: team:github-actions
  - id: runner-tcc-27
    resource: https://github.com/actions/runner-images/blob/main/images/macos/scripts/build/configure-tccdb-macos-27.sh
    title: runner-images configure-tccdb-macos-27.sh
    author: team:github-actions
  - id: spike-run
    resource: https://github.com/TheRogue76/macos-harness/actions/runs/37553145165
    title: M5 permissions spike run
    author: claude-code/claude-opus-5-5
  - id: apple-forum
    resource: https://developer.apple.com/forums/thread/834560
    title: "Apple Developer Forums: User TCC DB inaccessible for CI setups"
    author: team:apple-dts
---

# Findings

- **We can't grant permissions ourselves.** On macOS 27 the per-user
  permission database moved into a `ProtectedSystem` container and can't be
  edited. Apple's only supported routes are MDM profiles (which can't
  pre-approve Screen Recording) or a person in System Settings. Apple's
  suggestion for CI is a VM snapshot taken after approving by hand.[^apple-forum]
- **GitHub grants them at image build time.** Images are built with SIP off
  and insert grants for Accessibility, Screen Recording, PostEvent and Apple
  Events. The grantees are `/bin/bash`, `/usr/bin/osascript`, Terminal, the
  runner provisioner and the hosted compute agent.[^runner-tcc] The macOS 27
  script handles the new database location.[^runner-tcc-27]

# Approach

In CI, start the helper *as a child of the job's shell* (run its binary
directly, not through `open`), so macOS charges it to the already-granted
runner process. That is the opposite of the desktop rule in
[S1](/research/s1-permission-attribution.md), so the CLI needs an explicit
opt-in for it (for example `MACOS_HARNESS_LAUNCH=child`).

# Verified (M5)

On GitHub's `macos-15` runner (macOS 15.7.9), with `MACOS_HARNESS_LAUNCH=child`
and an ad-hoc signed dev build, `doctor` reported Accessibility and Screen
Recording granted. The caller chain was `macos-harness ← bash ← Runner.Worker
← Runner.Listener ← hosted-compute-agent ← bash`. A snapshot of Calculator,
an AX press (display `0 → 1`) and a 198×350 screenshot with real pixels all
worked.[^spike-run]

CI also needs pairing without a person: a helper started as a child with
`MACOS_HARNESS_AUTO_APPROVE=1` approves every caller. Both variables are
required, and a child helper only has the permissions of whatever started it,
so this grants nothing the parent didn't already have.

[^spike-run]: M5 permissions spike run
[^apple-forum]: Apple Developer Forums: User TCC DB inaccessible for CI setups
[^runner-tcc]: runner-images configure-tccdb-macos.sh
[^runner-tcc-27]: runner-images configure-tccdb-macos-27.sh
