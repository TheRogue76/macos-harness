---
type: Plan
title: Otto (2.0)
description: Finishing the Mac work in flight as 1.2.0, then renaming macos-harness to Otto as 2.0.0, with Linux shipping under the new name; what changes, what keeps working, and how users move across.
tags: [plan, rename, otto, release, branding]
status: draft
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-05T00:30:00Z }
sources:
  - id: owner
    resource: conversation with human:parsa.nasirimehr, 2026-11-04 and 05
    title: The owner's decisions on the name, the order of releases and the logo
  - id: macSession
    resource: report from the owner's macOS Claude session, 2026-11-05
    title: What the Mac side has in flight, and what a rename means for TCC, defaults, setup and Homebrew
---

# Goal

Rename the product from macos-harness to **Otto** once it runs on more than
the Mac, without breaking anyone who already uses it. The name refers to
Otto Octavius, whose mechanical arms are driven by his mind; the harness
gives an agent arms that reach into apps, and its guard rails play the part
of his inhibitor chip. It also sounds like "auto".[^owner]

# Order

1. **1.2.0 (Mac)**: finish and release the Mac work in flight, under the old
   name. Linux keeps building from source only.
2. **2.0.0**: the rename, with Linux packaged and released for the first
   time as Otto (L7 and L8 of the [Linux plan](/plan/linux.md) move here,
   since packages and paths are named once).

Nothing in the rename starts before 1.2.0 is out, so the Mac fixes ship
without waiting for it, and the rename lands on a quiet `main`.

# 1.2.0 (Mac)

What the Mac session has in flight, in the order it's fixing them, all
from an agent's feedback on driving Chrome:[^macSession]

