---
type: Design
title: "Helper UI: Control Tower"
description: The chosen menu bar design (direction B, refined in October 2026) in light and dark, what each surface shows, the settings page, and the rules behind sessions, stopping, pairing, settings and the on-screen window marker.
tags: [design, ui, menu-bar, pairing, overlay, safety, settings]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-06T19:10:00Z }
sources:
  - id: canvas
    resource: https://claude.ai/artifact/DHWJYPmsrDZHX8coX8myyZ
    title: macOS Harness UI directions (design canvas, private)
    author: claude-code/claude-opus-5-5
  - id: choice
    resource: Design review with human:parsa.nasirimehr, 2026-10-06
    title: Owner's pick of direction B, light and dark
    author: human:parsa.nasirimehr
  - id: refresh
    resource: https://claude.ai/artifact/6JYfMGVngHSUDSbuHUthAn
    title: macOS Harness UI refresh (design canvas, private)
    author: claude-code/claude-opus-5-5
  - id: refreshChoice
    resource: Design review with human:parsa.nasirimehr, 2026-10-10
    title: Owner's pick of direction 1, Control Tower refined
    author: human:parsa.nasirimehr
  - id: settingsIssue
    resource: https://github.com/TheRogue76/macos-harness/issues/27
    title: "Control Tower settings (#27)"
    author: human:parsa.nasirimehr
---

# Decision

Three directions were drawn: A Quiet Native, B Control Tower and C Co-pilot
Island.[^canvas] The owner chose **B**, in both light and dark.[^choice] The
helper follows the system appearance.

In October 2026 the owner asked for a refresh after three complaints: the
gear wasn't centered, the window outline didn't line up with the window, and
it was drawn over whatever the user was looking at when the agent's window
was behind it or on another Space. A second canvas drew four directions
(Control Tower refined, Beacon, Ledger, Modules);[^refresh] the owner picked
**Control Tower, refined**.[^refreshChoice]

One rule across everything: **orange means an agent is in control**. Blue
stays the system's "you".

The settings page ([#27](https://github.com/TheRogue76/macos-harness/issues/27))[^settingsIssue]
was drawn in the same language in October 2026 and hasn't had a design
review with the owner yet.

# Surfaces

| Surface | What it shows |
|---|---|
| Menu bar icon | Template glyph (window with a cursor). An orange dot appears when agents are active or stopped, a pairing request waits, or a permission is missing |
| Panel (click the icon) | Header: the app mark, the name, an `Idle` / `● N driving` / `Stopped` pill and a 28 pt gear button (settings, set up permissions, edit policy, show journal, restart, quit). Session cards: window thumbnail (orange ring while the agent acted in the last 10 s), `agent in app`, last step, `now · step N · mm:ss` or `38 s ago · …`, Stop or Resume. Rows for stopped agents that are idle. A readiness line (`Screen Recording and Accessibility are on` and the paired count); chips that open setup only while a permission is missing. The last 5 activities under a divider. Summaries leave element refs out. `Stop all agents ⌃⌥⌘.`, or `Resume all agents` while stopped |
| Settings (inside the panel, from the gear menu) | A 28 pt back button and `Settings`, then sections on cards: **Input** (Clicks and scrolls in the background); **On screen** (Window outline; Also when agents read, dimmed while the outline is off; Driving panel and click ripple) with a note that these change only what the user sees; **Recent activity** (how many entries, and Clear); **Paired agents** (monogram, name, `Allowed 6 Oct · team <ID>` or `· not signed`, with the year only when it isn't this one so the team ID fits, and Revoke; the list scrolls past five). Settings use native small switches in the system accent: they're the user's own controls, so blue, not orange |
| Pairing card (inside the panel, opens by itself) | Monogram, name and the session's folder, "Signed by <organization> · team <ID>" (or a warning when unsigned), what an allowed agent can do, a "Started from" chain ending in the command, then Deny / This session only / Allow |
| Setup window | Progress ring, a card per permission with a picture of its switch, "Open System Settings", a restart note while Screen Recording is off, and Done once both are on. Opens at launch when a permission is missing |
| Window marker | A 2 pt orange ring just outside the edge of the window an agent read, captured or acted in, with the window's own corner radius and a soft glow, and a tab on its top edge (`Codex · pressed button “Save” · step 14`; inside the title bar, clear of its buttons, when there's no room above). Fades after ~1.6 s; never on our own windows; can be switched off in Settings, for reads alone or altogether |
| Ripple and HUD | A ripple where an agent clicks or presses, left out when another window covers that point, and a "<agent> is driving" panel with Pause and Stop, both for M2 and M3 actions; one switch in Settings turns both off |
| App icon | The Control Tower mark, rendered by `scripts/render-icon.swift` |

# Rules

- **Sessions.** One agent process's run of activity; it ends after 120 s of
  quiet. Two sessions of the same agent get separate cards, named by their
  folders (see [several agents](/design/several-agents.md)).
  A card gets an orange edge while the agent acted in the last 10 s.
  `hello` and `doctor` aren't activity.
- **Stop.** Per agent from its card, or everyone with Stop all or ⌃⌥⌘. (a
  Carbon hotkey, so it needs no Input Monitoring). Stopped agents' gated
  calls fail with error 1004 and a message telling them to ask the user.
  `hello` and `doctor` still answer and report `stopped`. **Only the user
  resumes**; no command can. Stops are saved in the helper's defaults, so a
  helper restart doesn't clear them.
- **This session only.** The approval lasts while the agent process that
  asked keeps running (its pid, from the process chain), then lapses, and
  covers only that process.
- **Our own UI is never highlighted**, which avoids feedback loops when an
  agent inspects the helper.
- **Settings.** Kept in the helper's defaults (`backgroundRoute`,
  `showWindowOutline`, `showActivityOnScreen` for reads, which predates the
  page, and `showDrivingPanel`), all on until the user turns them off, so
  the dev and release helpers each have their own. `doctor` reports them.
  **Only the user changes them**: there's no command or tool for it, so an
  agent can't hide its outline or the driving panel (one with a shell could
  still write the defaults, as it could edit the policy file).
