---
type: Analysis
title: M5 acceptance run
description: A Claude Code session exported from the journal replays green, and CI runs the fixture, app and replayed-session flows on every push; tiers B, C and D pass locally. Findings cover CI screens, SwiftUI scrolling, scroll-area visibility, guards for teardown, journal sessions and local network prompts.
tags: [m5, acceptance, flows, ci, findings]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-07T01:50:00Z }
verified: { by: claude-code/claude-opus-5-5, at: 2026-10-07T01:45:00Z }
stale_after: 2027-10-07T00:00:00Z
sources:
  - id: run
    resource: "flow runs on macOS 27.2 and GitHub's macos-15 runner, 2026-10-07"
    title: M5 acceptance output
    author: claude-code/claude-opus-5-5
---

# Results

| Check | Result |
|---|---|
| A recorded agent session replays | Claude Code (normal model, MCP, dev build) pressed Increment three times, set the name and turned on the toggle. `flow export` produced the steps with selectors by identifier and the name as `${text_1}`; with the text filled in and three `expect` steps added, it replays green in 3.1 s and in CI[^run] |
| CI runs flows on every push | `UI flows` workflow: fixture basics, fixture pointer (real input), the recorded session and Calculator, 4 passed |
| Tier B | Notes (12.3 s), Reminders (11.3 s), Calendar (14.2 s): create the test area, create, edit and delete an item, remove the area |
| Tier C | Safari opens a local file in a private window, fills a field, checks the result (7.8 s); closes only its window |
| Tier D | Mail, Messages and FaceTime are read under a read-only policy, and a minimize is refused in each. On this Mac user none of the three is signed in, so there was no personal data to read |
| Recording | `--record failures` keeps a movie of the app with the failure artifacts; `record frames` extracts stills |

# Findings

1. **Hosted runners give a child helper their permissions**; the S5 plan
   works (see [S5](/research/s5-ci-permissions.md)). CI also needs
   pairing without a person, hence `MACOS_HARNESS_AUTO_APPROVE`.
2. **CI screens are small.** On the runner the Dock covered the fixture's
   lower half and the 900 pt window ran past the bottom of the screen. The
   real-input guard refused both correctly ("covered by Dock", "isn't on
   any screen"). CI now hides the Dock, and the fixture is 620 pt tall.
3. **SwiftUI scroll areas can't be scrolled through accessibility.** No
   `AXScrollToVisible` on their content and no scroll bars in the AX tree.
   Pointer actions now scroll the innermost scroll area that hides the
   target with the real wheel, then find the element again; `scroll-to`
   explains when it can't.
4. **Visibility ignored the scroll areas around a single element.** When
   re-checking one element, only the window clipped it, so an element
   scrolled out of its area could look clickable and the click would land
   on whatever covered that spot. Visibility now intersects every
   enclosing scroll area.
5. **Positions go stale.** A drag's destination was measured before the
   source was scrolled into view. Pointer actions now re-read each
   element's position inside the session.
6. **Teardown needs guards, not just order.** A teardown `expect` meant as
   a guard failed but the next step (close the window) ran anyway, because
   teardown runs every step. It closed the test's own window, but that was
   luck. `only_if` now makes a step conditional, and `quit: { if_launched:
   true }` leaves apps the user had open.
7. **A local web server triggers macOS's local network prompt** ("Allow
   Python to find devices on local networks?") even bound to 127.0.0.1, and
   the prompt blocks real input until someone answers. The Safari suite now
   opens a `file://` page instead.
8. **Relative paths make bad URLs.** `${flow_dir}` was relative, so
   `file://flows/…` read "flows" as a host. It's absolute now.
9. **One agent, several runs.** The journal grouped sessions by agent
   identity, so a `claude -p` run and this Claude Code session merged into
   one session. Sessions are now per agent process.
10. **Messages and FaceTime ignore a quit request** at their sign-in
    screens; they had to be force-quit (they held no data).
11. **`find` never matched windows**, so a flow couldn't check a window's
    title. It does now when the selector asks for `role: window`.

[^run]: M5 acceptance output
