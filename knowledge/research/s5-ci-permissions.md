---
type: Analysis
title: "S5: granting permissions on GitHub's hosted macOS runners"
description: The runner images pre-grant Accessibility and Screen Recording to bash and the runner agent, so a helper started as a child of the job shell should inherit them; unverified until a real run.
tags: [spike, m0, ci, github-actions, permissions, tcc]
status: draft
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

# Proposed approach (unverified)

In CI, start the helper *as a child of the job's shell* (run its binary
directly, not through `open`), so macOS charges it to the already-granted
runner process. That is the opposite of the desktop rule in
[S1](/research/s1-permission-attribution.md), so the CLI needs an explicit
opt-in for it (for example `MACOS_HARNESS_LAUNCH=child`).

# Verify

On the first CI run in the GitHub repo (M4 or M5), add a step that starts the
helper this way and runs `macos-harness doctor`. If permissions don't show up,
fall back to a self-hosted Mac or the VM mode (M7).

[^apple-forum]: Apple Developer Forums: User TCC DB inaccessible for CI setups
[^runner-tcc]: runner-images configure-tccdb-macos.sh
[^runner-tcc-27]: runner-images configure-tccdb-macos-27.sh