- **Background route off.** `pointer` clicks and scrolls, and `press` on an
  element without an AX action, go straight to the real mouse as `--real`
  would, with its guard rails, and say so in a `backgroundOff` notice. The
  notice only appears where the route would have been tried (a window on
  the current Space, with the private calls present). Keys aren't affected.
- **What's drawn is only drawn.** Turning off the outline or the driving
  panel and ripple changes nothing an agent can do; the stop hotkey and the
  panel's Stop still work. With the ripple off, real input doesn't pause
  the 180 ms it otherwise waits so the ripple shows first.
- **Clear and Revoke.** Clear empties the panel's recent list only; active
  sessions and the journal stay. Revoke removes a stored pairing and that
  agent's "This session only" approvals, so its next gated call asks again.
- **The panel opens on the dashboard** whenever it's shown again after
  closing, even if it closed on the settings.
- **The marker belongs to its window.** It sits at the normal window level,
  ordered directly above the agent's window, so whatever is in front of that
  window covers the ring and tab too. Every 100 ms it rereads the window
  from the window server: it follows moves and resizes, reorders itself if
  the window comes forward, cuts out what covers the window, and hides while
  the window is minimized, hidden or on another Space. The corner radius is
  measured once per window from a capture of its corner (16 pt until then).

# Linux

The owner asked for the macOS experience as closely as Linux allows. The
helper stays headless and serves the tray icon itself over D-Bus
(`TrayIcon`: StatusNotifierItem for the icon, DBusMenu for its menu); the
windows (the panel, pairing card, settings and setup) come from a separate
GTK 4 and libadwaita app the helper starts, so a UI crash can't take the
helper down and servers and CI need no GTK.

- **Tray icon.** The macOS glyph drawn as an SVG, symbolic so the panel
  recolours it, and the same orange dot (#FF450F) under the same rules:
  agents active or stopped, a pairing request waiting, or a permission
  missing. Until the panel exists, clicking it opens a menu: the state
  (`Idle`, `● N driving`, `Stopped`), each session with its last step,
  idle stopped agents, Resume all agents, Stop all agents with its
  shortcut, Set up permissions… while one is missing, Show journal, and
  Quit. KDE, Sway's bars and Ubuntu's GNOME (its AppIndicator extension)
  show it; plain GNOME needs that extension. Once the panel app is
  installed next to the helper, a click opens the panel and the menu moves
  to a right-click.
- **Top-bar icon on GNOME.** Ubuntu's AppIndicator extension opens a
  tray icon's menu on a single click and calls `Activate` only on a double
  click, so a tray icon there can't open the panel the way the Mac's
  menu bar icon does. The harness's own Shell extension (version 3) draws
  the icon in the top bar instead (`ShowIcon(title, attention)`, the
  glyph with an orange dot), removes it when the helper's bus name goes,
  and emits `IconClicked(x, y)` with the icon's bottom middle, where the
  panel is placed. It works on any GNOME, with or without AppIndicator
  support. KDE and Sway keep the StatusNotifierItem, where a left click
  calls `Activate`.
- **Start at login.** A switch in Settings on both platforms: an XDG
  autostart entry that runs the helper on Linux
  (`~/.config/autostart/io.github.therogue76.MacosHarness.desktop`), and
  `SMAppService.mainApp` on the Mac. Off by default; packages may turn it
  on.
- **Setup window.** As the Mac's: a progress ring (`3/6`), "N more and
  you're set", and a card per permission (what it lets agents do, then ✓ On,
  ✓ Nothing to allow here, or an orange button for the desktop's own
  dialog: Install the extension…, Allow screenshots…, Allow control…, Allow
  recording…, Add the shortcut…), then Done once nothing is missing. The
  helper opens it when it starts with something missing, from the
  notification's Set up, and from the panel's Set up…; the running panel
  app opens it when the state says `showSetup`, or a new one starts with
  only it. It shows once its first state is in, so the desktop centres it
  at full size, and the cards scroll past 400 pt so it fits small screens.
