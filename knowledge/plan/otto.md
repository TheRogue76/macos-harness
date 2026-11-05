---
type: Plan
title: Otto (2.0)
description: Finishing the Mac work in flight as 1.2.0 and 1.3.0, then renaming macos-harness to Otto as 2.0.0, whose headline is Linux, complete; what changes, what keeps working, and how users move across.
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
2. **1.3.0 (Mac)**: the rest of the agent's Chrome feedback, added by the
   owner on 5 November 2026, also under the old name.[^owner]
3. **2.0.0**: the rename, and Linux as *the* feature of the release: packaged
   and released for the first time as Otto, and fully functional, with
   every command and tool that can work on a Linux desktop working there
   (L7 and L8 of the [Linux plan](/plan/linux.md) move here, since packages
   and paths are named once).[^owner]

Nothing in the rename starts before 1.3.0 is out, so the Mac fixes ship
without waiting for it, and the rename lands on a quiet `main`.

# 1.2.0 (Mac)

Released on 5 November 2026 with #103 to #113 fixed (#106 by a check and a
notice, since the dropped character didn't reproduce); #51 and #54 stay
deferred. The plan was:[^macSession]

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

# 1.3.0 (Mac)

Released on 5 November 2026 with #135 to #141 fixed: Chrome's page tree
switching off again, `key` with unknown focus, background clicks judged
after drawing, pauses and `dx`/`dy` in steps, page-only text matches in
browsers, screenshots in window points with a pointer `scale`, and `tabs`.
#51 and #54 stay deferred.

# Names in 2.0

| What | Now | In 2.0 |
|---|---|---|
| Product | macOS Harness | Otto |
| Command | `macos-harness`, `macos-harness-dev` | `otto`, `otto-dev` |
| Packages, repository, Homebrew cask and formula | `macos-harness` | `otto-harness` |
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
`io.github.therogue76.macos-harness` (and `.dev`), which also lets 1.x
installs update in place, and changes only the app's name, its icon and the
executables inside.[^owner] The helper's own-process
check (`signingIdentifierPrefix`) and the log subsystem follow the bundle
ID, so they don't change either. The plan checks that a renamed app keeps
its grants and its login item on a real Mac before release.

# Homebrew

`otto-harness` is the cask's name (the owner's choice; free in Homebrew's
core, its cask list and the harness's own tap on 2026-11-05). In
`TheRogue76/homebrew-tap`: casks `otto-harness` and `otto-harness@rc`
from a renamed `packaging/` template, a `cask_renames.json` so
`brew upgrade` moves `macos-harness` users across, updated
`conflicts_with` pairs, the uninstall step quitting the same bundle ID, the
zap list for the new and old folders and the preferences plist, the
caveats, and the release check's cask input. Linux gets a formula of the
same name in L7.

# Branding

The owner picked "G1 · Pincers" on 2026-11-05, from rounds the Mac session
designed in Claude Design: the agent's terminal (`>_`, the `>` orange) as a
head over four jellyfish arms that keep their thickness, show faint segment
lines and end in round two-finger pincers with an orange light in each hub.
The owner steered it towards a happy helper robot, away from anything
menacing; it keeps clear of Marvel's artwork, likeness and the name Doctor
Octopus.[^owner] The sources are in `Resources/branding/otto/`:

