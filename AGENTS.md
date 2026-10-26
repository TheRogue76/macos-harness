# macos-harness

A harness that lets coding agents (Claude Code, Codex, pi and others) see and
operate macOS apps: the Mac counterpart of Claude's iOS Simulator tool.

Status: milestones M0 (foundations), M1 (seeing), the Control Tower UI, M2
(acting through AX, plus the MCP server), M3 (real input with guard rails),
M4 (first public release via Homebrew), M5 (flows, recording, CI), M6
(Electron, Chromium and canvas apps), M8 (iOS Simulator targets) and M9
(Android targets), M10 (several agents at once) and M11 (1.0) are built; M7
(VM mode) was dropped. 1.0.0 was released on 25 October 2026; fixes after it
go in the 1.0.1 GitHub milestone (see the [roadmap](knowledge/plan/roadmap.md)).
CLI: `doctor`, `apps`, `windows`, `snapshot`, `find`, `read`, `collect`,
`screenshot`, `menu`, `press`, `set-value`, `type`, `paste`, `key`, `focus`,
`select`, `scroll-to`, `increment`, `decrement`, `click`, `hover`, `drag`,
`scroll`, `swipe`, `long-press`, `menu-select`, `window`, `launch`, `quit`,
`wait`, `steps`, `sim`, `android`, `build`, `journal`, `clipboard`, `record`,
`flow`, `setup`, `permissions`, `mcp` (and hidden `spike`). Flows:
[format](knowledge/design/flows.md). Electron and Chromium apps, OCR:
[design](knowledge/design/chromium-and-canvas.md). iOS Simulators:
[design](knowledge/design/ios-simulator.md). Android:
[design](knowledge/design/android.md). Several agents at once:
[design](knowledge/design/several-agents.md). Permissions:
[design](knowledge/design/permissions.md). Releases:
[release process](knowledge/plan/release-process.md); policy and journal:
[design](knowledge/design/journal-and-policy.md). Actions:
[actions design](knowledge/design/actions.md). Output conventions: [snapshot format](knowledge/design/snapshot-format.md); helper UI:
[Control Tower](knowledge/design/ui-control-tower.md). Plan and next milestones:
[`knowledge/plan/`](knowledge/plan/index.md).

## Working on the code

```bash
swift build && swift test                 # build and run unit tests
scripts/build-app.sh dev --install        # install the dev helper; CLI: macos-harness-dev
macos-harness-dev doctor                  # check helper, permissions and pairing
scripts/acceptance-m1.sh                  # snapshot + screenshot every tier A app
scripts/acceptance-m2.sh                  # the four M2 tasks, no real input
scripts/acceptance-m3.sh                  # real input: fixture, Finder, stop hotkey
scripts/acceptance-m10.sh                 # several sessions: claims, turns, menus (review commands)
macos-harness-dev flow run flows/fixture flows/apps   # what CI runs
macos-harness-dev flow run flows/tier-b   # Notes, Reminders, Calendar test areas (local only)
macos-harness-dev flow run flows/spaces   # windows on a desktop that isn't showing (local only; needs a second desktop)
macos-harness-dev flow run flows/ios --var "device=macos-harness tests"   # iOS fixture on a test simulator
macos-harness-dev flow run flows/android --var device=macos_harness_tests # Android fixture on a test emulator (local only)
scripts/release.sh [--publish]            # notarized release; see the release process
python3 scripts/gen_reference.py          # regenerate docs/reference after changing commands or tools
```

- `acceptance-m3.sh` moves the user's cursor and ends by stopping every
  agent (the stop hotkey check); the user resumes from the menu bar panel.
  Don't restart the helper to clear a stop: stops are saved, and restarting
  around one is exactly what the guard rail forbids.
- Testing on the owner's Mac: Notes, Reminders and Calendar only inside a
  `macos-harness tests` folder, list or calendar you create and remove;
  Finder only in `~/macos-harness-sandbox`; Mail, Messages and FaceTime read
  only. Prefer `find` and `screenshot --element` over full snapshots of those
  apps, which show personal data. See
  [test targets](knowledge/plan/test-targets.md).
- `flows/tier-b`, `tier-c`, `tier-d` and `chromium` touch the owner's apps
  and only run locally, never in CI. Every teardown step that deletes or closes
  something needs an `only_if` guard naming what the flow created.
- iOS Simulators: test on a simulator you create (`xcrun simctl create
  "macos-harness tests" "iPhone 18 Pro"`) and delete afterwards, never on
  the owner's. Never quit Device Hub while a simulator runs: it shuts them
  all down. Device Hub only sees simulators that were running when it
  started, so boot with `macos-harness-dev sim boot`.
