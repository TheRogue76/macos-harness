---
type: Plan
title: Release process
description: How a version is built, signed, notarized, published to GitHub Releases and the Homebrew tap, and what a user's install looks like.
tags: [release, signing, notarization, homebrew, m4]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-06T21:30:00Z }
sources:
  - id: roadmap
    resource: /plan/roadmap.md
    title: Roadmap, M4 decisions
---

# Cutting a release

1. Bump `HarnessVersion.string` and add a `## <version>` section to
   `CHANGELOG.md` (it becomes the release notes).
2. Commit and push `main`; wait for CI.
3. `scripts/release.sh --publish` (add `--prerelease` to publish as a
   pre-release first). Without `--publish` it stops after notarizing, which
   is a safe dry run.

The script refuses to publish from a dirty tree, from a branch other than
`main`, when `main` isn't pushed, or when the tag exists.

# What the script does

- `scripts/build-app.sh release`: a universal (arm64 + x86_64) release
  build of **macOS Harness.app** only (no fixture), minimum macOS 15.0. The
  helper and the CLI inside it are signed with hardened runtime and a
  secure timestamp, using the Developer ID certificate that expires last
  (`scripts/pick-identity.py`; the keychain holds two with the same
  name).[^roadmap] No entitlements are needed.
- Zips the app with `ditto`, submits it with `xcrun notarytool submit
  --keychain-profile macos-harness-notary --wait`, staples the ticket to the
  app, checks it with `spctl`, and zips it again
  (`macOS-Harness-<version>.zip`).
- With `--publish`: tags `v<version>`, creates the GitHub release with the
  zip, fills `packaging/macos-harness.rb` with the version and SHA-256, and
  pushes it to `Casks/macos-harness.rb` in `TheRogue76/homebrew-tap`.

The notary profile holds the owner's app-specific password in their
keychain; it was stored by the owner with `xcrun notarytool
store-credentials`, never by an agent.

# What users get

`brew install --cask therogue76/tap/macos-harness` puts **macOS
Harness.app** in `/Applications` and links `macos-harness` into Homebrew's
`bin`. The CLI resolves that symlink to find its app. Upgrades quit the
helper first (`uninstall quit:`); permissions survive because they're tied
to the bundle ID and team. `brew uninstall --zap` also removes the policy,
journal, socket folder and preferences.

The release app (`io.github.therogue76.macos-harness`) and the dev build
(`….dev`) are separate apps with separate permissions, pairings, sockets and
journals, and separate CLIs (`macos-harness`, `macos-harness-dev`), so both
can be installed at once.

[^roadmap]: Roadmap, M4 decisions