- Nearly done: [#114](https://github.com/TheRogue76/macos-harness/pull/114)
  (Chrome's page tree, #103),
  [#115](https://github.com/TheRogue76/macos-harness/pull/115)
  (`wait --ocr` keeps its timeout and says what it last read, #104), and
  #105 (paste in steps).
- Worth including: #106 (typing drops characters the layout doesn't
  produce), #113 (menu bar extras hidden behind macOS's «, which fails the
  fixture flow on any Mac with a full menu bar), #107 and #108.
- If there's time: #109 to #112.
- Deferred unless someone hits them: #51 and #54 (the 1.0.1 milestone); #54
  may get a notice.

Done when the chosen issues are closed and 1.2.0 is released through the
[release process](/plan/release-process.md).

# Names in 2.0

| What | Now | In 2.0 |
|---|---|---|
| Product | macOS Harness | Otto |
| Command | `macos-harness`, `macos-harness-dev` | `otto`, `otto-dev` |
| Packages, repository, Homebrew | `macos-harness` | `otto-harness` |
| MCP server (`setup`) | `macos-harness` (tools `mcp__macos-harness__*`) | `otto` |
| Environment variables | `MACOS_HARNESS_*` | `OTTO_*` |
| Mac app | `macOS Harness.app` | `Otto.app` |
| Mac bundle ID | `io.github.therogue76.macos-harness` | unchanged (below) |
| Linux app IDs | `io.github.therogue76.MacosHarness…` | `io.github.therogue76.Otto…` |
| GNOME extension | `macos-harness@therogue76.github.io`, bus `org.gnome.Shell.Extensions.MacosHarness` | `otto@therogue76.github.io`, `org.gnome.Shell.Extensions.Otto` |
| Folders | `…/macos-harness/` (Application Support, Logs, `~/.config`, `$XDG_RUNTIME_DIR`, `~/.local/state`) | `…/otto/` |

`otto` and `otto-harness` were checked on 2026-11-05: no package in Debian
sid, Arch or the AUR ships an `otto` command, and Homebrew, Fedora 45 and
extensions.gnome.org have nothing by either name. `otto` is taken on npm,
PyPI and crates.io by unrelated, mostly dormant projects; `otto-harness` is
free everywhere. Fedora's files weren't searchable, so the release check
matrix confirms `/usr/bin/otto` is free there.

# What keeps working

Under the [interface contract](/design/interface-contract.md), renames keep
the old name as a hidden alias, here through all of 2.x:

- **The command.** A `macos-harness` link to `otto` (and `-dev`), so agent
  setups with the old absolute path, scripts and skills keep running.
- **The MCP server.** `setup` replaces a `macos-harness` entry with `otto`
  in each agent host it knows, and says so; the helper answers either
  name. Agents' permission allowlists and skills name
  `mcp__macos-harness__*` tools, so the upgrade notes say what to change.
- **Environment variables.** Every `MACOS_HARNESS_*` is read when its
  `OTTO_*` isn't set.
- **Files.** On first start, the helper moves the policy file, the journal,
  the logs and the state folders from the old paths to the new ones, or
  reads the old ones when it can't move them. Sockets are made fresh.

# The Mac app

TCC (Accessibility, Screen Recording) and `UserDefaults` follow the bundle
ID and the signing team, not the app's name. A new bundle ID would be a new
app: every user grants both permissions again, pairings, settings and stops
are lost unless migrated, the Start at login item goes stale, and the old
entries linger in System Settings.[^macSession] So 2.x keeps
`io.github.therogue76.macos-harness` (and `.dev`) and changes only the
app's name, its icon and the executables inside. The helper's own-process
check (`signingIdentifierPrefix`) and the log subsystem follow the bundle
ID, so they don't change either. The plan checks that a renamed app keeps
its grants and its login item on a real Mac before release.

# Homebrew

In `TheRogue76/homebrew-tap`: casks `otto-harness` and `otto-harness@rc`
from a renamed `packaging/` template, a `cask_renames.json` so
`brew upgrade` moves `macos-harness` users across, updated
`conflicts_with` pairs, the uninstall step quitting the same bundle ID, the
zap list for the new and old folders and the preferences plist, the
caveats, and the release check's cask input. Linux gets a formula of the
same name in L7.

# Branding

A new mark replaces the Control Tower glyph: a head with four arms, one of
them orange and holding the pointer from today's tray icon, on the same
dark tile and in the same line style as today's icon, plus a wordmark,
`otto` with the last "o" orange. It keeps clear of Marvel's artwork and of
the name Doctor Octopus.[^owner] The owner picks from the drafts, and the
picked mark is drawn by `scripts/render-icon.swift` for the Mac, as an SVG
for the Linux tray, top bar and app icon, and for the docs.

# Steps for 2.0

One PR each, on `main` after 1.2.0:

1. Names in one place: product, command, package, MCP server, prefixes and
   app IDs in `HarnessPaths`/`HarnessProduct`, with the legacy names beside
   them.
2. Folder and environment migration, with tests.
3. The command, the alias links, `setup`'s MCP migration, and the helper
   answering both server names.
4. The Mac app's name, icon and build scripts (`build-app.sh`,
   `release.sh`).
5. Linux: app IDs, D-Bus names, the GNOME extension's new ID (published on
   extensions.gnome.org, the old one removed), the KWin script names,
   systemd units and autostart entry, and their migration.
6. Docs, `docs/reference`, the skill and the knowledge.
7. L7 packaging and the release check matrix, as `otto-harness`.
8. The GitHub repository renamed to `otto-harness` (GitHub redirects the
   old URLs), the Homebrew tap, then L8 and a release candidate.

# Open decisions for the owner

- The logo, from the drafts.
- Whether the Mac bundle ID stays (recommended) or changes, with a
  re-grant step, in a later major version.
- The Homebrew cask's name: `otto-harness` (recommended, matches the
  packages) or `otto`.
- Whether Linux ships in 2.0.0 or follows in a 2.x.

[^owner]: Owner's decisions in conversation, 2026-11-04 and 05: the name,
    1.2.0 before the rename, 2.0.0 for it, and a logo for Otto.
[^macSession]: The Mac session's report of 2026-11-05 on work in flight
    and on what a rename means on macOS; its TCC and Start at login points
    are general macOS behaviour, not yet tested on a renamed app.
