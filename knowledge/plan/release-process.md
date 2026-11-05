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

0. Validate locally, since CI doesn't cover everything: it has no iOS job
   (dropped on 4 November 2026 as too slow, after failing on GitHub's loaded
   runners, [#35](https://github.com/TheRogue76/macos-harness/issues/35)),
   and its Android job runs on Linux and doesn't block. Every PR also gets
   `flows/ios` run locally before it's merged (see AGENTS.md). With the dev helper installed from the release commit:
   `swift build && swift test`; `flow run flows/fixture flows/apps flows/mac
   flows/catalyst`; `flows/ios` on a simulator created for the run; and
   `flows/android` on an emulator created for the run. The owner asked for
   this before every commit and release (2026-10-15).
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
  build of **Otto.app** only (no fixture), minimum macOS 15.0. The
  helper and the CLI inside it are signed with hardened runtime and a
  secure timestamp, using the Developer ID certificate that expires last
  (`scripts/pick-identity.py`; the keychain holds two with the same
  name).[^roadmap] No entitlements are needed. Each signature is tried up
  to five times: on 17 October 2026 Apple's timestamp server failed about
  half the requests from the owner's network ("A timestamp was expected but
  was not found").
- Zips the app with `ditto`, submits it with `xcrun notarytool submit
  --keychain-profile macos-harness-notary --wait`, staples the ticket to the
  app, checks it with `spctl`, and zips it again
  (`Otto-<version>.zip`). Submitting and stapling are tried up to
  five times too, since both also failed to reach Apple that day
  (`connectTimeout`, stapler error 68). Publishing isn't retried: if a step
  after the tag fails, finish the rest by hand with the zip in
  `.build/apps/release`.
- With `--publish`: tags `v<version>`, creates the GitHub release with the
  zip, fills `packaging/otto-harness.rb` with the cask's name, the version
  and SHA-256, and pushes it to `TheRogue76/homebrew-tap`. A pre-release
  (`--prerelease`) only updates `Casks/otto-harness@rc.rb`, so people who
  installed `otto-harness` don't get it on `brew upgrade`; testers opt in
  with `brew install --cask therogue76/tap/otto-harness@rc`. A release
  updates both casks, moving RC testers to it. Each cask conflicts with the
  other. They don't name the casks before 2.0 (`macos-harness`,
  `macos-harness@rc`): `brew upgrade` of a renamed cask installs its
  successor while the old one is still in the Caskroom, so a conflict with
  it refused the very upgrade the rename asks for (2.0.0, 6 November 2026;
  the tap was patched the same day). From 2.0 the script also removes a cask
  before 2.0 when it publishes its successor and records the move in the
  tap's `cask_renames.json` (`macos-harness@rc` with the first 2.0
  pre-release, `macos-harness` with 2.0.0), so `brew upgrade` moves its
  users across. It then waits for the Linux packages workflow and fills
  `packaging/otto-harness-formula.rb` with the tarballs' SHA-256s as
  `Formula/otto-harness@rc.rb`, or on a release both formulas; if that
  fails, the casks are still pushed and the script says the formulas
  weren't. Homebrew 7 refuses casks and formulas from untrusted taps, so
  users run `brew trust therogue76/tap` first, as the install docs say.
- Publishing the GitHub release also runs the **Linux packages** workflow
  (`.github/workflows/linux-packages.yml`), which builds
  `otto-harness` for x86_64 and arm64 on Ubuntu 24.04
  (`scripts/package-linux.sh --packages`: a `.deb`, an `.rpm` and a
  tarball with `install.sh`), installs them in Ubuntu 24.04, Debian 13,
  Fedora 44 and Arch containers, and attaches them to the release. It runs
  on pull requests that change the packaging too, without attaching
  anything.

# Checking a published release

The **Release check** workflow (`.github/workflows/release-check.yml`, run
by hand with the cask to try) installs the published cask on fresh GitHub
runners (macOS 15 and 26, Apple silicon and Intel), as a user would, and
runs `doctor`, `setup`, the app and Mac app flows and `doctor --report`
with the installed CLI and helper. It stands in for clean machines;
macOS 27 has no hosted runner, so that's the owner's Mac.

The notary profile holds the owner's app-specific password in their
keychain; it was stored by the owner with `xcrun notarytool
store-credentials`, never by an agent.

# What users get

`brew install --cask therogue76/tap/macos-harness` puts **Otto.app** in
`/Applications` and links `otto`, and `macos-harness` as another name for
it, into Homebrew's `bin`. The CLI resolves that symlink to find its app.
Upgrades quit the helper first (`uninstall quit:`); permissions survive
because they're tied to the bundle ID and team. `brew uninstall --zap` also
removes the policy, journal, socket folder and preferences.

The release app (`io.github.therogue76.macos-harness`) and the dev build
(`….dev`) are separate apps with separate permissions, pairings, sockets and
journals, and separate CLIs (`otto`, `otto-dev`), so both
can be installed at once.

[^roadmap]: Roadmap, M4 decisions