- **Panel.** `macos-harness-tower`, a GTK 4 and libadwaita app in Swift,
  laid out as the Mac's: the mark, the name, the `Idle` / `● N driving` /
  `Stopped` pill and a gear; pairing cards (Deny, This session only,
  Allow); a card per session with an orange edge while it acted in the
  last 10 s, its last step, `now · step N · mm:ss` and Stop or Resume;
  stopped agents with Resume; the readiness line (`Ready · N paired
  agents`, or what's missing with Set up…); the last five activities; and
  the orange Stop all agents with the bound shortcut, or Resume all
  agents. The gear opens Settings inside the panel: General first (Start
  at login, Show journal, Quit; the last two are in the gear's menu on the
  Mac), then recent activity with Clear and paired agents with Revoke. It closes when it loses focus or
  on Escape, and a second click brings the open one forward.
- **Placing the panel.** Wayland doesn't let an app place its own window,
  so the helper does, as on the Mac the panel hangs under the icon: the
  tray's `Activate(x, y)` says where the icon was clicked, the helper waits
  for the panel's window and has the compositor move it just below that
  point (above it for a bottom panel), inside the work area: GNOME through
  the Shell extension's `PlaceNear` (version 2, which only moves windows
  whose app ID starts with `io.github.therogue76.MacosHarness`), KDE
  through a KWin script, Sway by floating it and moving it through IPC.
  The panel stays transparent until the helper says it's placed (or two
  seconds pass), so it never shows in the middle first. GNOME lists the
  panel's window before it's mapped, at 0×0, and centres it when it maps,
  undoing any earlier move, so the helper waits until the window has a
  size, places it, and places it again 200 ms later. Where the tray
  host gives no point, it goes to the top right.
- **Only the panel acts for the user.** The helper accepts `tower.state`
  and `tower.act` only from a panel process it started itself (the
  connection's peer pid, which it recorded when starting it, running the
  panel's executable) carrying the random token it gave that panel, so an
  agent can't stop, resume, pair or revoke through them. The token alone
  wouldn't do: any process of the same user can read another's
  environment from `/proc/<pid>/environ`. Making the panel non-dumpable
  would hide it, but it also hides the panel's `/proc` entries from the
  helper (so the executable check fails) and from xdg-desktop-portal (so
  libadwaita gets no colour scheme and draws light), so it isn't done; the
  pid check is what holds. The panel's
  reads aren't activity and aren't journalled.

# Colours

The organization design system's neutral greys plus its orange, as dynamic
light/dark tokens in `UI/Theme.swift`. Filled orange buttons use `#D93100`
so white text keeps a 4.5:1 contrast.

# Debug commands

Hidden `spike` commands for reviewing the UI without touching real state:
`panel`, `settings` (the panel's settings page), `setup [missing]`,
`pairing-demo` (a made-up agent; the answer is discarded), `paired-demo`
(pairs that made-up agent until it's revoked in Settings, so the list and
Revoke can be checked without touching real pairings; no real caller has
its key, since a caller's key starts with a known agent's, a terminal's, an
app bundle's or an unknown process's name), `overlay-demo <app or window ID>`, `appearance light|dark|system` (the
helper only) and `stop-all`.

`screen <x> <y> <w> <h> [name] [app…]` saves a capture of part of the screen
showing only the helper's own windows and those of the apps named, so a
check never captures what else the user has open; `corners <app>` reports
each window's measured corner radius. Both are for checking the UI against
the design. `session-demo` adds a made-up second session of the calling
agent to the panel until it goes quiet, and `turn-demo` has made-up sessions
hold and wait for the mouse and keyboard.

# Not done yet

- The HUD's Pause button and showing the HUD automatically while an agent
  acts (M2/M3).
- A Dock presence: the helper is a menu bar app with no Dock icon by
  design.

[^canvas]: macOS Harness UI directions (design canvas, private)
[^choice]: Owner's pick of direction B, light and dark
[^refresh]: macOS Harness UI refresh (design canvas, private)
[^refreshChoice]: Owner's pick of direction 1, Control Tower refined
[^settingsIssue]: Control Tower settings (#27)