- `otto-icon.svg`, the app icon on a 64-unit grid (tile `rx` 13.5, #1A1A1A
  with an 8% white hairline; strokes #F4F4F4, accent #FF450F). The segment
  lines are each arm drawn again in the tile's colour with a dash pattern,
  so the icon only works on its own dark tile. It reads at 16 and 32 px
  without a separate small drawing.
- `otto-symbolic.svg`, the one-colour glyph for menu and tray bars on an
  18-unit grid, without segment lines: #bebebe for Linux's symbolic icons
  (GNOME and KDE recolour it), #000000 for the macOS template image,
  #FFFFFF for a white version.
- `otto-wordmark-on-light.svg` and `-on-dark.svg`, a monoline `otto` (stroke
  5, round caps) with orange crossbars on the t's; and the two lockups
  (`viewBox 0 0 184 64`, the wordmark at `translate(78 4)`).

In 2.0, `scripts/render-icon.swift` draws the Mac icon from it, the Linux
tray, top bar, panel and app icon use the SVGs, and the docs take the
lockup.

# Linux complete

2.0.0 ships Linux fully functional on GNOME, KDE and Sway. Before packaging,
an audit of every command and MCP tool against Linux desktop apps closes
what's left. Known gaps on 2026-11-05:

- `window` (activate, move, resize, minimize, restore, full screen, close)
  is refused on desktop apps.
- Text recognition (`--ocr` in `find`, `wait` and `press`) is refused, with
  a message saying screenshots aren't supported, which is no longer true.
- Messages that predate real input still say keys and paste aren't there
  (`realInputLater`), and the helper's doc comment says desktop apps aren't
  supported.
- The driving panel's "is waiting" line, and the marker following a window
  that moves while it shows.

Commands that need macOS by nature (`sim`, `build`) say so; everything else
works, or the audit says why it can't. Acceptance runs on GNOME, KDE and
Sway (L8) close it.

# Steps for 2.0

One PR each, on `main` after 1.2.0; the Linux gaps can start before it,
since they don't depend on the name:

1. Names in one place: product, command, package, MCP server, prefixes and
   app IDs in `HarnessPaths`/`HarnessProduct`, with the legacy names beside
   them. Done on 2026-11-05, still with the old values: every name in
   `Sources/` comes from `HarnessProduct` (`displayName`, `commandName`,
   `helperName`, `towerName`, `folderName`, `packageName`, `mcpServerName`,
   `environmentPrefix` with `environmentVariable(_:)`, `linuxAppID`,
   `linuxObjectPath`, `linuxIconName`, `gnomeExtensionUUID`,
   `gnomeExtensionBusName`, `gnomeExtensionObjectPath`), and
   `HarnessVariant` derives the dev names and `linuxAppID` from them. The
   bundle IDs, `signingIdentifierPrefix` and the Mac log subsystem stay
   literal, since they don't change. The legacy names arrive with step 2.
2. Folder and environment migration, with tests. Done on 2026-11-05:
   `folderName` is `otto` and `environmentPrefix` is `OTTO_`, beside
   `legacyFolderName` and `legacyEnvironmentPrefix`. At start, both
   helpers call `HarnessPaths.migrateLegacyFolders()`, which renames each
   old folder (`~/.config`, Logs or `$XDG_STATE_HOME`, Application Support
   or `$XDG_RUNTIME_DIR`) to the new name when the new one doesn't exist yet,
   and leaves it otherwise; the policy store reads the old policy file while
   there's none at the new path. Every read goes through
   `HarnessProduct.environmentValue(_:in:)`, which takes `OTTO_<name>` and
   falls back to `MACOS_HARNESS_<name>`; what the harness sets for the
   processes it starts uses the new names only. The systemd socket unit
   listens in the new folder; CI and the scripts still set the old
   variables, which keep working.
3. The command, the alias links, `setup`'s MCP migration, and the helper
   answering both server names. Done on 2026-11-05: `commandName` is
   `otto` (`otto-dev` for the dev build) and the SwiftPM product is `otto`,
   beside `legacyCommandName`; `build-app.sh` bundles `Contents/MacOS/otto`
   and links `otto-dev` and `macos-harness-dev`, and the cask template
   links `otto` and `macos-harness`. `mcpServerName` is `otto`, beside
   `legacyMCPServerName`: `setup` registers `otto` in each host and removes
   a `macos-harness` entry that runs this product's CLI, saying "Replaced
   the macos-harness server with otto in …"; the server reports `otto`, and
   nothing in it depends on the name a host gives it. The helper, the
   Linux tower, the tray icon's ID, the KWin scripts and the skill keep
   their old names until steps 4 to 6 ([why](/research/implementation-notes.md)).
   CI runs the CLI as `otto`, and its `doctor` also through a
   `macos-harness` link on the Mac and in the Linux build job; the
   Linux desktop job sets `OTTO_*` while the others keep the old variables.
4. The Mac app's name, icon and build scripts (`build-app.sh`,
   `release.sh`).
5. Linux: app IDs, D-Bus names, the GNOME extension's new ID (published on
   extensions.gnome.org, the old one removed), the KWin script names,
   systemd units and autostart entry, and their migration.
6. Docs, `docs/reference`, the skill and the knowledge, with Linux in the
   guides.
7. L7 packaging and the release check matrix, as `otto-harness`.
8. The GitHub repository renamed to `otto-harness` (GitHub redirects the
   old URLs), the Homebrew tap, then L8 and a release candidate.

# Decisions

Decided by the owner on 2026-11-05: the Mac bundle ID stays, so 1.x installs
update in place; the cask is `otto-harness`; Linux is the headline of
2.0.0 and ships fully functional in it.[^owner]

Still open: the logo. The owner's Mac session designs it in Claude Design
and the owner picks; the result replaces the placeholder description under
Branding.

[^owner]: Owner's decisions in conversation, 2026-11-04 and 05: the name,
    1.2.0 before the rename, 2.0.0 for it with Linux as its headline and
    fully functional, keeping the Mac bundle ID so updates work, the cask
    `otto-harness`, and a logo for Otto designed by the Mac session.
[^macSession]: The Mac session's report of 2026-11-05 on work in flight
    and on what a rename means on macOS; its TCC and Start at login points
    are general macOS behaviour, not yet tested on a renamed app.