- Android: test on an emulator you create (`avdmanager create avd -n
  macos_harness_tests -d pixel_8` from an installed phone system image; without
  `-d` it gets a 320x640 screen that the fixture flow doesn't fit) and delete
  afterwards, never on the owner's emulators or phones. If it asks to allow
  USB debugging, or taps go nowhere while the keyboard shows, see
  [fresh test emulators](knowledge/research/fresh-test-emulators.md). The
  emulator can't run on GitHub's macOS runners. CI runs `flows/android` on
  an Ubuntu runner with KVM, through the Linux helper, as a non-blocking job.
- The CLI talks to the helper over a Unix socket in
  `~/Library/Application Support/macos-harness/`. If your sandbox blocks it
  (Codex's default one does), the CLI says so; allow that path or run outside
  the sandbox. See [agent hosts](knowledge/references/agent-hosts.md).
- The first gated command from a new agent shows a pairing prompt that the
  user must approve.
- Validate locally before every commit and release: CI's iOS job and its
  Android job (on Linux) are non-blocking, so run the unit tests, the
  fixture, app, Mac and Catalyst flows, and `flows/ios` (and `flows/android`
  when Android code changed) on a simulator or emulator you create. See the
  [release process](knowledge/plan/release-process.md).
- On Linux (see the [Linux plan](knowledge/plan/linux.md)),
  `swift build && swift test` builds and tests what runs there: the
  protocol, client, CLI, core, helper core and the headless Linux helper.
  `.build/debug/macos-harness doctor` starts that helper and talks to it;
  `snapshot`, `find`, `read`, `wait`, element actions, menus, `launch`
  and `quit` work on desktop apps through AT-SPI (try
  GNOME Calculator, not apps showing the owner's files or terminals).
  `scripts/headless-desktop.sh .build/debug/macos-harness flow run
  flows/fixture` runs the fixture flows in a private headless desktop (needs
  mutter and libgtk-4-dev), as CI does; `HEADLESS_DESKTOP_COMPOSITOR=sway`
  runs them in Sway instead, where windows, positions, screenshots and real
  input (the pointer flow) work, and `kwin_wayland` in KDE's KWin (needs
  `kwin-wayland`, `kwin-common`, `xdg-desktop-portal-kde`,
  `qml6-module-qt5compat-graphicaleffects` and PipeWire), where they work
  too. Install Swift with swiftly. Code in those
  targets builds with strict memory safety and warnings as errors, so mark
  unsafe calls with `unsafe` and check both platforms in CI.
- User guides live in `docs/`; `docs/reference` is generated and CI checks
  it. Command, option, tool and parameter names follow the
  [interface contract](knowledge/design/interface-contract.md): renames keep
  the old name as a hidden alias.

## Observable state

- Observable state uses the Observation framework only: `@Observable`
  classes, `@ObservationIgnored` for stored properties views don't need,
  `@Bindable` where a view binds to one, and `withObservationTracking` for
  code outside SwiftUI that reacts to changes. It's what runs on Linux, and
  what the GTK Control Tower will watch.
- Don't use Combine's observation: no `ObservableObject`, `@Published`,
  `@StateObject`, `@ObservedObject`, `@EnvironmentObject`,
  `.environmentObject`, `objectWillChange`, `import Combine`, publishers or
  `AnyCancellable`. CI fails the build on any of them.

## Comments

- No comments in code. The one exception is a doc comment on a declaration
  (`///` in Swift, a docstring in Python, KDoc in Kotlin) saying what the
  function, type or property does or is, never how it works inside.
- So no inline or trailing comments, `// MARK:` lines or commented-out code.
  If code needs explaining, rename or restructure it.
- Reasons behind non-obvious code (platform quirks, workarounds, ordering
  that matters) go in `knowledge/`, not in the code.
- A script's header saying what it does and how to run it counts as its doc
  comment. Toolchain directives (`// swift-tools-version`, shebangs) aren't
  comments.

## Project knowledge (OKF)

Durable project knowledge lives in [`knowledge/`](knowledge/index.md), an
[Open Knowledge Format v0.2](knowledge/references/okf-spec.md) bundle: a folder
of markdown files with YAML frontmatter, one concept per file.

- Start at `knowledge/index.md` and open only what the task needs.
- Treat `status: draft` or unverified concepts as leads, not settled facts.
- Check `stale_after` before relying on facts about machine state or versions.

### When to write

Write or update a concept when you learn something a future agent would
otherwise have to rediscover: a decision and its reasons, a platform
constraint, an API gotcha, a measured fact about the environment.

Don't write what the code or git history already records, or notes that only
matter to the current task.

### How to write

- One concept per file, kebab-case name, in the folder that fits. Make a new
  folder (with an `index.md`) when nothing fits.
- Frontmatter: `type` (required), `title`, `description` (one sentence, reused
  in `index.md`), `tags`, `status` (`draft` | `stable` | `deprecated`), and
  `generated: { by: <actor>, at: <UTC ISO 8601> }`.
- Actors: agents write `<agent>/<model>` (for example
  `claude-code/claude-opus-5-5`, `codex/<model>`, `pi/<model>`); people write
  `human:<id>`. The owner is `human:parsa.nasirimehr`. Only a person adds a
  `human:` entry to `verified`; an agent that re-checks a fact against the
  machine adds itself.
- Facts with a shelf life (machine state, OS or tool versions) get a
  `stale_after` instant.
- Cite external material under `sources` with an `id`, and attribute specific
  claims with footnotes `[^id]`.
- Link concepts with bundle-relative links: `[permissions](/research/macos-permissions.md)`.
- Never delete superseded knowledge: set `status: deprecated` and link to its
  replacement.
- After any change: update the folder's `index.md`, add an entry to
  `knowledge/log.md` (newest date first), then run:

```bash
python3 scripts/okf_lint.py
```

Concept types in use: `Project Brief`, `Requirements`, `Architecture`,
`Plan`, `Test Plan`, `Design`, `Analysis`, `Platform Constraint`, `Reference`,
`Environment`. Add new types when none fit, such as `Decision` for choices
made during the build. Spike results go in `research/` as `Analysis`.
